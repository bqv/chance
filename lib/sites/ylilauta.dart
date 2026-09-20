import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chan/models/board.dart';
import 'package:chan/models/post.dart';
import 'package:chan/models/thread.dart';
import 'package:chan/services/cloudflare.dart';
import 'package:chan/services/persistence.dart';
import 'package:chan/sites/imageboard_site.dart';
import 'package:chan/sites/util.dart';
import 'package:chan/sites/ylilauta_parser.dart';
import 'package:chan/util.dart';
import 'package:chan/widgets/post_spans.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart';

/// Ylilauta (ylilauta.org) is a Finnish imageboard with no public JSON API.
///
/// Everything a browser needs is enforced at the edge, and the checks are
/// deliberately hard for a non-browser to satisfy:
///
///  * **HTTP/2 or newer is mandatory.** An HTTP/1.1 request is answered with
///    `404 HTTP Version Not Supported`.
///  * **The TLS ClientHello is fingerprinted, and must agree with the identity
///    being claimed.** A request is served only when the TLS stack looks like
///    the browser named in the User-Agent. Measured behaviour: `curl` and
///    `httpx` (both OpenSSL) are rejected with `410` for every User-Agent
///    tried, while a browser-fingerprinted client passes. A real Chrome browser
///    claiming to be Firefox is rejected, so the two must be consistent.
///  * **Engine capability is enforced.** The site requires very recent engines
///    (roughly Chrome 131+/Firefox 133+/Safari 18+) and refuses older ones.
///  * **hCaptcha** is presented when traffic looks automated and is verified
///    through `POST /api/user-captcha-verify`.
///
/// Dart's `dart:io` TLS stack cannot forge a browser ClientHello, so no Dio
/// request to ylilauta.org can succeed regardless of which headers are set.
/// This adapter therefore does **not** fetch HTML over Dio: each page is
/// rendered in a real browser engine via [useCloudflareClearedWebview], which
/// also lets the existing Cloudflare/hCaptcha machinery take over when a
/// challenge appears. Only the parsed result reaches the app, so browsing still
/// happens in Chance's own native board and thread views.
///
/// [overrideUserAgent] should be left unset for this site. The gate compares the
/// claimed identity against the TLS fingerprint, so forcing a different
/// User-Agent into the WebView would present a mismatch and be refused; the
/// WebView's own real-browser identity is the one that works.
///
/// Media is the exception: attachments are served ungated from `i.ylilauta.org`
/// over ordinary HTTP, so images and video need no WebView round-trip.
class SiteYlilauta extends ImageboardSite {
	static const _kFetchGatewayName = 'Ylilauta';
	static const _kChallengeGatewayName = 'Ylilauta challenge';
	static const _kVoteGatewayName = 'Ylilauta vote';

	SiteYlilauta({
		required this.name,
		required this.baseUrl,
		required this.defaultUsername,
		this.faviconPath = '/static/img/seal_of_ylilauta-icon.svg',
		required this.filesPerPost,
		required this.maxUploadSizeBytes,
		required super.overrideUserAgent,
		required super.addIntrospectedHeaders,
		required super.preferHttp3WithoutAltSvc,
		required super.archives,
		required super.imageHeaders,
		required super.videoHeaders
	});

	/// The signed `data-state` the board listing carries, remembered per board.
	///
	/// It is required by the "load more threads" request and is only obtainable
	/// from the board page, so it is cached after a catalog fetch. A call that
	/// misses the cache refetches the board page rather than failing.
	final Map<String, String> _catalogState = {};

	/// Slugs seen this session for threads the rest of the app has not read
	/// from a listing yet - in practice the thread a post just created, whose
	/// address is the page the composer's submit landed on.
	///
	/// The board listing does not carry a thread the moment it is created, so
	/// without this the app cannot open the thread it has just made.
	final Map<ThreadIdentifier, String> _knownSlugs = {};

	@override
	final String name;
	@override
	final String baseUrl;
	@override
	final String defaultUsername;
	final String faviconPath;
	final int filesPerPost;
	final int? maxUploadSizeBytes;

	@override
	String get siteType => 'ylilauta';

	@override
	String get siteData => baseUrl;

	@override
	Uri? get iconUrl => Uri.https(baseUrl, faviconPath);

	/// The seal, bundled rather than fetched.
	///
	/// [iconUrl] cannot work for this site: its static files sit behind the same
	/// browser check as its pages, so a plain HTTP client is refused, and the
	/// file is an SVG that the image decoder cannot read even if it arrived. The
	/// app already carries the seal as its launcher icon, so the site list uses
	/// that instead.
	@override
	String? get iconAsset => 'assets/ylilauta.png';

	/// Attachments are served ungated from a separate host.
	@override
	String? get imageUrl => 'i.$baseUrl';

	@override
	bool get supportsPushNotifications => false;

	@override
	bool get allowsArbitraryBoards => true;

	/// Threads have no subject here: they are known by their opening post, and
	/// the new-thread dialog takes a board, a name and a message, nothing more.
	/// Offering a subject in the composer promised something the site dropped.
	@override
	bool get supportsThreadSubjects => false;

	/// The site names an upload after its own file id and serves it that way
	/// (`content-disposition: <file id>.<ext>`), so the filename the app sends
	/// as the multipart part's name never reaches the post. Offering the field
	/// promised something the site dropped, the same as the subject above.
	@override
	bool get supportsCustomFilenames => false;

	/// Board listings are endless: the site appends more threads as the page
	/// scrolls, through `POST /api/community/board/load-threads`.
	@override
	bool get hasPagedCatalog => true;

	/// Posting runs through the site's own composer in a WebView, because every
	/// request to ylilauta has to look like a real browser - see [submitPost].
	///
	/// Whether it is *offered* follows the session, which is read from the pages
	/// the site serves ([signedInFromHtml]). The controls themselves are no use
	/// for this: the site renders `Post.reply`, `Thread.create` and `Post.upvote`
	/// for signed-out visitors as well - the anonymous captures in
	/// `test/ylilauta_fixtures` carry them - and only settles it when one is
	/// used. Its header does differ, which is what is read here.
	///
	/// Nothing read yet means yes: a page is what tells us otherwise, and the
	/// thread page is fetched before its reply box is built.
	@override
	bool get supportsPosting => _signedIn ?? true;

	/// Whether the last page the site served offered this session a login, or
	/// null when no full page has been read yet.
	///
	/// Every page the app fetches goes through [_readSession], so this follows
	/// the session rather than the app's own memory of a login: a session that
	/// expires while the app is open shows up here on the next page.
	bool? _signedIn;
	bool? get signedIn => _signedIn;

	/// Whether the last post page that carried post controls also carried the
	/// upvote control, or null when no such page has been read yet.
	///
	/// The control is not evidence on its own - the site renders it for
	/// signed-out visitors, the same way it renders `Post.reply` - so what it
	/// adds over [_signedIn] is the other direction: a post page that has post
	/// controls but no `Post.upvote` (a muted account, the account's own
	/// `removeVotes` preference, a site change) takes the affordance away
	/// instead of offering a vote that would be refused.
	bool? _upvoteOffered;

	/// Any of the controls the site puts on a post.

	/// The upvote control itself.
	static final _kPostUpvoteControlPattern = RegExp(r'data-action="Post\.upvote"');

	/// A page on which posts carry their own controls.
	///
	/// Only such a page can say whether upvoting is offered: the board listing
	/// renders each thread as a compact card whose `Post.menu` and `Post.reply`
	/// buttons are the only `Post.*` controls it has - by design, cards have no
	/// counts and no upvote button - so reading that as "the site stopped
	/// offering upvotes" would take the affordance away from every thread the
	/// app already has open, the moment the board is browsed.
	static final _kPostMetaPattern = RegExp(r'class="post-meta"');

	/// A page that offers to reply to a post, which only a thread page does.
	///
	/// This is what makes a page fit to answer whether voting is offered: a board
	/// listing and a 404 listing carry posts and post metadata too, but no vote
	/// buttons, so reading their silence as "no upvotes here" hid the control for
	/// as long as a board was the last thing read - which is most of the time.
	static final _kReplyControlPattern = RegExp(r'data-action="(?:Post|Thread)\.reply"');

	/// Whether this session can upvote posts here, decided from the page the
	/// same way [supportsPosting] is: the site's own controls say whether it
	/// offers voting at all, and the header says whether there is a session to
	/// vote with. Nothing read yet means yes, since a page is what tells us
	/// otherwise and a thread page is read before its posts are shown.
	@override
	bool get supportsPostUpvotes {
		if (_upvoteOffered == false) {
			return false;
		}
		return _signedIn ?? true;
	}

	/// Controls the site puts in the header of every full page it serves.
	static final _kUserControlPattern = RegExp(r'data-action="User\.[a-zA-Z]+"');

	/// The control that header offers a session with no account. Its absence,
	/// when the header is there at all, is what being signed in looks like from
	/// outside the site's own scripts.
	static final _kLoginControlPattern = RegExp(r'data-action="User\.login"');

	/// Reads what a page says about the session it was served to.
	///
	/// A page with no `User.*` control in it has no header to read - an Ajax
	/// fragment, or a document that never finished rendering - and returns null
	/// rather than guessing, so the previous answer stands.
	@visibleForTesting
	static bool? signedInFromHtml(String html) {
		if (!_kUserControlPattern.hasMatch(html)) {
			return null;
		}
		return !_kLoginControlPattern.hasMatch(html);
	}

	/// The account the last page was served to, if it named one.
	///
	/// The header of every full page carries it: `/user/account` links the
	/// name, `/user/level` shows the level, and the level's own title gives the
	/// experience behind it. That is the only place the app can see any of it -
	/// the cookie jar holds no name - and the level is worth having in front of
	/// the user, since most boards only accept posts from an account with
	/// enough of it.
	({String name, String level, String? experience})? _account;

	/// `<a class="username">nyymin</a>`, wherever its attributes sit.
	static final _kAccountNamePattern = RegExp(r'class="username"[^>]*>([^<]{1,64})<');

	/// `<span class="user-level" title="Experience points: 1208 / 1372">Level 5</span>`.
	static final _kAccountLevelPattern = RegExp(r'class="user-level"[^>]*>([^<]{1,32})<');
	static final _kAccountExperiencePattern = RegExp(r'class="user-level"[^>]*title="([^"]{1,64})"');

	void _readSession(Uri uri, String html) {
		if (signedInFromHtml(html) case final signedIn?) {
			if (signedIn != _signedIn) {
				debugPrint('ylilauta: ${signedIn ? 'signed in' : 'signed out'} according to $uri');
			}
			_signedIn = signedIn;
		}
		if (signedInFromHtml(html) == true) {
			final name = _kAccountNamePattern.firstMatch(html)?.group(1)?.trim();
			final level = _kAccountLevelPattern.firstMatch(html)?.group(1)?.trim();
			if (name != null && name.isNotEmpty && level != null && level.isNotEmpty) {
				_account = (
					name: name,
					level: level,
					experience: _kAccountExperiencePattern.firstMatch(html)?.group(1)?.trim()
				);
			}
		}
		// Only a thread page can answer this. A page that does not offer replies
		// is a board listing or a 404 listing: it carries posts and post metadata
		// but never vote buttons, and treating that as "no upvotes" is what left
		// the upvote control dead after any background board refresh.
		if (_kReplyControlPattern.hasMatch(html) && _kPostMetaPattern.hasMatch(html)) {
			_upvoteOffered = _kPostUpvoteControlPattern.hasMatch(html);
		}
	}

	/// Feeds a page through the reads [_readSession] makes, for tests: the real
	/// path is a WebView, so there is no other way to put a captured page in
	/// front of the session logic.
	@visibleForTesting
	void readPageState(Uri uri, String html) => _readSession(uri, html);

	/// Logging in is worth having on its own: most ylilauta boards only accept
	/// posts from an account with enough level behind it, so the login has to
	/// exist before posting can.
	///
	/// One instance, because the login state lives on it.
	late final SiteYlilautaLoginSystem _loginSystem = SiteYlilautaLoginSystem(this);
	@override
	SiteYlilautaLoginSystem get loginSystem => _loginSystem;

	@override
	String getWebUrlImpl(String board, [int? threadId, int? postId]) {
		// A thread is addressed by its slug, not its id, and /<board>/<number> is
		// a 404 - so emitting the id here would produce links that never load.
		// The slug is only known from a catalog already fetched for the board,
		// and that cache is in memory only; when it is missing the id is the last
		// resort, but note the resulting link will not work.
		String? segment;
		if (threadId != null) {
			segment = getThreadFromCatalogCache(ThreadIdentifier(board, threadId))?.urlSlug ?? threadId.toString();
		}
		final uri = Uri.https(baseUrl, '/$board/${segment ?? ''}');
		return postId == null ? uri.toString() : '$uri#post-$postId';
	}

	@override
	bool decodeUrlPossible(Uri url) => url.host == baseUrl || url.host == imageUrl;

	/// Thread URLs are `/<board>/<slug>`, with `#post-<postId>` for post links.
	/// Board names are open-ended, so the first path segment is taken as-is.
	///
	/// The slug is not the thread id, and a slug that is all digits is not an id
	/// either - the site has threads whose address is numeric (the captured
	/// `/rikokset/298021` is thread `136422217`) - so the number in the address
	/// is never reported as the thread. Resolving a slug to an id needs the
	/// page, so that lookup is only done when the caller supplied a cancel
	/// token, which the link handler does and a pure URL check does not.
	/// Otherwise the identifier carries the post it was given and no thread,
	/// rather than inventing one from the address.
	@override
	Future<BoardThreadOrPostIdentifier?> decodeUrl(Uri url, {CancelToken? cancelToken}) async {
		if (url.host != baseUrl && url.host != imageUrl) {
			return null;
		}
		final segments = url.pathSegments.where((s) => s.isNotEmpty).toList(growable: false);
		if (segments.isEmpty) {
			return null;
		}
		final board = segments.first;
		final postId = url.fragment.extractPrefixedInt('post-');
		// `/post/<id>` is a post's own address, which the site answers with the
		// thread holding that post - so its board and slug come from the page
		// reached, not from the address. Reading it as a board called "post"
		// meant every reference the site renders that way opened nothing.
		if (board == 'post' && segments.length == 2) {
			final id = segments[1].tryParseInt;
			if (id == null || cancelToken == null) {
				return null;
			}
			final html = await _fetchHtml(Uri.https(baseUrl, '/post/$id'), priority: RequestPriority.functional, cancelToken: cancelToken);
			if (YlilautaParser.threadAddress(html) case final address?) {
				final thread = YlilautaParser.parseThreadBySlug(html, board: address.board, slug: address.slug, defaultUsername: defaultUsername, fetchedTime: DateTime.now());
				return BoardThreadOrPostIdentifier(address.board, thread.id, id);
			}
			return BoardThreadOrPostIdentifier(board, null, id);
		}
		if (segments.length < 2) {
			return BoardThreadOrPostIdentifier(board, null, postId);
		}
		final slug = segments[1];
		if (cancelToken == null) {
			return BoardThreadOrPostIdentifier(board, null, postId);
		}
		// Resolve the slug to the thread's real id by reading the page.
		final html = await _fetchHtml(Uri.https(baseUrl, '/$board/$slug'), priority: RequestPriority.functional, cancelToken: cancelToken);
		final thread = YlilautaParser.parseThreadBySlug(html, board: board, slug: slug, defaultUsername: defaultUsername, fetchedTime: DateTime.now());
		return BoardThreadOrPostIdentifier(board, thread.id, postId);
	}

	// ---------------------------------------------------------------- fetching

	/// Fetches [uri], waiting out the site's "you are asking too fast" answer.
	///
	/// Asking for pages faster than roughly one every few seconds gets a ~930 byte
	/// stub with a 200 status, on the requested URL, for every request after that.
	/// It is not the challenge page (that is caught below) and it parses as a
	/// board with no threads - which is why it has to be caught here, or the app
	/// shows an empty board and no reason for it. A real page is 25 KB and up.
	///
	/// The stub is the site asking for patience rather than a failure, so a read
	/// the user is waiting on waits it out and asks once more. One retry and not a
	/// series: two answers like this in a row mean the site wants a longer rest
	/// than a screen should hang for, and asking repeatedly is itself the traffic
	/// the stub is asking to be spared. Speculative reads do not even get the one
	/// retry, being neither worth waiting for nor innocent of causing it.
	Future<String> _fetchHtml(Uri uri, {required RequestPriority priority, CancelToken? cancelToken}) async {
		var askedAgain = false;
		while (true) {
			final html = await _fetchPageOnce(uri, priority: priority, cancelToken: cancelToken);
			if (html.length >= _kSmallestRealPage) {
				_readSession(uri, html);
				return html;
			}
			if (askedAgain || priority.index < RequestPriority.functional.index) {
				final what = html.isEmpty ? 'nothing' : 'a ${html.length}-byte page instead of the page itself';
				throw Exception('ylilauta answered $uri with $what, '
					'which is what it does when asked for too much at once. Waited '
					'${_kThrottleRetryDelay.inSeconds}s and asked once more; leaving it '
					'alone for a moment, or reading fewer pages at once, is what clears it.');
			}
			await _pauseFor(_kThrottleRetryDelay, cancelToken);
			askedAgain = true;
		}
	}

	/// Waits [duration], or until the request is cancelled, whichever is first.
	Future<void> _pauseFor(Duration duration, CancelToken? cancelToken) async {
		if (cancelToken == null) {
			return Future.delayed(duration);
		}
		await Future.any([
			Future.delayed(duration),
			cancelToken.whenCancel.then((reason) => throw reason)
		]);
	}

	/// How long to wait before asking once more after being served the stub.
	static const _kThrottleRetryDelay = Duration(seconds: 9);

	/// Renders [uri] in a real browser engine and returns the document HTML.
	///
	/// This is the only way to read ylilauta. [useCloudflareClearedWebview]
	/// drives the site's hCaptcha challenge, presenting it to the user when it
	/// cannot be cleared headlessly, and persists cookies back to Chance's jar so
	/// the session is reused for later requests.
	///
	/// This handler is only reached once no gateway is pending (see
	/// [getRedirectGateway]), so the page should be the real one by then.
	///
	/// One attempt: what comes back is whatever the site answered with, including
	/// the stub that [_fetchHtml] decides what to do about.
	Future<String> _fetchPageOnce(Uri uri, {required RequestPriority priority, CancelToken? cancelToken}) async {
		// `T` is nullable so that the handler can return null to mean "not ready
		// yet". That matters: a null return leaves the future pending, which is
		// what lets the helper fall through to showing the authorization prompt.
		// Returning a non-null wrapper around null would instead *complete* the
		// future with nothing, and the prompt would never appear.
		final started = DateTime.now();
		var handlerCalls = 0;
		final fetch = useCloudflareClearedWebview<String?>(
			site: this,
			uri: uri,
			priority: priority,
			gatewayName: _kFetchGatewayName,
			// This is how long to wait before *showing the prompt*, not how long
			// the page has to render: the normal path completes as soon as
			// onLoadStop fires, which is under a second. So it is kept short, or
			// a prompt that is genuinely needed takes that long to appear.
			// Waiting for a slow render is the handler's job instead.
			headlessTime: const Duration(seconds: 6),
			cancelToken: cancelToken,
			handler: (controller, url) async {
				handlerCalls++;
				// The document can still be rendering when onLoadStop fires, so
				// retry briefly. Returning null is what tells the helper to keep
				// the WebView alive - but a null return is also what lets the
				// prompt open, so it is only taken after genuinely trying.
				//
				// getHtml is tried first because it is what the helper uses for
				// its own decisions: the gateway is handed the document through
				// that same call, so it is known to work here.
				String? html;
				for (var attempt = 0; attempt < 11; attempt++) {
					final viaHtml = await controller.getHtml();
					if (viaHtml != null && viaHtml.isNotEmpty) {
						html = viaHtml;
						break;
					}
					final viaJs = await controller.evaluateJavascript(source: 'document.documentElement.outerHTML');
					if (viaJs is String && viaJs.isNotEmpty) {
						html = viaJs;
						break;
					}
					await Future.delayed(const Duration(milliseconds: 250));
				}
				if (html == null) {
					// Not rendered yet; leave the WebView running.
					return null;
				}
				if (isChallengePage(html)) {
					throw Exception('ylilauta returned its bot challenge instead of $uri. '
						'Solving it in the authorization prompt should let this through.');
				}
				return html;
			}
		);
		// A fetch that never produces a document otherwise leaves the UI spinning
		// with no explanation. Give up with a message instead, saying how long it
		// waited and how many times the WebView reported a page.
		final html = await fetch.timeout(
			const Duration(seconds: 45),
			onTimeout: () => throw Exception('ylilauta did not respond for $uri after '
				'${DateTime.now().difference(started).inSeconds}s '
				'($handlerCalls WebView page load(s)); retrying may help')
		);
		// Nothing at all is treated like the stub and left to [_fetchHtml], which is
		// the only place that knows whether waiting for a real page is worth it.
		return html ?? '';
	}

	/// The shortest real document ylilauta serves. Anything smaller is a stub or
	/// an error page dressed up with a 200.
	static const _kSmallestRealPage = 4000;

	/// ylilauta truncates long thread titles to 160 characters and ends them
	/// with "...", so an ellipsis here says nothing about the page being a
	/// gateway - a long-titled thread is an ordinary thread.
	///
	/// This matters because the generic heuristic reads that ellipsis as an
	/// unfinished challenge: the page was never accepted, and once the headless
	/// attempt gave up, the authorization prompt opened showing the thread
	/// itself. This site's interstitial is recognised from its markup instead
	/// ([isChallengePage]), which is what actually identifies it.
	@override
	bool get ellipsisTitleMeansGateway => false;

	/// Tells the WebView machinery to hold off and present a prompt.
	///
	/// This is the hook that actually makes an hCaptcha solvable. The helper
	/// checks it *before* calling the fetch handler, and a non-null gateway makes
	/// it skip the handler's result and open the interactive authorization page
	/// instead. Without this, a challenge page reaches the handler, which can do
	/// nothing useful with it - and completing there means the prompt is never
	/// shown, which is exactly how a challenge turns into a silently empty board
	/// list.
	@override
	Future<ImageboardRedirectGateway?> getRedirectGateway(Uri uri, String? Function() title, Future<String?> Function() html) async {
		if (uri.host != baseUrl && uri.host.isNotEmpty) {
			return null;
		}
		// Use the same markers as [isChallengePage], not the title alone.
		// Checking only `<title>` missed the interstitial in practice: the
		// handler went on to see the challenge and throw, which is how this
		// showed up as an error instead of a prompt. `h-captcha` and the verify
		// endpoint are present in the markup the interstitial serves, and do not
		// appear on ordinary pages.
		final pageHtml = await html() ?? '';
		final challenging = isChallengePage(pageHtml);
		if (challenging) {
			return const ImageboardRedirectGateway(
				name: _kChallengeGatewayName,
				// hCaptcha always needs a human.
				alwaysNeedsManualSolving: true
			);
		}
		return null;
	}

	/// Detects ylilauta's bot interstitial. It is served with a `200` status on
	/// the requested URL, so it cannot be identified by status code.
	///
	/// The markers are deliberately narrow. A plain substring check on the
	/// interstitial's body text would misfire on an ordinary page whose posts
	/// merely mention the same words, and misfiring here is expensive: the fetch
	/// would wait for a challenge that never appears.
	static bool isChallengePage(String html) {
		// A page carrying a thread is the thread, not a challenge - whatever
		// else is on it. ylilauta serves the interstitial *inside* otherwise
		// normal pages in some situations, and treating those as challenges
		// handed the user a prompt displaying the very thread they asked for.
		if (html.contains('card thread')) {
			return false;
		}
		// The hCaptcha widget, or the interstitial's own title. Neither appears
		// on an ordinary board or thread page.
		if (html.contains('h-captcha')) {
			return true;
		}
		return _kChallengeTitlePattern.hasMatch(html);
	}

	// ----------------------------------------------------------------- boards

	@override
	Future<List<ImageboardBoard>> getBoards({required RequestPriority priority, CancelToken? cancelToken}) async {
		final html = await _fetchHtml(Uri.https(baseUrl, '/'), priority: priority, cancelToken: cancelToken);
		return YlilautaParser.parseBoards(html, filesPerPost: filesPerPost, maxUploadSizeBytes: maxUploadSizeBytes);
	}

	// ---------------------------------------------------------------- catalog

	@override
	Future<Catalog> getCatalogImpl(String board, {CatalogVariant? variant, required RequestPriority priority, CancelToken? cancelToken}) async {
		final html = await _fetchHtml(Uri.https(baseUrl, '/$board/'), priority: priority, cancelToken: cancelToken);
		if (YlilautaParser.parseCatalogState(html) case final state?) {
			_catalogState[board] = state;
		}
		return YlilautaParser.parseCatalog(html, board: board, defaultUsername: defaultUsername, fetchedTime: DateTime.now());
	}

	/// Fetches the next batch of threads for the endless board listing.
	///
	/// The board page's own script does this with
	/// `POST /api/community/board/load-threads {board, state, from}`, where
	/// `from` is the id of the last thread currently displayed and `state` is
	/// the signed token from the listing's container. Both are needed verbatim,
	/// so it is not something a plain GET to a page number can reproduce.
	@override
	Future<List<Thread>> getMoreCatalogImpl(String board, Thread after, {CatalogVariant? variant, required RequestPriority priority, CancelToken? cancelToken}) async {
		final state = await _catalogStateFor(board, priority: priority, cancelToken: cancelToken);
		if (state == null) {
			return const [];
		}
		final fragment = await _postFromPage(
			Uri.https(baseUrl, '/api/community/board/load-threads'),
			{
				'board': board,
				'state': state,
				'from': after.id.toString()
			},
			referer: Uri.https(baseUrl, '/$board/'),
			priority: priority,
			cancelToken: cancelToken
		);
		final threads = YlilautaParser.parseMoreThreads(fragment, board: board, defaultUsername: defaultUsername, fetchedTime: DateTime.now());
		if (threads.isEmpty) {
			// The listing ended, or the token has gone stale. Forget it so a
			// later attempt starts from a freshly fetched board page.
			_catalogState.remove(board);
		}
		return threads;
	}

	Future<String?> _catalogStateFor(String board, {required RequestPriority priority, CancelToken? cancelToken}) async {
		if (_catalogState[board] case final cached?) {
			return cached;
		}
		// Not seen yet (for example a board opened from a stored catalog), so
		// read it off the board page before giving up.
		final html = await _fetchHtml(Uri.https(baseUrl, '/$board/'), priority: priority, cancelToken: cancelToken);
		final state = YlilautaParser.parseCatalogState(html);
		if (state != null) {
			// Only a state the page published is worth remembering. An empty one
			// would be cached as though it were valid, and the caller's "no
			// state means the listing has ended" check could then never fire
			// again for this board.
			_catalogState[board] = state;
		}
		return state;
	}

	/// Performs a form POST from within the page context.
	///
	/// The endpoint rejects requests without the page's CSRF token and relies on
	/// the browser session, so the request is issued by the page itself rather
	/// than through Dio. The response body is returned as raw text.
	Future<String> _postFromPage(Uri uri, Map<String, String> fields, {
		required Uri referer,
		required RequestPriority priority,
		CancelToken? cancelToken
	}) async {
		final fieldsJson = jsonEncode(fields);
		// `T` is nullable because a null return is the helper's own signal for
		// "not ready yet", which the page needs while it is still loading.
		final response = await useCloudflareClearedWebview<String?>(
			site: this,
			uri: referer,
			priority: priority,
			gatewayName: _kFetchGatewayName,
			// ylilauta pages are large (threads run to hundreds of KB), so a short
			// window expires before the document has rendered. That expiry drops the
			// fetch into the interactive popup even though nothing is wrong, which
			// showed up as a prompt displaying the page that was already loading.
			headlessTime: const Duration(seconds: 20),
			cancelToken: cancelToken,
			handler: (controller, url) async {
				// The CSRF token is the `request_key` cookie's value, which the
				// page passes to its own App constructor as a literal. It has to
				// be read from that literal rather than from `document.cookie`:
				// the cookie is marked HttpOnly, so the page cannot see it.
				// Verified against the live site - sending the cookie value in
				// the header returns 403, while the literal from the script is
				// accepted. `document.cookie` is still tried first only as a
				// cheap no-op that costs nothing when it is absent.
				final token = await controller.evaluateJavascript(source: r"""
					(() => {
						const html = document.documentElement.outerHTML;
						const m = html.match(/new App\(\s*'[^']*'\s*,\s*'([0-9a-fA-F]{32,})'/);
						if (m) {
							return m[1];
						}
						const fromCookie = document.cookie
							.split('; ')
							.find((c) => c.startsWith('request_key='));
						return fromCookie ? fromCookie.slice('request_key='.length) : '';
					})()
				""");
				final csrf = token is String ? token : '';
				if (csrf.isEmpty) {
					throw Exception('No request_key on ${uri.path}; the session may have expired');
				}
				final result = await controller.callAsyncJavaScript(functionBody: """
					return (async () => {
						const fields = $fieldsJson;
						const body = new URLSearchParams();
						for (const key of Object.keys(fields)) {
							body.append(key, fields[key]);
						}
						const response = await fetch(${jsonEncode(uri.toString())}, {
							method: 'POST',
							headers: {
								'Content-Type': 'application/x-www-form-urlencoded',
								'X-CSRF-Token': ${jsonEncode(csrf)}
							},
							body: body.toString(),
							credentials: 'same-origin'
						});
						return await response.text();
					})();
				""");
				final value = result?.value;
				if (value is String && value.isNotEmpty) {
					return value;
				}
				// Nothing useful yet; keep the WebView open.
				return null;
			}
		);
		if (response == null) {
			throw Exception('No response from ${uri.path}');
		}
		return response;
	}

	// ----------------------------------------------------------------- thread

	@override
	Future<Thread> getThreadImpl(ThreadIdentifier thread, {ThreadVariant? variant, required RequestPriority priority, CancelToken? cancelToken}) async {
		final slug = await _resolveSlug(thread, priority: priority, cancelToken: cancelToken);
		_knownSlugs[thread] = slug;
		final html = await _fetchHtml(Uri.https(baseUrl, '/${thread.board}/$slug'), priority: priority, cancelToken: cancelToken);
		// A thread that has been deleted still returns a page, so a mismatch is
		// not evidence the thread is gone. Parsing it is what surfaces the
		// deleted-but-readable case, so it is preferred over refusing it.
		final parsed = YlilautaParser.parseThreadBySlug(html, board: thread.board, slug: slug, defaultUsername: defaultUsername, fetchedTime: DateTime.now());
		if (parsed.id != thread.id) {
			debugPrint('ylilauta: $slug parsed as thread ${parsed.id}, expected ${thread.id}');
		}
		return withUpvoteState(parsed, html);
	}

	/// The vote state the page's own markup carries, per post id.
	///
	/// `active` is the class the site's scripts toggle when this session upvotes
	/// a post, and the only thing the page says about the viewer's own vote. It
	/// is read here rather than in [YlilautaParser] because it is page state
	/// rather than post content: the parser is a pure DOM-to-model pass over a
	/// post, while this needs the whole document and the session it was served
	/// to.
	///
	/// A post with no upvote button, or a page with no post controls at all,
	/// stays absent from the map - which the caller must read as unknown and not
	/// as "not voted", since the page renders the control for signed-out
	/// visitors too.
	///
	/// TODO(probe): whether the server renders `active` on a post this session
	/// has already voted was never observed - no signed-in capture carries it -
	/// so this may only ever be populated by a vote the app itself just cast.
	/// The optimistic update in [togglePostUpvote] is what keeps the state right
	/// until then. If a probe shows a different class, change it here.
	@visibleForTesting
	static Map<int, bool> upvoteStateFromHtml(String html) {
		final result = <int, bool>{};
		// Cheap guard: most pages (the board listing, the catalog fragment)
		// carry no upvote control at all, and parsing those is not free.
		if (!html.contains('Post.upvote')) {
			return result;
		}
		for (final button in parse(html).querySelectorAll('button[data-action="Post.upvote"][data-post-id]')) {
			final id = button.attributes['data-post-id']?.tryParseInt;
			if (id != null) {
				result[id] = button.classes.contains('active');
			}
		}
		return result;
	}

	/// Fills in [Post.upvoted] from the page a thread was parsed out of.
	@visibleForTesting
	static Thread withUpvoteState(Thread thread, String html) {
		final state = upvoteStateFromHtml(html);
		if (state.isEmpty) {
			return thread;
		}
		for (var i = 0; i < thread.posts_.length; i++) {
			final post = thread.posts_[i];
			if (state[post.id] case final upvoted?) {
				thread.posts_[i] = post.copyWith(upvoted: upvoted);
			}
		}
		return thread;
	}

	/// The URL slug for a thread, which is what its address is built from.
	///
	/// The slug is unrelated to the id and is known when the thread came from the
	/// catalog (which records it on the Thread) or from a link the user pasted.
	/// The cache holds every catalog page fetched for this board, including the
	/// batches appended while scrolling, so it is a better source than a fresh
	/// first-page fetch - but it is in memory only, so a thread opened after a
	/// restart or from history has nothing there. The stored thread state is the
	/// second source: a thread is stored with the slug it was fetched under, so
	/// anything the app has read once opens again without the board being
	/// visited. Failing both, the board listing is re-read, which only covers
	/// the first page - the case that produced "no link known" for a thread that
	/// was perfectly readable.
	Future<String> _resolveSlug(ThreadIdentifier thread, {required RequestPriority priority, CancelToken? cancelToken}) async {
		// The slug of a thread this session has already seen, e.g. one the user
		// just started: the composer's page *is* that thread, so its address is
		// known before the board listing has caught up with it.
		var slug = _knownSlugs[thread]
			?? getThreadFromCatalogCache(thread)?.urlSlug
			?? persistence?.getThreadStateIfExists(thread)?.thread?.urlSlug;
		if (slug == null) {
			// The numeric id is not usable as an address: ylilauta answers
			// /<board>/<number> with a 404, so that path never reaches the thread.
			try {
				final boardHtml = await _fetchHtml(Uri.https(baseUrl, '/${thread.board}/'), priority: priority, cancelToken: cancelToken);
				final fresh = YlilautaParser.parseCatalog(boardHtml, board: thread.board, defaultUsername: defaultUsername, fetchedTime: DateTime.now());
				slug = fresh.threads[thread.id]?.urlSlug;
				if (slug == null) {
					// A post's id is sometimes handed round as if it were a
					// thread's - a reference to another board's post names one,
					// and a new thread's receipt used to carry its opening
					// post's - and the two are different numbers here. A card
					// whose opening post is this id is still the thread being
					// asked for, so it is used rather than reported as missing.
					for (final candidate in fresh.threads.values) {
						if (candidate.urlSlug != null && candidate.posts_.any((p) => p.id == thread.id)) {
							debugPrint('ylilauta: ${thread.board}/${thread.id} is post ${thread.id}, which opens thread ${candidate.id} at ${candidate.urlSlug}');
							slug = candidate.urlSlug;
							break;
						}
					}
				}
			}
			catch (e) {
				// Fall through.
			}
		}
		if (slug == null) {
			// A thread that scrolled off the listing, or one opened after a
			// restart, lands here. That is a missing address, not proof the
			// thread is gone - reporting it as deleted hid threads that are
			// perfectly readable, so say what actually happened instead.
			throw Exception('ylilauta: no link known for ${thread.board}/${thread.id}. '
				'Open the board once so the thread is listed, then retry.');
		}
		return slug;
	}

	// ---------------------------------------------------------------- captcha

	/// ylilauta presents hCaptcha on its own pages and verifies it server-side
	/// through `POST /api/user-captcha-verify`.
	@override
	Future<CaptchaRequest> getCaptchaRequest(String board, int? threadId, {CancelToken? cancelToken}) async {
		// A thread is addressed by its slug, so a numeric path here would fetch a
		// 404 listing and always come back "no captcha".
		final hostPage = threadId == null
			? Uri.https(baseUrl, '/$board/')
			: Uri.https(baseUrl, '/$board/${await _resolveSlug(ThreadIdentifier(board, threadId), priority: RequestPriority.interactive, cancelToken: cancelToken)}');
		final html = await _fetchHtml(hostPage, priority: RequestPriority.interactive, cancelToken: cancelToken);
		final siteKey = _kCaptchaSiteKeyPattern.firstMatch(html)?.group(1);
		if (siteKey == null || siteKey.isEmpty) {
			return const NoCaptchaRequest();
		}
		return HCaptchaRequest(hostPage: hostPage, siteKey: siteKey);
	}

	// ------------------------------------------------------------------ post

	/// How long the WebView is given to get a post out before it would ask the
	/// user to clear the browser check by hand.
	///
	/// A post with no files takes a couple of seconds, so the base is what the
	/// composer needs. Files are the reason this is not a constant: each one
	/// crosses into the page in chunks and is then uploaded by the site, and
	/// getting that wrong is not a slow post but an authorization prompt over
	/// the top of one.
	static Future<Duration> _postingWindow(DraftPost post) async {
		var bytes = 0;
		for (final file in post.files) {
			try {
				bytes += await File(file.path).length();
			}
			catch (e) {
				// A missing file is reported where the files are read.
			}
		}
		// Roughly 250 KB/s of allowance, plus a fixed cost per file for the
		// round trips around it.
		return Duration(seconds: 15 + post.files.length * 10 + bytes ~/ 250000);
	}

	/// Posts by asking the site to post, in a WebView.
	///
	/// The request cannot be made from here: every request to ylilauta has to
	/// look like a real browser - Dart's TLS stack is refused at the edge - and
	/// the composer's POST carries the session's own `x-csrf-token`, which only
	/// the loaded page has. So the page posts it: the composer is opened, the
	/// text is put in it, and the site's own submit control is pressed. The page
	/// is then read back to see whether the post arrived, which is also what
	/// supplies the new post's id - or, for a thread, the thread's.
	@override
	Future<PostReceipt> submitPost(DraftPost post, CaptchaSolution captchaSolution, CancelToken cancelToken) async {
		// ylilauta has no guest posting, and its login is a dialog the page builds
		// for the user, so there is nothing to log in as without credentials and
		// no way to check the session from here: the jar holds cookies either
		// way. Credentials saved by a login are the only evidence of an account,
		// so say so now rather than opening a WebView to find out. With them, the
		// page is the authority - it either has a composer or it asks for a
		// login, and that answer is reported below.
		if (loginSystem.getSavedLoginFields() == null) {
			throw PostFailedException('Log in to ylilauta first - site settings, then Account. Most boards only accept posts from an account with enough level behind it.');
		}
		if (_signedIn == false) {
			throw PostFailedException('ylilauta is not signed in on this device - the last page it served offered a login rather than a session. Log in from site settings, then post again.');
		}
		final threadId = post.threadId;
		// A reply is written on the thread's own page, and a thread is started
		// from its board: the same composer either way, opened by a different
		// control on a different page.
		final page = threadId == null
			? Uri.https(baseUrl, '/${post.board}/')
			: Uri.https(baseUrl, '/${post.board}/${await _resolveSlug(ThreadIdentifier(post.board, threadId), priority: RequestPriority.interactive, cancelToken: cancelToken)}');
		// Whether the WebView gets the session is the whole question when a post
		// is refused, and the jar is the only side of it that can be looked at
		// from here, so log what it holds (names, never values).
		debugPrint('ylilauta post: ${threadId == null ? 'new thread' : 'reply to $threadId'} on $page');
		debugPrint('ylilauta post: jar cookies = ${(await Persistence.currentCookies.loadForRequest(Uri.https(baseUrl, '/'))).map((c) => c.name).toList()}');
		// One attempt, shared by every handler run the WebView makes for it.
		// Submitting a thread navigates the page, which enters the handler
		// again on the page that arrives; that run belongs to this attempt and
		// has to report its outcome, not post a second time.
		final attempt = _PostAttempt();
		final outcome = await useCloudflareClearedWebview<_PostOutcome>(
			site: this,
			uri: page,
			priority: RequestPriority.interactive,
			gatewayName: name,
			// The composer is built by the site's scripts, so give it room to
			// appear before the prompt would be shown - and room for the files
			// as well: attachments cross into the page and then go up to the
			// site, and the authorization prompt appearing in the middle of a
			// post is not something a post in progress should be interrupted
			// by. The estimate is generous on purpose, since the window only
			// matters if the work outlasts it.
			headlessTime: await _postingWindow(post),
			cancelToken: cancelToken,
			handler: (controller, uri) => _postInPage(controller, post, attempt)
		);
		if (outcome.error case final error?) {
			throw PostFailedException('ylilauta: $error');
		}
		return PostReceipt(
			password: '',
			id: outcome.postId!,
			name: post.name ?? defaultUsername,
			options: post.options ?? '',
			time: DateTime.now(),
			post: post
		);
	}

	/// Whether a post arrived, or what the site said instead.
	///
	/// The composer and its response are the site's own markup built by its own
	/// scripts, so what is found there is logged: it is the only way to see the
	/// shape of it without being in the page.
	///
	/// Every run of [attempt] answers with the attempt's one outcome, so this
	/// always has something to say.
	Future<_PostOutcome> _postInPage(InAppWebViewController controller, DraftPost post, _PostAttempt attempt) async {
		Future<dynamic> js(String source) => controller.evaluateJavascript(source: source);
		Future<Map<String, dynamic>?> readJson(String source) async {
			final raw = await js(source);
			if (raw is String && raw.isNotEmpty) {
				try {
					return jsonDecode(raw) as Map<String, dynamic>;
				}
				catch (e) {
					debugPrint('ylilauta post: unreadable json $raw');
				}
			}
			return null;
		}
		Future<Map<String, dynamic>?> state() => readJson(_kPostStateJs);

		// Submitting a thread navigates the page, which enters this handler
		// again on the page that arrives. That run is part of the attempt that
		// is already running, not a new post, so it reports the same outcome.
		// It also has to report *something*: returning null tells the helper
		// that this run has nothing to say, and - once the helper has no other
		// run to wait for - the post's result is what gets lost. That is what
		// "the post was left unfinished" was: the submit landed, the site
		// navigated to the new thread, and the answer never came back.
		if (attempt.outcome case final running?) {
			debugPrint('ylilauta post: the page reloaded while this post was being watched, reporting that attempt');
			return await running;
		}
		final outcome = _composeAndSubmit(controller, post, js, readJson, state);
		attempt.outcome = outcome;
		return await outcome;
	}

	Future<_PostOutcome> _composeAndSubmit(
		InAppWebViewController controller,
		DraftPost post,
		Future<dynamic> Function(String) js,
		Future<Map<String, dynamic>?> Function(String) readJson,
		Future<Map<String, dynamic>?> Function() state
	) async {
		// A thread is started from the board, a reply is written on the thread.
		final creating = post.threadId == null;
		final initial = await state();
		final before = initial?['highest'] as int? ?? 0;
		final complaintBefore = initial?['complaint'] as String? ?? '';
		debugPrint('ylilauta post: ${creating ? 'starting a thread' : 'replying'}, highest post id before = $before');
		debugPrint('ylilauta post: page = ${await js(_kPostPageProbeJs)}');
		debugPrint('ylilauta post: composer = ${await js(_kPostComposerProbeJs)}');
		debugPrint('ylilauta post: open -> ${await js(creating ? _kPostOpenThreadComposerJs : _kPostOpenComposerJs)}');
		// The composer is built by the site after that click, so wait for it -
		// and for a thread, wait for the dialog's own form rather than any
		// editor that happens to be on the page already.
		final readySelector = creating ? 'dialog.create-thread select[name="board"]' : 'textarea, [contenteditable="true"]';
		for (var attempt = 0; attempt < 24; attempt++) {
			if (await js('!!document.querySelector(${jsonEncode(readySelector)})') == true) {
				break;
			}
			await Future.delayed(const Duration(milliseconds: 250));
		}
		Future<dynamic> fill() => js(_kPostFillJs
			.replaceAll('__TEXT__', jsonEncode(post.text))
			.replaceAll('__SUBJECT__', jsonEncode(post.subject ?? ''))
			.replaceAll('__BOARD__', jsonEncode(creating ? post.board : '')));
		final filled = await fill();
		debugPrint('ylilauta post: fill -> $filled');
		if (filled != 'editor') {
			final page = await readJson(_kPostPageProbeJs);
			debugPrint('ylilauta post: no composer, page = $page');
			// A session that has expired gets a login dialog instead of a
			// composer, which is the site's own answer and worth saying plainly.
			if (page?['loginDialog'] == true) {
				return const _PostOutcome.failure('the site asked for a login instead of taking the post, so the session has expired - log in again from site settings, then post');
			}
			return _PostOutcome.failure('could not find the ${creating ? 'new thread form' : 'reply box'} ($filled)');
		}
		// Putting the text in the box is not the same as the box holding it: the
		// site's own script sometimes re-renders the composer afterwards, and the
		// site then answers "please type a message" to a post that had one -
		// which is what happened to a thread with a video attached, whose text
		// was empty by the time the file had finished uploading. So it is read
		// back, and put in again if the box lost it.
		for (var attempt = 0; attempt < 3; attempt++) {
			final state = await readJson(_kPostFilledJs.replaceAll('__TEXT__', jsonEncode(post.text)));
			if (state?['holds'] == true) {
				break;
			}
			debugPrint('ylilauta post: composer held ${state?['length']} of ${post.text.length} characters, filling again');
			await Future.delayed(const Duration(milliseconds: 400));
			await fill();
		}
		// Files go in before the site is asked to send anything, because the
		// site uploads them itself as soon as it has them, and the post has to
		// carry what those uploads produced.
		if (post.files.isNotEmpty) {
			final problem = await _attachFiles(controller, post);
			if (problem != null) {
				return _PostOutcome.failure(problem);
			}
		}
		final submitted = await js(_kPostSubmitJs.replaceAll('__BOARD__', jsonEncode(creating ? post.board : '')));
		debugPrint('ylilauta post: submit -> $submitted');
		if (submitted is String && submitted.startsWith('no ')) {
			return _PostOutcome.failure(submitted);
		}
		// The site reloads the page when a post lands. A reply shows up as a post
		// id above everything that was there before; a new thread is the page
		// itself, which the site navigates to.
		for (var attempt = 0; attempt < 60; attempt++) {
			await Future.delayed(const Duration(seconds: 1));
			final now = await state();
			if (now == null) {
				// Mid-navigation.
				continue;
			}
			if (creating) {
				final thread = await _newThread(js, post);
				if (thread != null) {
					// The page the site navigated to *is* the new thread, so its
					// slug is known here - and it has to be kept, because the
					// board listing does not show a thread the moment it is
					// created. Without it the app cannot open the thread it just
					// made, and reports a post it cannot find.
					if (thread.slug case final slug?) {
						_knownSlugs[ThreadIdentifier(post.board, thread.id)] = slug;
					}
					debugPrint('ylilauta post: accepted, new thread id ${thread.id} slug ${thread.slug}');
					return _PostOutcome.posted(thread.id);
				}
			}
			else {
				final highest = now['highest'] as int? ?? 0;
				if (highest > before) {
					debugPrint('ylilauta post: accepted, new post id $highest');
					return _PostOutcome.posted(highest);
				}
			}
			// Only something the site started saying after the attempt counts: the
			// page has plenty of error-styled markup of its own.
			final complaint = (now['complaint'] as String?)?.trim();
			if (complaint != null && complaint.isNotEmpty && complaint != complaintBefore) {
				debugPrint('ylilauta post: site said $complaint');
				return _PostOutcome.failure(complaint);
			}
		}
		return _PostOutcome.failure(creating
			? 'the site did not show the new thread within a minute - it may have been created anyway, so check the board before trying again'
			: 'the site did not accept or reject the post within a minute');
	}

	/// How much of a file crosses into the page per round trip. Base64 makes
	/// each round trip a third larger again, so this is what keeps a long video
	/// from having to exist as one enormous string on either side.
	static const _kFileChunkBytes = 512 * 1024;

	/// The name the page calls back for a file's bytes.
	static const _kFileChunkHandler = 'mahdoFileChunk';

	/// Gives the composer the post's files, the way picking them would.
	///
	/// Returns null when the site took every file, or what went wrong.
	///
	/// ylilauta keeps no file field in the post form: `File.select` opens a
	/// media-pack modal whose `input#main-file-upload[name="files"]` the site
	/// uploads itself, to `POST /api/file/upload`, and then adds one hidden
	/// `input[name="file_id[]"]` to the form per file it accepted - that field,
	/// and not the file, is what the post carries. A headless WebView has
	/// nobody to answer the system file picker the input would otherwise open,
	/// so the input is taken as the site builds it and filled with the post's
	/// files. After that the site's own script does the uploading, and the form
	/// ends up holding what a person's pick would have put there.
	///
	/// The site's uploads are watched rather than guessed at: the wait ends
	/// when its own requests to the upload endpoint have settled, and a file it
	/// refused is reported by name instead of being silently left out of the
	/// post.
	Future<String?> _attachFiles(InAppWebViewController controller, DraftPost post) async {
		// The page pulls each file's bytes, a chunk at a time, from here.
		try {
			controller.addJavaScriptHandler(
				handlerName: _kFileChunkHandler,
				callback: (args) async {
					final index = (args.isNotEmpty && args.first is num) ? (args.first as num).toInt() : -1;
					final offset = (args.length > 1 && args[1] is num) ? (args[1] as num).toInt() : 0;
					if (index < 0 || index >= post.files.length) {
						return {'error': 'there is no file $index'};
					}
					final file = post.files[index];
					try {
						final handle = await File(file.path).open();
						try {
							final size = await handle.length();
							final from = offset.clamp(0, size);
							await handle.setPosition(from);
							final bytes = await handle.read(_kFileChunkBytes);
							return {
								// Only the multipart part's name: the site stores
								// and serves the file under its own id whatever
								// this says (`content-disposition` is
								// `<file id>.<ext>`), which is why the reply box
								// does not offer a filename for this site.
								'name': file.overrideFilename ?? file.basename,
								'type': _mimeTypeFor(file.fileExt),
								'size': size,
								'bytes': bytes.length,
								'data': base64Encode(bytes),
								'done': from + bytes.length >= size
							};
						}
						finally {
							await handle.close();
						}
					}
					catch (e) {
						// The page asked for bytes it cannot have, and answering
						// with the reason is what keeps this from looking like a
						// page that said nothing at all - an unreadable file and a
						// thrown script used to be indistinguishable from outside.
						return {'error': '${file.path} could not be read: $e'};
					}
				}
			);
		}
		catch (e) {
			// A previous attempt in this WebView registered it already, and the
			// handler is the same either way.
		}
		final result = await controller.callAsyncJavaScript(functionBody: _kPostAttachJs
			.replaceAll('__COUNT__', '${post.files.length}')
			.replaceAll('__BOARD__', jsonEncode(post.threadId == null ? post.board : ''))
			.replaceAll('__HANDLER__', jsonEncode(_kFileChunkHandler)));
		final value = result?.value;
		if (value is! String || value.isEmpty) {
			// The plugin answers with the script's value or the error it threw,
			// and both are logged: a thrown script and a file that could not be
			// read used to be the same sentence to the user.
			debugPrint('ylilauta post: attach got no report: value = ${result?.value}, error = ${result?.error}');
			final error = result?.error;
			return (error == null)
				? 'the page did not say what became of the file(s)'
				: 'the page could not take the file(s): $error';
		}
		debugPrint('ylilauta post: attach = $value');
		final Map<String, dynamic> report;
		try {
			report = jsonDecode(value) as Map<String, dynamic>;
		}
		catch (e) {
			return 'the page said something unreadable about the file(s)';
		}
		if (report['error'] case final String error) {
			return 'could not attach the file(s): $error';
		}
		final uploads = (report['uploads'] as List?)?.whereType<Map>().toList() ?? const <Map>[];
		if (uploads.isEmpty) {
			return 'the site did not upload the file(s): it may not accept them';
		}
		for (final upload in uploads) {
			final status = upload['status'];
			if (status != 200) {
				final body = (upload['body'] as String?)?.trim() ?? '';
				return 'the site refused an attachment (${status == -1 ? 'the connection failed' : status == -2 ? 'the upload was cancelled' : 'HTTP $status'})'
					'${body.isEmpty ? '' : ': $body'}';
			}
		}
		return null;
	}

	/// The type a browser would give a file of this kind, which is part of what
	/// the site judges an upload by.
	static String _mimeTypeFor(String? extension) => switch (extension) {
		'png' => 'image/png',
		'jpg' || 'jpeg' || 'jfif' => 'image/jpeg',
		'gif' => 'image/gif',
		'webp' => 'image/webp',
		'avif' => 'image/avif',
		'mp4' || 'm4v' => 'video/mp4',
		'webm' => 'video/webm',
		'mov' => 'video/quicktime',
		'mkv' => 'video/x-matroska',
		'ogv' => 'video/ogg',
		'3gp' => 'video/3gpp',
		'mp3' => 'audio/mpeg',
		'm4a' => 'audio/mp4',
		'flac' => 'audio/flac',
		'ogg' || 'oga' => 'audio/ogg',
		'aac' => 'audio/aac',
		_ => 'application/octet-stream'
	};

	/// The id of the thread the page is showing, if it is showing one, and the
	/// slug it is addressed by.
	///
	/// A new thread is addressed by its slug, so neither is in the composer: the
	/// id comes from the thread's own markup, where the starter's post is marked
	/// `op`, and the slug from the address the site navigated to once the post
	/// landed.
	Future<({int id, String? slug})?> _newThread(Future<dynamic> Function(String) js, DraftPost post) async {
		final result = await js(_kPostNewThreadJs
			.replaceAll('__SUBJECT__', jsonEncode(post.subject ?? ''))
			.replaceAll('__TEXT__', jsonEncode(post.text)));
		if (result is! String || result.isEmpty) {
			return null;
		}
		final Map<String, dynamic> state;
		try {
			state = jsonDecode(result) as Map<String, dynamic>;
		}
		catch (e) {
			return null;
		}
		final id = state['threadId'] as int? ?? 0;
		return id > 0 ? (id: id, slug: state['slug'] as String?) : null;
	}

	// ------------------------------------------------------------------ vote

	/// Casts or retracts this session's upvote on [post] by driving the site's
	/// own upvote control, and returns [post] carrying the count and vote state
	/// the site reports afterwards.
	///
	/// The request cannot be made from here for the same reason a post cannot:
	/// it carries the session's own `x-csrf-token` and has to look like a real
	/// browser, so the page makes it. `Module/Action/PostAction.js` is the site's
	/// handler: it toggles the control's `active` class, adjusts the count in
	/// `span.post-upvotes[data-count]`, and then posts to
	/// `/api/community/post/vote` or `/api/community/post/unvote` with the post
	/// id - reverting both on failure. So the *direction* is the page's to
	/// decide, which is why nothing here reads the app's own copy of the post to
	/// choose between voting and unvoting.
	///
	/// The state that comes back is the site's own optimistic update rather than
	/// something the server rendered (it happens before the request is sent), so
	/// a successful vote is remembered even though no signed-in page has been
	/// seen that renders the voted state.
	@override
	Future<Post> togglePostUpvote(Post post, {CancelToken? cancelToken}) async {
		// The same two gates as [submitPost]: there is no anonymous voting, and
		// the page is the authority on whether the session still works.
		if (loginSystem.getSavedLoginFields() == null) {
			throw Exception('Log in to ylilauta first - site settings, then Account.');
		}
		if (_signedIn == false) {
			throw Exception('ylilauta is not signed in on this device - the last page it served offered a login rather than a session. Log in from site settings, then try again.');
		}
		final page = Uri.https(baseUrl, '/${post.board}/${await _resolveSlug(ThreadIdentifier(post.board, post.threadId), priority: RequestPriority.interactive, cancelToken: cancelToken)}');
		debugPrint('ylilauta vote: post ${post.id} on $page');
		// One attempt, shared by every handler run the WebView makes: the page
		// can navigate while the vote is in flight, and that run reports this
		// attempt's outcome rather than voting a second time.
		final attempt = _VoteAttempt();
		final outcome = await useCloudflareClearedWebview<_VoteOutcome>(
			site: this,
			uri: page,
			priority: RequestPriority.interactive,
			gatewayName: _kVoteGatewayName,
			// The page has to render before its own control can be clicked. The
			// script that does the clicking is bounded well inside this, so the
			// window is only reached when the page itself never loads - which is
			// when the authorization prompt is the right answer.
			headlessTime: const Duration(seconds: 30),
			cancelToken: cancelToken,
			handler: (controller, uri) => _voteInPage(controller, post, attempt)
		);
		if (outcome.error case final error?) {
			throw Exception('ylilauta: $error');
		}
		debugPrint('ylilauta vote: post ${post.id} is now ${outcome.upvoted ? 'upvoted' : 'not upvoted'} with ${outcome.upvotes}');
		return post.copyWith(upvotes: outcome.upvotes, upvoted: outcome.upvoted);
	}

	/// Runs [post]'s vote in the loaded page, once per WebView however many
	/// times the handler is entered for it.
	Future<_VoteOutcome> _voteInPage(InAppWebViewController controller, Post post, _VoteAttempt attempt) async {
		if (attempt.outcome case final running?) {
			debugPrint('ylilauta vote: the page reloaded while this vote was being watched, reporting that attempt');
			return await running;
		}
		final outcome = _castVoteInPage(controller, post);
		attempt.outcome = outcome;
		return await outcome;
	}

	Future<_VoteOutcome> _castVoteInPage(InAppWebViewController controller, Post post) async {
		final result = await controller.callAsyncJavaScript(functionBody: _kVoteInPageJs
			.replaceAll('__POST_ID__', post.id.toString()));
		final value = result?.value;
		if (value is! String || value.isEmpty) {
			return const _VoteOutcome.failure('the page did not say what became of the upvote');
		}
		debugPrint('ylilauta vote: $value');
		final Map<String, dynamic> report;
		try {
			report = jsonDecode(value) as Map<String, dynamic>;
		}
		catch (e) {
			return _VoteOutcome.failure('the page said something unreadable about the upvote ($value)');
		}
		if (report['error'] case final String error) {
			return _VoteOutcome.failure(error);
		}
		final status = (report['status'] as num?)?.toInt();
		if (status == null || status < 200 || status > 299) {
			final body = (report['body'] as String?)?.trim() ?? '';
			return _VoteOutcome.failure('the site refused the upvote'
				'${status == null ? '' : ' (HTTP $status)'}'
				'${body.isEmpty ? '' : ': $body'}');
		}
		// What the app just did is the direction the page's own control was not
		// already in, and the site's handler applied it before sending anything.
		final voted = report['voted'] as bool? ?? !(report['activeBefore'] as bool? ?? false);
		final countBefore = (report['countBefore'] as num?)?.toInt() ?? post.upvotes;
		final countFromPage = (report['count'] as num?)?.toInt();
		final domVoted = report['domVoted'] as bool?;
		if (domVoted != null && domVoted != voted) {
			// Only possible if the site's own handler did not update its control;
			// worth knowing about, since the count below is then the only clue.
			debugPrint('ylilauta vote: the control says $domVoted after asking for $voted');
		}
		int? expected;
		if (countBefore != null) {
			expected = countBefore + (voted ? 1 : -1);
			if (expected < 0) {
				expected = 0;
			}
		}
		return _VoteOutcome.voted(countFromPage ?? expected ?? (voted ? 1 : 0), voted);
	}

	// ------------------------------------------------------------ span format

	/// Parses ylilauta's post body markup into Chance's span tree.
	///
	/// Bodies are real HTML, but the vocabulary is small: `span.ref` is a quote
	/// link (carrying `data-post-id`), and `span.quote` / `span.quote.blue`
	/// colour inline quotes. Everything else is text.
	static PostNodeSpan makeSpan(String board, int threadId, String html) {
		final body = parseFragment(html);
		Iterable<PostSpan> visit(Iterable<dom.Node> nodes) sync* {
			for (final node in nodes) {
				if (node is dom.Text) {
					yield PostTextSpan(node.text);
				}
				else if (node is dom.Element) {
					if (node.localName == 'br') {
						yield const PostLineBreakSpan();
					}
					else if (node.classes.contains('ref')) {
						final postId = node.attributes['data-post-id']?.tryParseInt;
						if (postId != null) {
							yield PostQuoteLinkSpan(board: board, threadId: threadId, postId: postId);
						}
					}
					else if (node.classes.contains('quote')) {
						final inner = PostNodeSpan(visit(node.nodes).toList(growable: false));
						yield node.classes.contains('blue') ? PostBlueQuoteSpan(inner) : PostQuoteSpan(inner);
					}
					else if (node.localName == 'a') {
						if (node.attributes['href'] case final href?) {
							yield PostLinkSpan(
								Uri.tryParse(href)?.hasScheme ?? false ? href : Uri.https('ylilauta.org', href).toString(),
								name: node.text.nonEmptyOrNull
							);
						}
					}
					else if (node.children.isNotEmpty) {
						// Recurse so nested markup is not swallowed.
						yield* visit(node.nodes);
					}
					else {
						yield PostTextSpan(node.text);
					}
				}
			}
		}
		return PostNodeSpan(visit(body.nodes).toList(growable: false));
	}

	@override
	bool operator ==(Object other) =>
		identical(this, other) ||
		(other is SiteYlilauta) && super == (other);

	@override
	int get hashCode => baseUrl.hashCode;
}

/// `new Captcha('<site key>')`, used inline on challenge pages.
final _kCaptchaSiteKeyPattern = RegExp(r'''new Captcha\(['"]([0-9a-fA-F-]{36})['"]''');

/// The bot interstitial's document title.
final _kChallengeTitlePattern = RegExp(r'<title>\s*Beep boop\?', caseSensitive: false);

/// What came of one attempt to log in.
class _LoginOutcome {
	final bool ok;
	final String? error;

	const _LoginOutcome(this.ok, this.error);
}

/// Logs in to ylilauta by driving the site's own login dialog in a WebView.
///
/// The credentials cannot be posted from here. Every request to ylilauta has to
/// look like a real browser - Dart's TLS stack is refused at the edge - and the
/// site signs its Ajax requests with a token that only the loaded page has, so
/// posting `/modal/user/login` (which is what the dialog does) is answered with
/// "Invalid or expired session" rather than a form. Filling the page's own form
/// and letting its own script submit it avoids both problems.
class SiteYlilautaLoginSystem extends ImageboardSiteLoginSystem {
	static const _kLoginDialogAction = 'User.login';

	@override
	final SiteYlilauta parent;

	SiteYlilautaLoginSystem(this.parent);

	/// Names the mechanism, not the site - the site's own name is already next to
	/// this button, and the login dialog is titled "${name} Login".
	@override
	String get name => 'Account';

	@override
	bool get hidden => false;

	/// The queue gives an attempt 15 seconds and this login is a dialog the
	/// loaded page builds, so an automatic one would open a login window over
	/// whatever the user was doing, be cancelled, and leave the session it
	/// already had untouched. Posts check for credentials instead, and the
	/// thread page is the authority on whether the session still works.
	@override
	bool get autoLoginBeforePosting => false;

	@override
	List<ImageboardSiteLoginField> getLoginFields() => const [
		ImageboardSiteLoginField(
			displayName: 'Username',
			formKey: 'username',
			autofillHints: [AutofillHints.username]
		),
		ImageboardSiteLoginField(
			displayName: 'Password',
			formKey: 'password',
			autofillHints: [AutofillHints.password]
		)
	];

	/// What the header says about the account, read from any page the app has
	/// fetched; failing that, from one page fetched here.
	///
	/// The experience behind the level is kept, because that is what the level
	/// is made of and the site shows it in the tooltip; the level is what
	/// decides whether a board will take a post.
	@override
	Future<String?> getAccountSummary() async {
		var account = parent._account;
		if (account == null) {
			try {
				final html = await parent._fetchHtml(Uri.https(parent.baseUrl, '/'), priority: RequestPriority.cosmetic);
				account = parent._account;
				if (account == null && SiteYlilauta.signedInFromHtml(html) == false) {
					return 'Not signed in - ylilauta is showing this device a logged-out page';
				}
			}
			catch (e) {
				// Nothing to say is better than a spinner that never ends.
				return null;
			}
		}
		if (account == null) {
			return null;
		}
		return 'Signed in as ${account.name}\n${account.level}'
			'${account.experience == null ? '' : '\n${account.experience}'}';
	}

	@override
	Future<void> login(Map<ImageboardSiteLoginField, String> fields, CancelToken cancelToken) async {
		final home = Uri.https(parent.baseUrl, '/');
		final outcome = await useCloudflareClearedWebview<_LoginOutcome>(
			site: parent,
			uri: home,
			// The user is here to do this on purpose, so let the dialog be shown
			// if it takes longer than a headless attempt allows - a captcha on the
			// login is solvable by hand in that window, and the attempt carries on.
			priority: RequestPriority.interactive,
			gatewayName: parent.name,
			headlessTime: const Duration(seconds: 12),
			cancelToken: cancelToken,
			handler: (controller, uri) => _attemptLogin(controller, {
				for (final entry in fields.entries) entry.key.formKey: entry.value
			})
		);
		if (!outcome.ok) {
			loggedIn[Persistence.currentCookies] = false;
			throw ImageboardSiteLoginException(outcome.error ?? 'ylilauta did not accept the login');
		}
		// The helper saved the cookie jar before the handler ran, so the session
		// cookies the login just set would go with the WebView when it is disposed.
		await Persistence.saveCookiesFromWebView(home);
		loggedIn[Persistence.currentCookies] = true;
	}

	/// Opens the dialog, fills it, submits it, and waits for the site to say how
	/// it went. Runs inside the page, which is the only place the login can happen.
	static Future<_LoginOutcome> _attemptLogin(InAppWebViewController controller, Map<String, String> credentials) async {
		Future<String> js(String source) async {
			final result = await controller.evaluateJavascript(source: source);
			return result is String ? result : '';
		}

		await js('''
			(() => {
				const button = document.querySelector('[data-action="$_kLoginDialogAction"]');
				if (button) {
					button.click();
				}
			})();
		''');
		// The dialog is fetched by Ajax, so it is not there straight away.
		var dialogAppeared = false;
		for (var attempt = 0; attempt < 80; attempt++) {
			if (await controller.evaluateJavascript(source: "!!document.querySelector('input[name=password]')") == true) {
				dialogAppeared = true;
				break;
			}
			await Future.delayed(const Duration(milliseconds: 250));
		}
		if (!dialogAppeared) {
			return const _LoginOutcome(false, 'The ylilauta login dialog did not appear.');
		}
		final submitted = await js('''
			(() => {
				const password = document.querySelector('input[name=password]');
				const form = password && password.form;
				if (!form) {
					return 'no form';
				}
				// The site announces the outcome on the form itself, which is a
				// better answer than anything guessed from the page afterwards.
				// It reloads the page on success, so the flag has to be read
				// before that happens.
				window.__chanceLogin = {ok: false, error: null};
				form.addEventListener('login-form-submit-success', () => {
					window.__chanceLogin.ok = true;
				});
				form.addEventListener('login-form-submit-fail', (e) => {
					window.__chanceLogin.error = (e.detail && e.detail.response) || 'Login failed.';
				});
				const fill = (name, value) => {
					const input = form.querySelector('input[name="' + name + '"]');
					if (!input) {
						return false;
					}
					input.value = value;
					input.dispatchEvent(new Event('input', {bubbles: true}));
					return true;
				};
				if (!fill('username', ${jsonEncode(credentials['username'] ?? '')})) {
					return 'no username field';
				}
				if (!fill('password', ${jsonEncode(credentials['password'] ?? '')})) {
					return 'no password field';
				}
				if (form.requestSubmit) {
					form.requestSubmit();
				}
				else {
					form.dispatchEvent(new Event('submit', {bubbles: true, cancelable: true}));
				}
				return 'submitted';
			})();
		''');
		if (submitted != 'submitted') {
			return _LoginOutcome(false, 'ylilauta login form: $submitted');
		}
		// Long enough for a captcha to be solved by hand in the prompt, since the
		// attempt is still being watched while that window is open.
		for (var attempt = 0; attempt < 120; attempt++) {
			final state = await js('''
				(() => {
					const state = window.__chanceLogin;
					if (state && state.ok) {
						return 'ok';
					}
					if (state && state.error) {
						return 'error:' + state.error;
					}
					// A reload wipes the flag, so a page that no longer offers a
					// login - and has no form open - is the fallback answer.
					if (!document.querySelector('input[name=password]') &&
						!document.querySelector('[data-action="$_kLoginDialogAction"]')) {
						return 'ok';
					}
					return '';
				})();
			''');
			if (state == 'ok') {
				return const _LoginOutcome(true, null);
			}
			if (state.startsWith('error:')) {
				final mfa = await controller.evaluateJavascript(source: "!!document.querySelector('#totp-code, #backup-code')") == true;
				if (mfa) {
					// The site answers a password-only login with 401 and then asks
					// for a second factor, which this does not fill in.
					return const _LoginOutcome(false, 'This account has multi-factor authentication, which this build cannot complete. Log in from the site itself in the browser instead.');
				}
				return _LoginOutcome(false, state.substring('error:'.length));
			}
			await Future.delayed(const Duration(milliseconds: 500));
		}
		return const _LoginOutcome(false, 'ylilauta did not answer the login attempt.');
	}

	@override
	Future<void> logoutImpl(bool fromBothWifiAndCellular, CancelToken cancelToken) async {
		// The site's own logout is another token-signed Ajax call, and there is no
		// way to make it from here. Dropping the cookies ends the session as far as
		// this app is concerned, which is what the button means.
		final home = Uri.https(parent.baseUrl, '/');
		loggedIn[Persistence.currentCookies] = false;
		await Persistence.currentCookies.deletePreservingCloudflare(home);
		await CookieManager.instance().deleteCookies(url: WebUri.uri(home));
		if (fromBothWifiAndCellular) {
			await Persistence.nonCurrentCookies.deletePreservingCloudflare(home);
			await CookieManager.instance().deleteCookies(url: WebUri.uri(home));
			loggedIn[Persistence.nonCurrentCookies] = false;
		}
	}
}

/// What came of one attempt to post.
class _PostOutcome {
	final int? postId;
	final String? error;

	const _PostOutcome.posted(this.postId) : error = null;
	const _PostOutcome.failure(this.error) : postId = null;
}

/// One attempt to post, shared by the handler runs the WebView makes for it.
///
/// Submitting a thread navigates the WebView, so the handler is entered again
/// for the page that arrives. Both runs read this, so the second one reports
/// the first one's outcome rather than posting a second time.
class _PostAttempt {
	Future<_PostOutcome>? outcome;
}

/// What came of one attempt to upvote a post.
class _VoteOutcome {
	final int upvotes;
	final bool upvoted;
	final String? error;

	const _VoteOutcome.voted(this.upvotes, this.upvoted) : error = null;
	const _VoteOutcome.failure(this.error) : upvotes = 0, upvoted = false;
}

/// One attempt to vote, shared by the handler runs the WebView makes for it.
///
/// The page can navigate while the vote is in flight, which enters the handler
/// again for the page that arrives; both runs read this, so the second reports
/// the first one's outcome rather than clicking the control a second time
/// (which would take the vote back).
class _VoteAttempt {
	Future<_VoteOutcome>? outcome;
}

/// The site's reply box is built by its own scripts, so opening it means
/// clicking whatever the site put there to open it.
const _kPostOpenComposerJs = r"""
(() => {
	if (document.querySelector('textarea, [contenteditable="true"]')) {
		return 'already open';
	}
	const opener = document.querySelector('[data-action="Post.reply"], [data-action="Thread.reply"], button.reply');
	if (!opener) {
		return 'no way to open the reply box';
	}
	opener.click();
	return 'clicked opener';
})()
""";

/// Whether the loaded page is a thread the session can reply to, or a page
/// whose reply box is really a login.
///
/// The header goes with it, because the only view into what the WebView is
/// logged in as - which is not something the cookie jar can be asked - is what
/// the site puts at the top of its own page.
const _kPostPageProbeJs = r"""
JSON.stringify({
	login: !!document.querySelector('[data-action="User.login"]'),
	loginDialog: !!document.querySelector('input[name=password]'),
	reply: !!document.querySelector('[data-action="Post.reply"], [data-action="Thread.reply"], button.reply'),
	composer: !!document.querySelector('form[action*="post/create"]'),
	header: (document.querySelector('header')?.innerText || '').replace(/\s+/g, ' ').trim().slice(0, 300)
})
""";

/// Starting a thread is a control on the board page rather than a box that is
/// already there, and the site answers it by opening the new thread composer -
/// by navigating to it, in the captures this was built from.
const _kPostOpenThreadComposerJs = r"""
(() => {
	if (document.querySelector('dialog.create-thread select[name="board"]')) {
		return 'already open';
	}
	const opener = document.querySelector('[data-action="Thread.create"]');
	if (!opener) {
		return 'no way to start a thread';
	}
	opener.click();
	return 'clicked opener';
})()
""";

/// The thread a page is showing, if it is showing one at all.
///
/// A new thread's id is not in its address - ylilauta addresses threads by slug
/// - so it comes from the markup, and it is the *thread's* id rather than its
/// opening post's: those are different numbers here (a thread and its starter
/// are counted separately), and using the post's id produced an address that
/// could not resolve, which the app reported as a post it could not find.
///
/// The card is chosen by the address the page is on, not by being the first
/// `[data-thread-id]` in the document: a page lists threads in more than one
/// place, and taking whichever came first would read the id of a thread that
/// only happens to be linked from this one.
///
/// The slug is reported only when a card carries it, which is what a page that
/// navigated into the new thread looks like; the board listing does not show a
/// thread the moment it is created, and a board page has no such card.
///
/// As a fallback, a board listing that has a card whose text is the one that
/// was just submitted counts too, since the site may go back to the board
/// rather than into the thread.
const _kPostNewThreadJs = r"""
JSON.stringify((() => {
	const parts = location.pathname.split('/').filter((p) => p.length > 0);
	const fromAddress = parts.length > 0 ? parts[parts.length - 1] : null;
	const cards = [...document.querySelectorAll('[data-thread-id]')];
	const slugOf = (card) => {
		const url = card.getAttribute('data-url');
		const urlParts = (url || '').split('/').filter((p) => p.length > 0);
		return urlParts.length > 0 ? urlParts[urlParts.length - 1] : null;
	};
	const idOf = (card) => card ? (parseInt(card.getAttribute('data-thread-id'), 10) || 0) : 0;
	let card = (fromAddress && cards.find((c) => slugOf(c) === fromAddress)) || null;
	if (!card) {
		const subject = __SUBJECT__;
		const opening = __TEXT__.split('\n')[0].slice(0, 40).toLowerCase();
		card = cards.find((c) => {
			const text = (c.innerText || '').toLowerCase();
			return (subject && text.includes(subject.toLowerCase())) || (opening.length > 8 && text.includes(opening));
		}) || null;
	}
	return {
		path: location.pathname,
		slug: (card && slugOf(card) === fromAddress) ? fromAddress : null,
		threadId: idOf(card)
	};
})())
""";

/// What the page's composer looks like, logged because it is the site's own
/// markup and there is no other way to see its shape.
const _kPostComposerProbeJs = r"""
JSON.stringify({
	forms: [...document.querySelectorAll('form')].map((f) => ({
		action: f.getAttribute('action'),
		fields: [...f.querySelectorAll('input, textarea, select')].map((e) => e.tagName + '[' + (e.name || e.id || '') + ']')
	})),
	editables: [...document.querySelectorAll('[contenteditable="true"]')].map((e) => e.className),
	textareas: [...document.querySelectorAll('textarea')].map((e) => e.name || e.id || ''),
	actions: [...new Set([...document.querySelectorAll('[data-action]')].map((e) => e.dataset.action))].slice(0, 40)
})
""";

/// Whether the composer actually holds the text that was put in it.
///
/// A composer whose own script re-renders leaves the box empty, and the site
/// then refuses the post with "please type a message".
const _kPostFilledJs = r"""
JSON.stringify((() => {
	const want = __TEXT__;
	const box = document.querySelector('form[action*="post/create"] textarea') || document.querySelector('textarea');
	const have = box ? box.value : null;
	return {found: !!box, holds: have === want, length: have ? have.length : 0};
})())
""";

/// Puts the post's text where the site expects to read it.
const _kPostFillJs = r"""
(() => {
	const TEXT = __TEXT__;
	const SUBJECT = __SUBJECT__;
	const BOARD = __BOARD__;
	const boardFieldFor = (f) => f && f.querySelector('select[name="board"], input[name="board"]');
	if (SUBJECT) {
		const subjectField = document.querySelector('input[name="subject"], input[name="title"], input[name="otsikko"]');
		if (subjectField) {
			subjectField.value = SUBJECT;
			subjectField.dispatchEvent(new Event('input', {bubbles: true}));
		}
	}
	// A new thread is written in the dialog's own form, which is the one that
	// knows about boards - and whose board select starts on a disabled
	// placeholder, which is what the site complains about if it is left there.
	const forms = [...document.querySelectorAll('form[action*="post/create"]')];
	const form = (BOARD && forms.find(boardFieldFor))
		|| forms[0]
		|| [...document.querySelectorAll('form')].find((f) => f.querySelector('textarea, [contenteditable="true"]'));
	if (BOARD) {
		const boardField = boardFieldFor(form);
		if (boardField) {
			if (boardField.tagName === 'SELECT') {
				boardField.value = BOARD;
				if (boardField.value !== BOARD) {
					const option = [...boardField.options].find((o) => o.value === BOARD);
					if (option) {
						for (const o of boardField.options) o.selected = false;
						option.selected = true;
					}
				}
			}
			else {
				boardField.value = BOARD;
			}
			boardField.dispatchEvent(new Event('input', {bubbles: true}));
			boardField.dispatchEvent(new Event('change', {bubbles: true}));
		}
		// Fall through to the message: the board is only half of a new thread,
		// and returning here is what made the site answer "please type a
		// message" to a post that had one.
		if (!boardFieldFor(form)) {
			return 'no board field';
		}
	}
	const textarea = (form && form.querySelector('textarea')) || document.querySelector('textarea');
	if (textarea) {
		textarea.value = TEXT;
		textarea.dispatchEvent(new Event('input', {bubbles: true}));
		textarea.dispatchEvent(new Event('change', {bubbles: true}));
		return 'editor';
	}
	const editables = [...document.querySelectorAll('[contenteditable="true"]')];
	const editable = editables.find((e) => e.offsetParent !== null) || editables[0];
	if (editable) {
		editable.focus();
		editable.innerHTML = '';
		for (const line of TEXT.split('\n')) {
			const block = document.createElement('div');
			block.textContent = line.length > 0 ? line : '\u00a0';
			editable.appendChild(block);
		}
		editable.dispatchEvent(new Event('input', {bubbles: true}));
		return 'editor';
	}
	return 'no editor';
})()
""";

/// Presses the site's own submit control, so its own script builds the request.
const _kPostSubmitJs = r"""
(() => {
	const BOARD = __BOARD__;
	const forms = [...document.querySelectorAll('form[action*="post/create"]')];
	const form = (BOARD && forms.find((f) => f.querySelector('select[name="board"], input[name="board"]')))
		|| forms[0]
		|| [...document.querySelectorAll('form')].find((f) => f.querySelector('textarea, [contenteditable="true"]'));
	if (!form) {
		return 'no reply form';
	}
	const controls = [...form.querySelectorAll('button, input[type="submit"]')];
	const submit = controls.find((b) => /(lähetä|vastaa|post|reply|send)/i.test(b.textContent || b.value || '')) || controls[controls.length - 1];
	if (submit) {
		submit.click();
		return 'clicked ' + ((submit.textContent || submit.value || '').trim().slice(0, 24));
	}
	if (form.requestSubmit) {
		form.requestSubmit();
		return 'requestSubmit';
	}
	form.dispatchEvent(new Event('submit', {bubbles: true, cancelable: true}));
	return 'dispatched submit';
})()
""";

/// Gives the composer the post's files, the way a pick would.
///
/// ylilauta holds no file field in the post form: `File.select` opens a
/// media-pack modal whose `input#main-file-upload[name="files"]` the site
/// uploads itself, to `POST /api/file/upload`, and then adds one hidden
/// `input[name="file_id[]"]` per file it accepted - that field, not the file,
/// is what the post carries. A headless WebView has nobody to answer the
/// system file picker the input would otherwise open, so the input is taken as
/// the site builds it and filled with the post's files. After that the site's
/// own code uploads them, and the form holds what a person's pick would have
/// put there.
///
/// It answers with what the site did with them, so a file that never uploaded
/// is something the caller can name rather than a post that quietly lost it.
const _kPostAttachJs = r"""
return (async () => {
	// Whatever happens in here answers with a report: a script that throws is
	// otherwise indistinguishable from one that did nothing.
	const report = {steps: []};
	try {
		return await attach();
	}
	catch (e) {
		// What was found before the throw goes with it: otherwise a failure here
		// does not even say whether the composer had a file control.
		return JSON.stringify({
			error: 'the page threw while attaching: ' + (e && e.message ? e.message : e),
			steps: report.steps,
			input: report.input
		});
	}

	async function attach() {
	const COUNT = __COUNT__;
	const BOARD = __BOARD__;
	const HANDLER = __HANDLER__;
	const later = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
	const boardFieldFor = (f) => f && f.querySelector('select[name="board"], input[name="board"]');
	const forms = [...document.querySelectorAll('form[action*="post/create"]')];
	const form = (BOARD && forms.find(boardFieldFor)) || forms[0] || [...document.querySelectorAll('form')].find((f) => f.querySelector('textarea'));
	// The system file picker is what this control would normally open, and
	// there is nobody here to answer it, so it is held back. The input the site
	// builds is what is wanted, not the dialog around it.
	try {
		HTMLInputElement.prototype.showPicker = function() {
			report.steps.push('held back the system picker');
		};
	}
	catch (e) {
	}
	const originalClick = HTMLInputElement.prototype.click;
	HTMLInputElement.prototype.click = function() {
		if (this.type === 'file') {
			report.steps.push('took the file input the site built');
			window.__mahdoFileInput = this;
			return undefined;
		}
		return originalClick.apply(this, arguments);
	};
	const select = (form && form.querySelector('[data-action="File.select"]')) || document.querySelector('[data-action="File.select"]');
	if (!select) {
		return JSON.stringify({error: 'this composer has no file control', steps: report.steps});
	}
	select.click();
	let input = window.__mahdoFileInput || null;
	for (let attempt = 0; attempt < 40 && !input; attempt++) {
		await later(150);
		input = window.__mahdoFileInput || document.querySelector('input[type=file][name="files"], input[type=file]');
	}
	if (!input) {
		return JSON.stringify({error: 'the site did not offer a file input', steps: report.steps});
	}
	report.input = input.id + ' name=' + input.name + ' accept=' + input.accept + ' max=' + input.getAttribute('data-max-size');
	// The site's own uploads are watched, so the wait for them is exact rather
	// than a guess at how long they take.
	const uploads = [];
	const originalOpen = XMLHttpRequest.prototype.open;
	XMLHttpRequest.prototype.open = function(method, url, ...rest) {
		this.__mahdoUrl = url;
		return originalOpen.call(this, method, url, ...rest);
	};
	const originalSend = XMLHttpRequest.prototype.send;
	XMLHttpRequest.prototype.send = function(...args) {
		const entry = {url: String(this.__mahdoUrl || ''), status: null, body: ''};
		const watching = /\/api\/file\/upload/.test(entry.url);
		if (watching) {
			uploads.push(entry);
			const body = args[0];
			if (typeof FormData !== 'undefined' && body instanceof FormData) {
				try {
					entry.files = [...body.entries()].map(([k, v]) => k + '=' + (v && v.name ? v.name + ' ' + (v.size || 0) + 'B ' + v.type : String(v)));
				}
				catch (e) {
				}
			}
			this.addEventListener('load', () => {
				entry.status = this.status;
				try {
					entry.body = String(this.responseText || '').slice(0, 300);
				}
				catch (e) {
					entry.body = '(unreadable)';
				}
			});
			this.addEventListener('error', () => {
				entry.status = -1;
			});
			this.addEventListener('abort', () => {
				entry.status = -2;
			});
		}
		return originalSend.apply(this, args);
	};
	const transfer = new DataTransfer();
	for (let index = 0; index < COUNT; index++) {
		let offset = 0;
		let info = null;
		const parts = [];
		while (true) {
			const chunk = await window.flutter_inappwebview.callHandler(HANDLER, index, offset);
			if (!chunk || chunk.error) {
				return JSON.stringify({error: 'file ' + index + ' could not be read: ' + (chunk && chunk.error), steps: report.steps});
			}
			info = info || chunk;
			// Each chunk is base64 on its own, padding and all, so they are
			// decoded one at a time: joining the encoded strings and decoding
			// once is invalid past the first chunk, which is what made every
			// file bigger than one chunk fail with "the string to be decoded is
			// not correctly encoded".
			parts.push(atob(chunk.data));
			offset += chunk.bytes;
			if (chunk.done) {
				break;
			}
		}
		const binary = parts.join('');
		const bytes = new Uint8Array(binary.length);
		for (let i = 0; i < binary.length; i++) {
			bytes[i] = binary.charCodeAt(i);
		}
		transfer.items.add(new File([bytes], info.name, {type: info.type}));
	}
	input.files = transfer.files;
	input.dispatchEvent(new Event('input', {bubbles: true}));
	input.dispatchEvent(new Event('change', {bubbles: true}));
	// A batch may leave as more than one request, so the wait ends when the
	// uploads have settled and nothing new has started for a moment.
	let quiet = 0;
	const deadline = Date.now() + 180000;
	while (Date.now() < deadline) {
		await later(300);
		if (uploads.length > 0 && uploads.every((u) => u.status !== null)) {
			quiet += 300;
			if (quiet >= 1500) {
				break;
			}
		}
		else {
			quiet = 0;
		}
	}
	report.uploads = uploads;
	report.fields = [...(form || document).querySelectorAll('input, textarea')].map((e) => e.tagName + '[' + (e.name || e.id || '') + ']=' + String(e.value || '').slice(0, 60));
	report.complaints = [...document.querySelectorAll('.toast, [class*="error" i], [class*="alert" i]')].map((e) => (e.innerText || '').replace(/\s+/g, ' ').trim()).filter((t) => t.length > 0).slice(0, 6);
	return JSON.stringify(report);
	}
})();
""";

/// The thread's own state: the newest post id present, and anything the site is
/// currently saying that it was not saying before.
const _kPostStateJs = r"""
JSON.stringify({
	highest: Math.max(0, ...[...document.querySelectorAll('[data-post-id]')]
		.map((e) => parseInt(e.getAttribute('data-post-id'), 10) || 0)),
	complaint: [...document.querySelectorAll('.toast, [class*="error"], [class*="Error"]')]
		.map((e) => (e.innerText || '').trim())
		.filter((t) => t.length > 0 && t.length < 300)
		.join(' | ')
})
""";

/// Clicks the post's own upvote control and reports what the page did with it.
///
/// The site's own handler is what makes the request
/// (`/api/community/post/vote` or `/unvote`), so this only presses the control
/// and watches: the class it toggles (`active`), the count it rewrites, and the
/// `XMLHttpRequest` it sends. Nothing here computes the vote itself - the site
/// decides the direction from the control's own state, which is why the app
/// must not.
///
/// The module that installs the click handler is loaded asynchronously
/// (`new App(...)` imports `Locale/<locale>.default.js` first), so a click
/// during that window is swallowed. The site's own `Ajax` calls `open()`
/// synchronously inside the handler, so "a vote request appeared" is an exact
/// test of "the handler was attached": the click is repeated only while no
/// request was seen, which cannot toggle a vote twice.
///
/// Always returns a bounded JSON verdict - never null, which the WebView helper
/// reads as "not ready yet" and waits out.
const _kVoteInPageJs = r"""
return (async () => {
	const postId = __POST_ID__;
	const selector = 'button[data-action="Post.upvote"][data-post-id="' + postId + '"]';
	if (!document.querySelector(selector)) {
		return JSON.stringify({error: 'the page has no upvote control for post ' + postId});
	}
	const calls = [];
	if (!window.__mahdoVoteCalls) {
		window.__mahdoVoteCalls = calls;
		const nativeOpen = XMLHttpRequest.prototype.open;
		XMLHttpRequest.prototype.open = function (method, url) {
			const call = {url: String(url), status: null, done: false, body: null};
			calls.push(call);
			this.addEventListener('loadend', () => {
				call.status = this.status;
				call.done = true;
				try {
					call.body = (this.responseText || '').slice(0, 300);
				}
				catch (e) {
				}
			});
			return nativeOpen.apply(this, arguments);
		};
	}
	const read = () => {
		const button = document.querySelector(selector);
		const count = button && button.querySelector('.post-upvotes');
		return {
			active: !!button && button.classList.contains('active'),
			count: count ? parseInt(count.dataset.count || '0', 10) : null
		};
	};
	const before = read();
	let call = null;
	for (let attempt = 0; attempt < 6 && !call; attempt++) {
		const button = document.querySelector(selector);
		if (!button) {
			return JSON.stringify({error: 'the upvote control left the page while the vote was being made'});
		}
		button.click();
		for (let i = 0; i < 20 && !call; i++) {
			// Only the vote endpoints count: the page polls other ones itself.
			call = window.__mahdoVoteCalls.find((c) => /\/api\/community\/post\/(un)?vote(\?|$)/.test(c.url));
			if (!call) {
				await new Promise((resolve) => setTimeout(resolve, 50));
			}
		}
		if (!call) {
			await new Promise((resolve) => setTimeout(resolve, 500));
		}
	}
	if (!call) {
		return JSON.stringify({
			error: 'the page did not act on the upvote click - its own scripts may not be loaded yet',
			activeBefore: before.active,
			countBefore: before.count
		});
	}
	for (let i = 0; i < 50 && !call.done; i++) {
		await new Promise((resolve) => setTimeout(resolve, 100));
	}
	const after = read();
	return JSON.stringify({
		// The site's handler applied this before sending the request, and undoes
		// it if the request fails - so with a 2xx this is what just happened.
		voted: !before.active,
		domVoted: after.active,
		countBefore: before.count,
		count: after.count,
		activeBefore: before.active,
		request: call.url,
		status: call.status,
		body: call.body
	});
})()
""";
