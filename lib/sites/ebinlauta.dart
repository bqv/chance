import 'dart:convert';
import 'dart:io';

import 'package:chan/models/board.dart';
import 'package:chan/models/thread.dart';
import 'package:chan/services/media.dart';
import 'package:chan/services/persistence.dart';
import 'package:chan/services/util.dart';
import 'package:chan/sites/ebinlauta_parser.dart';
import 'package:chan/sites/helpers/http_304.dart';
import 'package:chan/sites/imageboard_site.dart';
import 'package:chan/sites/lainchan.dart';
import 'package:chan/sites/util.dart';
import 'package:chan/util.dart';
import 'package:chan/widgets/post_spans.dart';
import 'package:chan/widgets/util.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart';

/// ebinlauta.net, running the site's own ebinboard engine over plain HTTP.
///
/// Unlike the app's ylilauta support this needs no browser: the pages answer
/// ordinary requests, so every read here is an HTML parse (see
/// [EbinlautaParser] for the markup rules). Posting is an ordinary multipart
/// form post to `/api/post/create/`, answered with a small JSON object; the
/// engine has no captcha and no token, so the only thing a request needs beyond
/// its fields is the guest session cookie the site hands out on any page load
/// (which the app's own client already keeps).
class SiteEbinlauta extends ImageboardSite with Http304CachingThreadMixin, Http304CachingCatalogMixin {
	@override
	final String baseUrl;
	@override
	final String name;
	@override
	final String defaultUsername;
	/// Used only where a board's own `max_files` is missing; the board list
	/// carries the real figure per board (1 everywhere except /a/ and /int/,
	/// which allow 4).
	final int filesPerPost;
	final int? maxUploadSizeBytes;

	SiteEbinlauta({
		required this.baseUrl,
		required this.name,
		this.defaultUsername = 'Anonyymi',
		this.filesPerPost = 1,
		this.maxUploadSizeBytes,
		required super.overrideUserAgent,
		required super.addIntrospectedHeaders,
		required super.preferHttp3WithoutAltSvc,
		required super.archives,
		required super.imageHeaders,
		required super.videoHeaders
	});

	static PostNodeSpan makeSpan(String board, int threadId, String data) {
		final body = parseFragment(data.trimRight());
		int spoilerSpanId = 0;
		Iterable<PostSpan> visit(Iterable<dom.Node> nodes) sync* {
			for (final node in nodes) {
				if (node is dom.Element) {
					if (node.localName == 'br') {
						yield const PostLineBreakSpan();
					}
					else if (node.localName == 'a' && node.classes.contains('reply')) {
						// The engine writes a reply link for every ">>123", even
						// when 123 is not on this page ("dead"): the id is always
						// a data attribute, and the thread is only named when the
						// target was found. A dead link still quotes the thread
						// being read, which is the best statement available.
						final postId = node.attributes['data-post-id']?.tryParseInt;
						if (postId == null) {
							yield PostTextSpan(node.text);
						}
						else {
							yield PostQuoteLinkSpan(
								board: node.attributes['data-board'] ?? board,
								threadId: node.attributes['data-thread']?.tryParseInt ?? threadId,
								postId: postId
							);
						}
					}
					else if (node.localName == 'a' && node.attributes['href'] != null) {
						yield PostLinkSpan(node.attributes['href']!, name: node.text.nonEmptyOrNull);
					}
					else if (node.localName == 'b' || node.localName == 'strong') {
						yield PostBoldSpan(PostNodeSpan(visit(node.nodes).toList(growable: false)));
					}
					else if (node.localName == 'i' || node.localName == 'em') {
						yield PostItalicSpan(PostNodeSpan(visit(node.nodes).toList(growable: false)));
					}
					else if (node.localName == 'u') {
						yield PostUnderlinedSpan(PostNodeSpan(visit(node.nodes).toList(growable: false)));
					}
					else if (node.localName == 's' || node.localName == 'strike' || node.localName == 'del') {
						yield PostStrikethroughSpan(PostNodeSpan(visit(node.nodes).toList(growable: false)));
					}
					else if (node.localName == 'big') {
						yield PostBigTextSpan(PostNodeSpan(visit(node.nodes).toList(growable: false)));
					}
					else if (node.localName == 'small') {
						yield PostSmallTextSpan(PostNodeSpan(visit(node.nodes).toList(growable: false)));
					}
					else if (node.localName == 'pre' || node.localName == 'code') {
						// [code] becomes <pre class="code"><code>…</code></pre>;
						// reading the outer element takes the whole block once.
						yield PostCodeSpan(node.text.trimRight());
					}
					else if (node.localName == 'span' && node.classes.contains('spoiler-text')) {
						yield PostSpoilerSpan(PostNodeSpan(visit(node.nodes).toList(growable: false)), spoilerSpanId++);
					}
					else if (node.localName == 'span' && node.classes.contains('green-text')) {
						yield PostQuoteSpan(PostNodeSpan(visit(node.nodes).toList(growable: false)));
					}
					else if (node.localName == 'span' && node.classes.contains('blue-text')) {
						yield PostBlueQuoteSpan(PostNodeSpan(visit(node.nodes).toList(growable: false)));
					}
					else if (node.localName == 'span' && node.classes.contains('purple-text')) {
						yield PostPinkQuoteSpan(PostNodeSpan(visit(node.nodes).toList(growable: false)));
					}
					else if (node.attributes['style'] case String style when style.isNotEmpty) {
						yield PostCssSpan(PostNodeSpan(visit(node.nodes).toList(growable: false)), style);
					}
					else {
						// Anything else the engine renders - and anything it adds
						// later - keeps its text and its children's links rather
						// than being shown as raw HTML or dropped.
						yield* visit(node.nodes);
					}
				}
				else {
					yield* SiteLainchan.parsePlaintext(node.text ?? '');
				}
			}
		}
		return PostNodeSpan(visit(body.nodes).toList(growable: false));
	}

	@override
	Future<List<ImageboardBoard>> getBoards({required RequestPriority priority, CancelToken? cancelToken}) async {
		final response = await client.getUri<String>(Uri.https(baseUrl, '/boards.json'), options: Options(
			responseType: ResponseType.plain,
			headers: {
				'referer': 'https://$baseUrl/'
			},
			extra: {
				kPriority: priority
			}
		), cancelToken: cancelToken);
		return EbinlautaParser.parseBoards(
			response.data!,
			filesPerPost: filesPerPost,
			maxUploadSizeBytes: maxUploadSizeBytes
		);
	}

	/// The engine renders no captcha anywhere: there is no captcha field in any
	/// live form, none in the site's own posting JavaScript, and no captcha
	/// check in the code that handles `/api/post/create/`. Nothing to ask for.
	@override
	Future<CaptchaRequest> getCaptchaRequest(String board, int? threadId, {CancelToken? cancelToken}) async => const NoCaptchaRequest();

	static final _postDelayPattern = RegExp(r'too fast[^0-9]*(\d+)', caseSensitive: false);

	/// The scalar fields the site's own form sends, named as it names them.
	///
	/// `parent` is the thread being replied to and 0 for a new thread (the
	/// engine reads an absent field as 0 as well). `email` doubles as the
	/// option list: it is split on whitespace and the tokens the engine knows
	/// ("sage", so as not to bump) are consumed rather than stored. `noko` is
	/// always added because the address the site redirects to is the only place
	/// it reports the new post's id - see [parsePostResponse].
	///
	/// The multipart field order this is written in is the form's own; PHP
	/// builds `$_POST` and `$_FILES` as maps and does not care about it.
	static Map<String, String> makePostFields(DraftPost post, {required String password}) {
		return {
			'parent': (post.threadId ?? 0).toString(),
			'name': post.name ?? '',
			'email': _emailField(post.options),
			'subject': post.subject ?? '',
			'message': post.text,
			'board': post.board,
			'password': password
		};
	}

	/// The whole multipart body of a post, files included.
	///
	/// The files go in as repeated `file[]` parts - the name the form's own
	/// input carries - which is what makes PHP collect them into
	/// `$_FILES['file']` instead of keeping only the last one.
	static Future<FormData> makePostFormData(DraftPost post, {required String password}) async {
		final fields = makePostFields(post, password: password);
		final form = FormData();
		for (final key in const ['parent', 'name', 'email', 'subject', 'message']) {
			form.fields.add(MapEntry(key, fields[key]!));
		}
		for (final file in post.files) {
			form.files.add(MapEntry('file[]', await MultipartFile.fromFile(
				file.path,
				filename: file.overrideFilename,
				contentType: MediaScan.guessMimeTypeFromPath(file.path)
			)));
		}
		for (final key in const ['board', 'password']) {
			form.fields.add(MapEntry(key, fields[key]!));
		}
		return form;
	}

	/// The ids in the address a successful post is answered with.
	///
	/// A reply is sent to `/<board>/<thread>#<post>` and a new thread to
	/// `/<board>/<thread>`, whose id is its opening post's. The fragment is the
	/// site's only report of the new post's id, and the path names the thread
	/// either way. Null means the address named no thread at all - the board
	/// listing, which is what the site redirects to when the post was not asked
	/// for with "noko".
	static ({int threadId, int? postId})? parsePostRedirect(String redirect) {
		final uri = Uri.tryParse(redirect);
		if (uri == null) {
			return null;
		}
		final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList(growable: false);
		if (segments.isEmpty) {
			return null;
		}
		final threadId = segments.last.tryParseInt;
		if (threadId == null) {
			return null;
		}
		return (
			threadId: threadId,
			postId: uri.fragment.extractPrefixedInt('q') ?? uri.fragment.tryParseInt
		);
	}

	/// What the site's answer to a post means, as the id of the post it made.
	///
	/// The endpoint answers `{"success":true,"redirect":"/<board>/<thread>#<post>"}`
	/// for a post that was made and `{"success":false,"message":"…","title":"…"}`
	/// for one it refused (`Ajax::respond`), which is what the site's own
	/// `postform.js` reads. A refusal keeps the site's own sentence; the "posting
	/// too fast" one becomes a [PostCooldownException] so the queue waits the
	/// time the site asked for instead of asking again immediately.
	///
	/// A success without an address cannot happen while the request carries
	/// "noko", and is reported rather than guessed at: the app marks a post as
	/// the user's own by this id, and a wrong one would highlight somebody
	/// else's post.
	static int parsePostResponse(String body) {
		final decoded = _decodeJson(body);
		if (decoded is! Map) {
			throw PostFailedException('The site answered the post with something other than a result.');
		}
		if (decoded['success'] != true) {
			final message = _errorMessage(decoded);
			if (_postDelayPattern.firstMatch(message)?.group(1)?.tryParseInt case final seconds?) {
				throw PostCooldownException(message, DateTime.now().add(Duration(seconds: seconds)));
			}
			throw PostFailedException(message);
		}
		final redirect = decoded['redirect'];
		final ids = redirect is String ? parsePostRedirect(redirect) : null;
		if (ids == null) {
			throw PostFailedException('The site accepted the post but did not say which post it was; check the board before posting again.');
		}
		return ids.postId ?? ids.threadId;
	}

	/// Refuses, before anything is uploaded, a post the board's own limits rule
	/// out.
	///
	/// The server enforces the same figures (the app has already split the
	/// draft's files to fit them), but its refusal only arrives after the bytes
	/// are sent, so the composer is told the board's own numbers instead.
	static void assertBoardLimits(DraftPost post, ImageboardBoard? board) {
		if (board == null || post.files.isEmpty) {
			// Nothing known about the board, or nothing to check.
			return;
		}
		if (post.files.length > board.filesPerPost) {
			throw PostFailedException('/${post.board}/ takes at most ${board.filesPerPost} file(s) per post, and ${post.files.length} were attached.');
		}
		// The engine applies one figure to the whole request: its own check sums
		// every uploaded file, and the board list gives that same number as both
		// the image and the video limit.
		final limit = board.maxImageSizeBytes ?? board.maxWebmSizeBytes;
		if (limit == null) {
			return;
		}
		var total = 0;
		for (final file in post.files) {
			final onDisk = File(file.path);
			if (onDisk.existsSync()) {
				total += onDisk.lengthSync();
			}
		}
		if (total > limit) {
			throw PostFailedException('The attachments add up to ${formatFilesize(total)}, more than the ${formatFilesize(limit)} a post on /${post.board}/ may carry.');
		}
	}

	@override
	Future<PostReceipt> submitPost(DraftPost post, CaptchaSolution captchaSolution, CancelToken cancelToken) async {
		assertBoardLimits(post, persistence?.maybeGetBoard(post.board));
		// The site keeps this only so a poster can delete later; the app stores
		// it in the receipt for the same reason.
		final password = makeRandomBase64String(28);
		final response = await client.postUri(Uri.https(baseUrl, '/api/post/create/'),
			data: await makePostFormData(post, password: password),
			options: Options(
				headers: {
					// Both are what the engine's Ajax::isAjax() looks for; the site's
					// own script sends only the first, and the second keeps the JSON
					// answer if a middlebox drops it.
					'x-requested-with': 'XMLHttpRequest',
					'accept': 'application/json',
					'referer': getWebUrlImpl(post.board, post.threadId)
				},
				extra: {
					kPriority: RequestPriority.interactive
				},
				// Read as text: the body is JSON for a post that was accepted or
				// refused, and a whole HTML page if the request ever stops looking
				// like AJAX. The app decides which it got rather than a transformer
				// guessing, and a body it cannot read is never taken for a post.
				responseType: ResponseType.plain,
				validateStatus: (_) => true
			),
			cancelToken: cancelToken
		);
		final body = response.data;
		if (body is! String || (response.statusCode ?? 0) >= 400) {
			throw HTTPStatusException.fromResponse(response);
		}
		return PostReceipt(
			id: parsePostResponse(body),
			password: password,
			name: post.name ?? '',
			options: post.options ?? '',
			time: DateTime.now(),
			post: post,
			ip: captchaSolution.ip
		);
	}

	/// The engine's own delay between two posts from one address on one board
	/// (`post_delay`, the same for threads and replies) is what the queue waits,
	/// so a second post is not answered with "posting too fast".
	@override
	Duration getActionCooldown(String board, ImageboardAction action, CookieJar cookies) {
		final boardState = persistence?.maybeGetBoard(board);
		final seconds = switch (action) {
			ImageboardAction.postThread => boardState?.threadCooldown,
			ImageboardAction.postReply || ImageboardAction.postReplyWithImage => boardState?.replyCooldown,
			_ => null
		};
		if (seconds == null) {
			return super.getActionCooldown(board, action, cookies);
		}
		return Duration(seconds: seconds);
	}

	/// The site takes a subject of its own (the form's field is 75 characters,
	/// as is every board's `max_subject`).
	@override
	int? get subjectCharacterLimit => 75;

	static String _emailField(String? options) {
		final tokens = (options ?? '').split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
		if (!tokens.any((t) => t.toLowerCase() == 'noko')) {
			tokens.add('noko');
		}
		return tokens.join(' ');
	}

	/// The site's own sentence about why a post was refused.
	static String _errorMessage(Map data) {
		final parts = [data['title'], data['message']]
			.whereType<Object>()
			.map((p) => p.toString().trim())
			.where((p) => p.isNotEmpty);
		return parts.isEmpty ? 'The site refused the post without saying why.' : parts.join(' ');
	}

	static dynamic _decodeJson(String body) {
		try {
			return jsonDecode(body);
		}
		catch (_) {
			return null;
		}
	}

	@override
	ImageboardBoardPopularityType? get boardPopularityType => ImageboardBoardPopularityType.postsCount;

	/// The site has no global catalog: its board list is the twelve boards in
	/// `/boards.json`, but `/ukko/` and `/epic/` are real too and are only
	/// linked from the sidebar. Allowing an arbitrary board name is what lets a
	/// typed one reach them; an unknown board answers 404, which the app already
	/// understands.
	@override
	bool get allowsArbitraryBoards => true;

	@override
	RequestOptions getCatalogRequest(String board, {CatalogVariant? variant}) => RequestOptions(
		baseUrl: 'https://$baseUrl',
		// The catalog is one page: /b/ is 10 threads over 16 pages and the
		// catalog lists the same 160, which is the board's whole cap, so there
		// is no "load more" request to make.
		path: board.isEmpty ? '/' : '/$board/catalog',
		headers: {
			'referer': 'https://$baseUrl/$board/'
		},
		responseType: ResponseType.plain
	);

	@override
	Future<List<Thread>> makeCatalog(String board, Response response, {
		CatalogVariant? variant,
		required RequestPriority priority,
		CancelToken? cancelToken
	}) async {
		return EbinlautaParser.parseCatalog(
			response.data as String,
			board: board,
			defaultUsername: defaultUsername,
			fetchedTime: DateTime.now()
		).threads.values.toList(growable: false);
	}

	@override
	RequestOptions getThreadRequest(ThreadIdentifier thread, {ThreadVariant? variant}) => RequestOptions(
		baseUrl: 'https://$baseUrl',
		path: '/${thread.board}/${thread.id}',
		headers: {
			'referer': 'https://$baseUrl/${thread.board}/'
		},
		responseType: ResponseType.plain
	);

	@override
	Future<Thread> makeThread(ThreadIdentifier thread, Response response, {
		ThreadVariant? variant,
		required RequestPriority priority,
		CancelToken? cancelToken
	}) async {
		final page = EbinlautaParser.parseThread(
			response.data as String,
			board: thread.board,
			threadId: thread.id,
			defaultUsername: defaultUsername,
			fetchedTime: DateTime.now()
		);
		return page.thread;
	}

	@override
	String getWebUrlImpl(String board, [int? threadId, int? postId]) {
		if (board.isEmpty) {
			return 'https://$baseUrl/';
		}
		// The site's own post links are /<board>/<thread>#<postId>.
		return 'https://$baseUrl/$board/${threadId ?? ''}${postId == null ? '' : '#$postId'}';
	}

	@override
	Uri? get iconUrl => Uri.https(baseUrl, '/static/img/favicon.ico');

	@override
	String get siteData => baseUrl;

	@override
	String get siteType => 'ebinlauta';

	/// Threads are `/<board>/<id>`, board listings `/<board>/` and
	/// `/<board>-<page>/`, and the catalog `/<board>/catalog` - so the board is
	/// always the first segment, with a page suffix on the listing form.
	@override
	Future<BoardThreadOrPostIdentifier?> decodeUrl(Uri url, {CancelToken? cancelToken}) async {
		if (url.host != baseUrl) {
			return null;
		}
		final segments = url.pathSegments.where((s) => s.isNotEmpty).toList(growable: false);
		if (segments.isEmpty) {
			return null;
		}
		final postId = url.fragment.extractPrefixedInt('q') ?? url.fragment.tryParseInt;
		// A listing address carries the page in the board segment (`/b-3/`).
		final dash = segments.first.lastIndexOf('-');
		final board = dash == -1 ? segments.first : segments.first.substring(0, dash);
		if (segments.length == 1) {
			return BoardThreadOrPostIdentifier(board, null, postId);
		}
		if (segments.length == 2) {
			if (segments[1] == 'catalog') {
				return BoardThreadOrPostIdentifier(board, null, postId);
			}
			final threadId = segments[1].tryParseInt;
			if (threadId != null) {
				return BoardThreadOrPostIdentifier(board, threadId, postId);
			}
			return null;
		}
		if (segments.length == 3) {
			// /<board>/<thread>/<offset>
			final threadId = segments[1].tryParseInt;
			if (threadId != null) {
				return BoardThreadOrPostIdentifier(board, threadId, postId);
			}
		}
		return null;
	}

	@override
	bool decodeUrlPossible(Uri url) => url.host == baseUrl;

	/// All media is on the same host as the pages.
	@override
	String get imageUrl => baseUrl;

	@override
	List<ImageboardSnippet> getBoardSnippets(String board) => const [
		greentextSnippet
	];

	@override
	bool operator == (Object other) =>
		identical(this, other) ||
		other is SiteEbinlauta &&
		other.baseUrl == baseUrl &&
		other.name == name &&
		other.defaultUsername == defaultUsername &&
		other.filesPerPost == filesPerPost &&
		other.maxUploadSizeBytes == maxUploadSizeBytes &&
		super==(other);

	@override
	int get hashCode => baseUrl.hashCode;
}
