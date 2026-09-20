import 'dart:io';

import 'package:chan/models/attachment.dart';
import 'package:chan/models/flag.dart';
import 'package:chan/models/post.dart';
import 'package:chan/sites/imageboard_site.dart';
import 'package:chan/services/settings.dart';
import 'package:chan/sites/personal_sites.dart';
import 'package:chan/sites/ylilauta.dart';
import 'package:chan/sites/ylilauta_parser.dart';
import 'package:chan/widgets/post_spans.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;

/// These tests run [YlilautaParser] against pages captured from ylilauta.org.
///
/// They exist because the site's markup has several traps that are easy to get
/// wrong and impossible to notice without real input: compact board cards carry
/// no `data-post-id` of their own, thread slugs are often non-numeric, and the
/// quoted-post previews are nested *inside* the quoting post's message.
String fixture(String name) => File('test/ylilauta_fixtures/$name').readAsStringSync();

void main() {
	group('boards', () {
		test('parses the board list with names and titles', () {
			final boards = YlilautaParser.parseBoards(fixture('boards.html'), filesPerPost: 4, maxUploadSizeBytes: null);
			expect(boards, isNotEmpty);
			// Names come from data-board, titles from the anchor label.
			final byName = {for (final b in boards) b.name: b};
			expect(byName.keys, contains('rikokset'));
			expect(byName['rikokset']!.title, 'Rikokset');
			// The nav lists boards across several categories.
			expect(boards.length, greaterThan(30));
			expect(boards.every((b) => b.title.isNotEmpty), isTrue);
			expect(boards.every((b) => b.filesPerPost == 4), isTrue);
		});
	});

	group('catalog', () {
		test('parses compact board cards', () {
			final catalog = YlilautaParser.parseCatalog(
				fixture('catalog.html'),
				board: 'rikokset',
				defaultUsername: 'Anonyymi',
				fetchedTime: DateTime(2026, 9, 19)
			);
			// All four fixture cards must be usable. Three of them have a
			// non-numeric slug (29cjqi, 29d1f9, 29c42b); identifying threads by
			// slug discarded those, which is what made boards look empty.
			expect(catalog.threads, hasLength(4));
			expect(catalog.threads.keys, containsAll([136422217, 136634346, 136657269, 136614035]));
			final thread = catalog.threads[136422217]!;
			expect(thread.board, 'rikokset');
			// A compact card only renders the OP.
			expect(thread.posts_, hasLength(1));
			final op = thread.posts_.single;
			// The id is the card's data-thread-id, which is NOT the OP post id
			// (that comes from the card's menu button) and NOT the URL slug.
			expect(op.id, 317373496);
			expect(op.threadId, 136422217);
			expect(op.name, 'Anonyymi');
			expect(op.spanFormat, PostSpanFormat.ylilauta);
			expect(op.text, contains('Esitutkintapöytäkirja-lanka'));
			// Board-page stats are unlabelled: just `<replies> <votes>`.
			expect(thread.replyCount, 898);
			// The slug is kept so the thread can be fetched and linked to later.
			expect(thread.urlSlug, '298021');
			expect(catalog.threads[136634346]!.urlSlug, '29cjqi');
		});
	});

	group('attachment sizes', () {
		test('keeps the size a thread page publishes', () {
			final thread = YlilautaParser.parseThread(
				fixture('live_thread.html'),
				board: 'rikokset',
				threadId: 135614236,
				defaultUsername: 'Anonyymi',
				urlSlug: '28qom4',
				fetchedTime: DateTime(2026, 9, 20)
			);
			final sizes = thread.posts_
				.expand((p) => p.attachments)
				.map((a) => a.sizeInBytes)
				.whereType<int>()
				.toSet();
			expect(sizes, containsAll([70351, 329885]));
		});

		test('reports a size the site did not publish as unknown, not as zero', () {
			// Board and catalog listings carry `data-file-size="0"` for every
			// file, because they have not measured it: it is a placeholder
			// there, not a size. Passing it on printed "0 B" against every
			// previewed file, and, being non-null, it also blocked the real
			// size from being merged in when the thread itself was fetched.
			final catalog = YlilautaParser.parseCatalog(
				fixture('catalog.html'),
				board: 'rikokset',
				defaultUsername: 'Anonyymi',
				fetchedTime: DateTime(2026, 9, 20)
			);
			final attachments = catalog.threads.values
				.expand((t) => t.posts_)
				.expand((p) => p.attachments)
				.toList();
			expect(attachments, isNotEmpty);
			expect(attachments.every((a) => a.sizeInBytes == null), isTrue);
		});
	});

	group('thread by slug', () {
		test('reads the card that names the thread, not the first one on the page', () {
			// A thread page carries one card today, but the selector matches any
			// card, so a page that also lists other threads - a sidebar, a
			// related-threads block - must not be parsed as one of those.
			const decoy = '<div class="card thread" data-thread-id="1" data-url="https://ylilauta.org/rikokset/decoy"></div>';
			final html = fixture('live_thread.html').replaceFirst('<body>', '<body>$decoy');
			final thread = YlilautaParser.parseThreadBySlug(
				html,
				board: 'rikokset',
				slug: '28qom4',
				defaultUsername: 'Anonyymi',
				fetchedTime: DateTime(2026, 9, 20)
			);
			expect(thread.id, 135614236);
			expect(thread.urlSlug, '28qom4');
			expect(thread.posts_, isNotEmpty);
		});

		test('still parses a page whose card carries no address of its own', () {
			// A card without data-url cannot name the thread, and a slug that
			// matches nothing must not turn a readable thread into a missing one.
			final thread = YlilautaParser.parseThreadBySlug(
				fixture('thread.html'),
				board: 'rikokset',
				slug: '28qom4',
				defaultUsername: 'Anonyymi',
				fetchedTime: DateTime(2026, 9, 20)
			);
			expect(thread.posts_, isNotEmpty);
		});
	});

	group('flags', () {
		test('reads the flag the site shows beside a post', () {
			const html = '<div class="card thread" data-thread-id="5" data-url="https://ylilauta.org/international/29dbm4">'
				'<div class="post op-post op" data-post-id="7" data-user-id="0">'
				'<div class="post-meta"><span class="time" data-timestamp="1766075036">now</span>'
				'<img class="flag" alt="FI" title="Finland" src="https://ylilauta.org/static/img/flags/fi.png">'
				'</div><div class="post-message">hello</div></div></div>';
			final thread = YlilautaParser.parseThread(html, board: 'international', threadId: 5, defaultUsername: 'Anonyymi', fetchedTime: DateTime(2026, 9, 20));
			final flag = thread.posts_.single.flag as ImageboardFlag;
			expect(flag.name, 'Finland');
			expect(flag.imageUrl, 'https://ylilauta.org/static/img/flags/fi.png');
			// The site publishes no size, and each country's flag is its own.
			expect(flag.imageWidth, lessThan(0));
			expect(flag.imageHeight, lessThan(0));
		});

		test('a post without a flag has none', () {
			final thread = YlilautaParser.parseThread(
				fixture('thread.html'),
				board: 'rikokset',
				threadId: 136422217,
				defaultUsername: 'Anonyymi',
				fetchedTime: DateTime(2026, 9, 20)
			);
			expect(thread.posts_.every((p) => p.flag == null), isTrue);
		});
	});

	group('thread', () {
		late final parsed = YlilautaParser.parseThread(
			fixture('thread.html'),
			board: 'rikokset',
			threadId: 136422217,
			defaultUsername: 'Anonyymi',
			fetchedTime: DateTime(2026, 9, 19)
		);

		test('parses every post in the card', () {
			expect(parsed.id, 136422217);
			expect(parsed.board, 'rikokset');
			expect(parsed.posts_, hasLength(10));
			expect(parsed.posts_.map((p) => p.id).toSet(), hasLength(10));
			expect(parsed.posts_.every((p) => p.threadId == 136422217), isTrue);
		});

		test('reads timestamps as real dates', () {
			final times = parsed.posts_.map((p) => p.time).toList();
			expect(times.every((t) => t.year >= 2020), isTrue);
			// Posts are in ascending time order.
			for (var i = 1; i < times.length; i++) {
				expect(times[i].isBefore(times[i - 1]), isFalse);
			}
		});

		test('uses the labelled thread stats', () {
			expect(parsed.replyCount, 898);
			expect(parsed.uniqueIPCount, 283);
			expect(parsed.title, isNull);
			expect(parsed.time, parsed.posts_.first.time);
		});

		test('gives the thread starter the OP badge the site shows', () {
			// `data-user-id` is a per-thread poster number, and the thread starter
			// does not get one: the site writes 0 and renders "OP" in the slot
			// where everyone else gets a number - on the thread's first post and
			// on that poster's later replies (which carry the `op` class too).
			final opPosts = parsed.posts_.where((p) => p.id == 317373496 || p.id == 317620075 || p.id == 317620160);
			expect(opPosts, hasLength(3));
			expect(opPosts.every((p) => p.posterId == YlilautaParser.kOpPosterId), isTrue);
			// Everyone else is numbered.
			final named = parsed.posts_.where((p) => !opPosts.contains(p));
			expect(named, isNotEmpty);
			expect(named.every((p) => p.posterId != null && p.posterId != YlilautaParser.kOpPosterId), isTrue);
			expect(parsed.posts_.firstWhere((p) => p.id == 317375489).posterId, '1');
		});

		test('parses attachments', () {
			final withFiles = parsed.posts_.where((p) => p.attachments.isNotEmpty).toList();
			expect(withFiles, isNotEmpty);
			for (final post in withFiles) {
				for (final a in post.attachments) {
					// Attachments live on the ungated image host.
					expect(a.url, startsWith('https://i.ylilauta.org/'));
					expect(a.thumbnailUrl, isNotEmpty);
					expect(a.id, isNotEmpty);
					expect(a.ext, isNotEmpty);
					expect(a.type.isImageSearchable, isTrue);
				}
			}
			expect(parsed.imageCount, parsed.posts_.expand((p) => p.attachments).length);
		});

		test('turns quoted-post previews into quote links, not body text', () {
			// The preview body is a duplicate of the quoted post; it must not be
			// swallowed into the quoting post's text.
			for (final post in parsed.posts_) {
				expect(post.text, isNot(contains('[preview body trimmed]')));
			}
			// Posts that quote an earlier post in the fixture must resolve to a
			// quote link pointing at it.
			final quoter = parsed.posts_.firstWhere((p) => p.id == 317375489);
			expect(quoter.repliedToIds, contains(317373938));
			final link = quoter.span.traverse(quoter).whereType<PostQuoteLinkSpan>().toList();
			expect(link, isNotEmpty);
			expect(link.first.postId, 317373938);
			expect(link.first.board, 'rikokset');
			expect(link.first.threadId, 136422217);
		});

		test('infers the reply graph from quote links', () {
			final quoted = parsed.posts_.firstWhere((p) => p.id == 317375489);
			// 317375578 quotes 317375489, and 317376229/317380387 quote 317375578.
			expect(quoted.replyIds, contains(317375578));
			final middle = parsed.posts_.firstWhere((p) => p.id == 317375578);
			expect(middle.replyIds, containsAll([317376229, 317380387]));
		});
	});

	group('challenge detection', () {
		test('recognises the real interstitial', () {
			// Captured from the live site when it rate-limited this machine.
			expect(SiteYlilauta.isChallengePage(fixture('challenge.html')), isTrue);
		});

		test('recognises the interstitial title without the hCaptcha widget', () {
			expect(SiteYlilauta.isChallengePage('<html><head><title>Beep boop?</title></head><body></body></html>'), isTrue);
		});

		test('recognises hCaptcha wherever it is rendered', () {
			expect(SiteYlilauta.isChallengePage('<div class="h-captcha" data-sitekey="x"></div>'), isTrue);
		});

		test('a page carrying a thread is not a challenge', () {
			// ylilauta serves its interstitial inside otherwise normal pages in
			// some situations. Treating those as challenges gave the user a
			// prompt showing the thread they had just opened.
			expect(SiteYlilauta.isChallengePage(
				'<html><title>Beep boop?</title><div class="card thread">x</div>'
				'<div class="h-captcha"></div></html>'), isFalse);
		});

		test('does not misfire on ordinary pages', () {
			// A real page must never be mistaken for a challenge: doing so would
			// hang the fetch waiting for a challenge that never appears.
			expect(SiteYlilauta.isChallengePage(fixture('thread.html')), isFalse);
			expect(SiteYlilauta.isChallengePage(fixture('catalog.html')), isFalse);
			expect(SiteYlilauta.isChallengePage(fixture('boards.html')), isFalse);
			// Prose merely repeating the interstitial's wording is not the
			// interstitial.
			expect(SiteYlilauta.isChallengePage('<html><head><title>Rikokset</title></head><body><div class="post-message">Beep boop? We have detected unusual traffic</div></body></html>'), isFalse);
		});
	});

	// The gateway is what makes a challenge solvable. The WebView helper checks
	// it before calling the fetch handler and, when it returns non-null, opens
	// the interactive authorization page instead of completing with the
	// challenge body. Missing this is what made the board list come back empty
	// with no prompt.
	// Endless board listings. The board page carries a signed state token and
	// the "load more" endpoint returns the same kind of compact card as the board
	// page, so parsing is shared. The request itself needs a live session, so
	// only the parsing half is covered here.
	group('endless catalog', () {
		test('reads the listing state token', () {
			final state = YlilautaParser.parseCatalogState(fixture('board_page.html'));
			expect(state, isNotNull);
			expect(state, isNotEmpty);
			// The token is a signed blob, not a page number.
			expect(state!.length, greaterThan(100));
		});

		test('reports no state when the listing is absent', () {
			expect(YlilautaParser.parseCatalogState('<html><body></body></html>'), isNull);
		});

		test('parses a batch of additional threads', () {
			// Reuse real cards: the endpoint returns the same markup as the board
			// page, which is what makes sharing parseCatalog safe.
			final cards = RegExp(r'<div class="card thread op-post op[\s\S]*?</footer>')
				.allMatches(fixture('catalog.html'))
				.map((m) => m.group(0))
				.toList();
			expect(cards, isNotEmpty);
			final fragment = '<div class="threads">${cards.join()}</div>';
			final threads = YlilautaParser.parseMoreThreads(
				fragment,
				board: 'rikokset',
				defaultUsername: 'Anonyymi',
				fetchedTime: DateTime(2026, 9, 19)
			);
			expect(threads, isNotEmpty);
			for (final thread in threads) {
				expect(thread.board, 'rikokset');
				expect(thread.posts_, hasLength(1));
				// A thread without a slug is still usable, since the id addresses
				// it once the slug is unknown.
				expect(thread.id, greaterThan(0));
			}
		});

		test('an empty batch means the listing has ended', () {
			final threads = YlilautaParser.parseMoreThreads(
				'<div class="threads"></div>',
				board: 'rikokset',
				defaultUsername: 'Anonyymi',
				fetchedTime: DateTime(2026, 9, 19)
			);
			expect(threads, isEmpty);
		});
	});

	group('challenge gateway', () {
		final site = SiteYlilauta(
			name: 'ylilauta',
			baseUrl: 'ylilauta.org',
			defaultUsername: 'Anonyymi',
			filesPerPost: 4,
			maxUploadSizeBytes: null,
			overrideUserAgent: null,
			addIntrospectedHeaders: false,
			preferHttp3WithoutAltSvc: null,
			archives: const [],
			imageHeaders: const {},
			videoHeaders: const {}
		);

		Future<ImageboardRedirectGateway?> gatewayFor(String html, {String host = 'ylilauta.org'}) {
			return site.getRedirectGateway(Uri.https(host, '/'), () => '', () async => html);
		}

		test('asks for a prompt when the interstitial is served', () async {
			final gateway = await gatewayFor(fixture('challenge.html'));
			expect(gateway, isNotNull);
			// hCaptcha cannot be solved without a human.
			expect(gateway!.alwaysNeedsManualSolving, isTrue);
		});

		test('asks for a prompt from the title alone', () async {
			expect(await gatewayFor('<html><head><title>Beep boop?</title></head></html>'), isNotNull);
		});

		test('asks for a prompt from the hCaptcha widget alone', () async {
			// This is the case that regressed in practice: the interstitial was
			// matched by isChallengePage via `h-captcha`, but the gateway only
			// looked at the title, so it returned null and the fetch threw
			// instead of prompting. The gateway must accept every marker the
			// detector does, or the two disagree about what a challenge is.
			expect(await gatewayFor('<html><body><div class="h-captcha" data-sitekey="x"></div></body></html>'), isNotNull);
		});

		test('agrees with isChallengePage on every fixture', () async {
			for (final name in ['challenge.html', 'boards.html', 'catalog.html', 'thread.html']) {
				final html = fixture(name);
				final detected = SiteYlilauta.isChallengePage(html);
				final gateway = await gatewayFor(html);
				expect(gateway != null, detected,
					reason: '$name: isChallengePage=$detected but gateway=${gateway != null}');
			}
		});

		test('stays out of the way for real pages', () async {
			expect(await gatewayFor(fixture('boards.html')), isNull);
			expect(await gatewayFor(fixture('catalog.html')), isNull);
			expect(await gatewayFor(fixture('thread.html')), isNull);
		});

		test('ignores other hosts', () async {
			expect(await gatewayFor(fixture('challenge.html'), host: 'example.com'), isNull);
		});
	});

	group('makeSpan', () {
		test('maps refs, quotes and links', () {
			final span = SiteYlilauta.makeSpan('rikokset', 136422217,
				'<span class="ref" data-post-id="317373938"></span>Oli tylsää');
			final children = span.children;
			expect(children.first, isA<PostQuoteLinkSpan>());
			expect((children.first as PostQuoteLinkSpan).postId, 317373938);
			expect(children.whereType<PostTextSpan>().map((s) => s.text).join(), contains('Oli tylsää'));
		});

		test('colours inline quotes and keeps line breaks', () {
			final span = SiteYlilauta.makeSpan('rikokset', 1, '<span class="quote">green</span><br><span class="quote blue">blue</span>');
			expect(span.children[0], isA<PostQuoteSpan>());
			expect(span.children[1], isA<PostLineBreakSpan>());
			expect(span.children[2], isA<PostBlueQuoteSpan>());
		});

		test('absolutises relative links', () {
			final span = SiteYlilauta.makeSpan('rikokset', 1, '<a href="/rikokset/298021">thread</a>');
			final link = span.children.single as PostLinkSpan;
			expect(link.url, 'https://ylilauta.org/rikokset/298021');
			expect(link.name, 'thread');
		});
	});

	group('decodeUrl', () {
		final site = SiteYlilauta(
			name: 'ylilauta',
			baseUrl: 'ylilauta.org',
			defaultUsername: 'Anonyymi',
			filesPerPost: 4,
			maxUploadSizeBytes: null,
			overrideUserAgent: null,
			addIntrospectedHeaders: false,
			preferHttp3WithoutAltSvc: null,
			archives: const [],
			imageHeaders: const {},
			videoHeaders: const {}
		);

		test('understands thread and post URLs', () async {
			// A numeric address segment is the thread's *slug*, not its id: the
			// captured page this test's fixture holds is /rikokset/298021 and its
			// data-thread-id is 136422217. Believing the number was an id made
			// every such link resolve to a thread that does not exist - "no link
			// known" - so no id is reported until the page says what it is.
			final thread = await site.decodeUrl(Uri.parse('https://ylilauta.org/rikokset/298021'));
			expect(thread!.board, 'rikokset');
			expect(thread.threadId, isNull);
			final id = await site.decodeUrl(Uri.parse('https://ylilauta.org/rikokset/298021#post-317373496'));
			expect(id!.board, 'rikokset');
			expect(id.threadId, isNull);
			expect(id.postId, 317373496);
		});

		test('handles non-numeric slugs and other hosts', () async {
			// Without a cancel token there is no live lookup, so a non-numeric
			// slug cannot be resolved to an id and none is invented. The link
			// handler passes a token, which is where the live lookup happens.
			final id = await site.decodeUrl(Uri.parse('https://ylilauta.org/rikokset/29cjqi'));
			expect(id!.board, 'rikokset');
			expect(id.threadId, isNull);
			expect(await site.decodeUrl(Uri.parse('https://example.com/rikokset/1')), isNull);
		});

		test('produces a growable posts list', () {
			// Thread.mergePosts mutates posts_ in place with removeAt/insert when
			// a thread is refreshed. A fixed-length list throws
			// "cannot remove from a fixed-length list", which made opening a
			// thread fail outright.
			final parsed2 = YlilautaParser.parseThread(
				fixture('thread.html'),
				board: 'rikokset',
				threadId: 136422217,
				defaultUsername: 'Anonyymi',
				fetchedTime: DateTime(2026, 9, 19)
			);
			expect(() => parsed2.posts_.removeAt(0), returnsNormally);
			expect(() => parsed2.posts_.insert(0, parsed2.posts_.first), returnsNormally);
			// `attachments` is deliberately narrowed to a fixed-length list by
			// the Thread constructor itself, so it is not asserted here - only
			// posts_ is left mutable, and it is the one mergePosts mutates.
		});

		test('reads the slug from a thread page rather than the id', () {
			// Fetching by slug means the id has to come back off the page.
			final parsed = YlilautaParser.parseThreadBySlug(
				fixture('thread.html'),
				board: 'rikokset',
				slug: '298021',
				defaultUsername: 'Anonyymi',
				fetchedTime: DateTime(2026, 9, 19)
			);
			expect(parsed.id, 136422217);
			expect(parsed.urlSlug, '298021');
		});

		test('ignores a slug it cannot resolve to a thread', () {
			expect(
				() => YlilautaParser.parseThreadBySlug(
					'<html><body></body></html>',
					board: 'rikokset',
					slug: 'nope',
					defaultUsername: 'Anonyymi',
					fetchedTime: DateTime(2026, 9, 19)
				),
				throwsA(isA<ThreadNotFoundException>())
			);
		});

		test('reports derived config', () {
			expect(site.siteType, 'ylilauta');
			expect(site.imageUrl, 'i.ylilauta.org');
			// Posting goes through the site's own composer in a WebView, and is
			// refused at submit time when logged out rather than hidden here.
			expect(site.supportsPosting, isTrue);
			// The login is a dialog the page builds, so the queue must not start
			// one by itself: it would be cancelled by its own timeout and flash a
			// login window over the app on every post.
			expect(site.loginSystem.autoLoginBeforePosting, isFalse);
			expect(site.decodeUrlPossible(Uri.parse('https://i.ylilauta.org/ab/cd/x.avif')), isTrue);
			expect(site.decodeUrlPossible(Uri.parse('https://example.com/x')), isFalse);
		});
	});

	// The site renders its reply, thread and upvote controls for signed-out
	// visitors as well - the captures above carry them - and only settles it
	// when one is used, so what the app offers follows the header instead.
	group('catalog cards', () {
		test('the card preview is the thread starter, so it carries the OP badge', () {
			// A thread met in the board listing is built from its card, and a card
			// has no data-user-id. It does not need one: the post it previews is the
			// one that opened the thread. This is what makes the badge show up
			// without a refresh, since a fetch merges into this same post.
			final threads = YlilautaParser.parseCatalog(fixture('live_board.html'), board: 'satunnainen', defaultUsername: 'Anonyymi', fetchedTime: DateTime(2026, 9, 20));
			expect(threads.threads, isNotEmpty);
			for (final thread in threads.threads.values) {
				expect(thread.posts_.first.posterId, YlilautaParser.kOpPosterId);
			}
		});
	});

	group('session', () {
		test('a page served without an account offers a login', () {
			expect(SiteYlilauta.signedInFromHtml(fixture('live_board.html')), isFalse);
		});

		test('a header with no login in it is a session that is signed in', () {
			expect(
				SiteYlilauta.signedInFromHtml(fixture('live_board.html').replaceAll('data-action="User.login"', 'data-action="User.menu"')),
				isTrue
			);
		});

		test('a page with no header at all says nothing', () {
			// A thread fragment, or a document that never finished rendering:
			// reading it as "signed out" would hide posting for a live session.
			expect(SiteYlilauta.signedInFromHtml(fixture('live_thread.html')), isNull);
			expect(SiteYlilauta.signedInFromHtml('<html><body>nothing</body></html>'), isNull);
		});
	});

	// Upvoting has no server-side "you voted" field to read: the page's own
	// upvote control carries the state, `Post.upvote` is rendered for
	// signed-out visitors too, and `none` on that control means the post has no
	// votes rather than "not voted". Both halves of what the app offers are
	// therefore read from the page, and these tests pin that down.
	group('upvotes', () {
		SiteYlilauta makeSite() => SiteYlilauta(
			name: 'ylilauta',
			baseUrl: 'ylilauta.org',
			defaultUsername: 'Anonyymi',
			filesPerPost: 4,
			maxUploadSizeBytes: null,
			overrideUserAgent: null,
			addIntrospectedHeaders: false,
			preferHttp3WithoutAltSvc: null,
			archives: const [],
			imageHeaders: const {},
			videoHeaders: const {}
		);

		final threadUri = Uri.https('ylilauta.org', '/rikokset/28qom4');

		test('reads the vote state each post control carries', () {
			final state = SiteYlilauta.upvoteStateFromHtml(fixture('live_thread.html'));
			// The capture has no session, so every control is unvoted - but the
			// control is there for every post, which is what makes the state
			// known rather than absent.
			expect(state, hasLength(25));
			expect(state.values, everyElement(isFalse));
		});

		test('reads a vote the page says the viewer cast', () {
			// `active` is the class the site's own script toggles, so this is
			// what a voted control looks like to the app.
			final html = fixture('live_thread.html')
				.replaceFirst('icon-pointer-upright', 'icon-pointer-upright active');
			final state = SiteYlilauta.upvoteStateFromHtml(html);
			expect(state.values.where((upvoted) => upvoted), hasLength(1));
		});

		test('a page without the control says nothing', () {
			// The board listing renders no upvote button at all, and a fragment
			// may carry other post controls - neither is evidence either way.
			expect(SiteYlilauta.upvoteStateFromHtml(fixture('live_board.html')), isEmpty);
			expect(SiteYlilauta.upvoteStateFromHtml('<html><body><button data-action="Post.reply"></button></body></html>'), isEmpty);
		});

		test('fills Post.upvoted from the page the thread came from', () {
			final html = fixture('live_thread.html');
			final thread = YlilautaParser.parseThreadBySlug(html,
				board: 'rikokset', slug: '28qom4', defaultUsername: 'Anonyymi', fetchedTime: DateTime(2026, 9, 20));
			// The parser knows nothing about votes; the page read fills them in.
			expect(thread.posts_.map((p) => p.upvoted), everyElement(isNull));
			final votedHtml = html.replaceFirst('icon-pointer-upright', 'icon-pointer-upright active');
			final applied = SiteYlilauta.withUpvoteState(thread, votedHtml);
			expect(applied.posts_.where((p) => p.upvoted == true), hasLength(1));
			expect(applied.posts_.where((p) => p.upvoted == false), hasLength(thread.posts_.length - 1));
		});

		test('a post kept by the app remembers the vote it just cast', () {
			final thread = YlilautaParser.parseThreadBySlug(fixture('live_thread.html'),
				board: 'rikokset', slug: '28qom4', defaultUsername: 'Anonyymi', fetchedTime: DateTime(2026, 9, 20));
			final post = thread.posts_.first;
			expect(post.upvoted, isNull);
			final voted = post.copyWith(upvotes: (post.upvotes ?? 0) + 1, upvoted: true);
			expect(voted.upvoted, isTrue);
			expect(voted.upvotes, (post.upvotes ?? 0) + 1);
			// The update replaces the post, so the difference has to show up in
			// equality - that is what makes the thread rebuild around it.
			expect(voted == post, isFalse);
		});

		test('offering the vote follows the page and the session', () {
			final site = makeSite();
			// Nothing read yet: like posting, yes until a page says otherwise.
			expect(site.supportsPostUpvotes, isTrue);
			// A fragment says nothing at all.
			site.readPageState(threadUri, '<html><body>nothing here</body></html>');
			expect(site.supportsPostUpvotes, isTrue);
			// A thread page is where the control lives, and a signed-out page
			// must not offer a vote that cannot be cast.
			site.readPageState(threadUri, fixture('live_board.html'));
			expect(site.supportsPostUpvotes, isFalse, reason: 'a signed-out page offers no vote');
			// The board page carries Post.menu buttons but no per-post controls,
			// so it must not clear what the thread page established.
			site.readPageState(threadUri, fixture('live_board.html').replaceAll('data-action="User.login"', 'data-action="User.menu"'));
			expect(site.supportsPostUpvotes, isTrue);
			site.readPageState(threadUri, fixture('live_thread.html'));
			expect(site.supportsPostUpvotes, isTrue);
			// Browsing the board does not take the affordance away.
			site.readPageState(threadUri, fixture('live_board.html').replaceAll('data-action="User.login"', 'data-action="User.menu"'));
			expect(site.supportsPostUpvotes, isTrue);
			// A post page that carries other post controls but no upvote control
			// is the site saying it is not offered.
			site.readPageState(threadUri, fixture('live_thread.html')
				.replaceAll('data-action="Post.upvote"', 'data-action="Post.reply"'));
			expect(site.supportsPostUpvotes, isFalse, reason: 'the site did not render the control');
			// And a page that offers it again restores it.
			site.readPageState(threadUri, fixture('live_thread.html'));
			expect(site.supportsPostUpvotes, isTrue);
		});
	});

	// An adapter that exists but is not reachable from the UI is not usable.
	// These assertions are what would have caught that: the shared registry does
	// not contain ylilauta, so its definition has to come from personalSites.
	//
	// They exercise `availableSites`, the single helper that the "Add new site"
	// dialog and `Settings.addSiteKey` both go through. An earlier version of
	// this work merged personalSites by hand in a few places instead; the dialog
	// read the registry directly and ylilauta never appeared, which is exactly
	// the failure a hand-written replica in a test cannot catch.
	group('default site', () {
		test('the default site is ylilauta and it is registered', () {
			// A default key that is not in the site map would leave a fresh
			// install with nothing to open, so the two are asserted together.
			expect(kDefaultSiteKey, 'ylilauta');
			final available = availableSites(null);
			expect(available.containsKey(kDefaultSiteKey), isTrue,
				reason: 'default site must exist in the site map');
			expect(() => makeSite(available[kDefaultSiteKey]!), returnsNormally);
		});

		test('the default site is not one the registry supplies', () {
			// ylilauta is only present because of personalSites; if it ever moves
			// into the shared registry this assertion is a signal to simplify.
			expect(personalSites.containsKey(kDefaultSiteKey), isTrue);
		});
	});

	group('reachability', () {
		// A stand-in for the downloaded registry, which has no ylilauta entry.
		final registry = <String, Map<String, Object?>>{
			'testchan': {
				'type': 'lainchan',
				'name': 'testchan',
				'baseUrl': 'boards.chance.surf'
			}
		};

		test('makeSite builds a site from the personalSites definition', () {
			final site = makeSite(personalSites['ylilauta']!);
			expect(site, isA<SiteYlilauta>());
			expect(site.baseUrl, 'ylilauta.org');
			expect((site as SiteYlilauta).defaultUsername, 'Anonyymi');
		});

		test('the definition is complete enough to be usable', () {
			final definition = personalSites['ylilauta']!;
			// These are the keys the settings UI and makeSite rely on.
			expect(definition['type'], 'ylilauta');
			expect(definition['baseUrl'], isA<String>());
			expect(definition['name'], isA<String>());
		});

		test('the registry alone does not contain ylilauta', () {
			// Guards the premise: if the maintainer ever adds it, this test
			// should be revisited rather than silently passing for the wrong
			// reason.
			expect(registry.containsKey('ylilauta'), isFalse);
		});

		test('availableSites adds personal sites to the registry', () {
			final available = availableSites(registry);
			expect(available.containsKey('ylilauta'), isTrue);
			// Existing entries survive.
			expect(available.containsKey('testchan'), isTrue);
			expect(available['testchan'], registry['testchan']);
		});

		test('availableSites still offers personal sites before the registry downloads', () {
			// JsonCache.sites.value is null until the first download completes.
			final available = availableSites(null);
			expect(available.containsKey('ylilauta'), isTrue);
		});

		test('every entry the dialog would list is buildable', () {
			// The "Add new site" dialog skips any entry whose makeSite throws, so
			// a definition that cannot be built is invisible to the user.
			for (final entry in availableSites(registry).entries) {
				expect(() => makeSite(entry.value), returnsNormally, reason: entry.key);
			}
		});
	});

	// The save path strips the extension off `filename` and concatenates `ext`
	// back on, so `ext` has to carry its own dot. Ylilauta publishes the type
	// without one (`data-file-type="avif"`), and a dotless `ext` produced a save
	// name with no extension at all, which the gallery then refused. These
	// assertions run against the captured pages rather than a hand-made figure,
	// because the value the site actually publishes is what was wrong.
	group('attachment extensions', () {
		test('every captured page gives its attachments a dotted extension and a matching filename', () {
			final pages = <String, List<Post>>{
				'thread.html': YlilautaParser.parseThread(
					fixture('thread.html'),
					board: 'rikokset',
					threadId: 136422217,
					defaultUsername: 'Anonyymi',
					fetchedTime: DateTime(2026, 9, 20)
				).posts_,
				'catalog.html': YlilautaParser.parseCatalog(
					fixture('catalog.html'),
					board: 'rikokset',
					defaultUsername: 'Anonyymi',
					fetchedTime: DateTime(2026, 9, 20)
				).threads.values.expand((t) => t.posts_).toList(growable: false),
				'live_thread.html': YlilautaParser.parseThread(
					fixture('live_thread.html'),
					board: 'rikokset',
					threadId: 135614236,
					urlSlug: '28qom4',
					defaultUsername: 'Anonyymi',
					fetchedTime: DateTime(2026, 9, 20)
				).posts_
			};
			for (final entry in pages.entries) {
				final attachments = entry.value.expand((p) => p.attachments).toList(growable: false);
				expect(attachments, isNotEmpty, reason: '${entry.key}: no attachments parsed');
				for (final a in attachments) {
					expect(a.ext, startsWith('.'), reason: '${entry.key}: ext "${a.ext}" for ${a.id}');
					// A bare "." is as useless as no dot at all.
					expect(a.ext.length, greaterThan(1), reason: '${entry.key}: ext "${a.ext}" for ${a.id}');
					// The filename carries that same extension, so the save path
					// rebuilds exactly the name the site published.
					expect(a.filename, contains(a.ext), reason: '${entry.key}: filename "${a.filename}" lacks ext "${a.ext}"');
					expect(a.filename, endsWith(a.ext), reason: '${entry.key}: filename "${a.filename}" does not end with ext "${a.ext}"');
				}
			}
		});

		test('a type the markup gives without a dot still reaches the attachment dotted', () {
			// Every captured page happens to serve .avif; this checks the rule
			// rather than the one extension the fixtures carry.
			final thread = YlilautaParser.parseThread(
				_selfContainedThreadPage('<figure class="file" data-file-id="abc" '
					'data-file-src="https://i.ylilauta.org/ab/c/abc.webm" data-file-type="webm" '
					'data-media-type="video"></figure>'),
				board: 'b',
				threadId: 5,
				urlSlug: '1',
				defaultUsername: 'Anonyymi',
				fetchedTime: DateTime(2026, 9, 20)
			);
			final attachment = thread.posts_.single.attachments.single;
			expect(attachment.ext, '.webm');
			expect(attachment.filename, 'abc.webm');
			expect(attachment.filename, endsWith(attachment.ext));
			expect(attachment.type, AttachmentType.webm);
		});
	});

	// `data-file-size="0"` is what ylilauta publishes wherever it has not
	// measured a file - the board listing, and some thread posts. Zero is a
	// placeholder there, not a size: passing it on printed "0 B" against every
	// previewed file and, being non-null, it also blocked the real size from
	// being merged in when the thread itself was fetched. The existing
	// `attachment sizes` group covers the catalog case; these extend it.
	group('attachment size boundaries', () {
		test('a real byte count on a thread page is kept', () {
			final thread = YlilautaParser.parseThread(
				fixture('thread.html'),
				board: 'rikokset',
				threadId: 136422217,
				defaultUsername: 'Anonyymi',
				fetchedTime: DateTime(2026, 9, 20)
			);
			final sizes = thread.posts_.expand((p) => p.attachments).map((a) => a.sizeInBytes).toSet();
			expect(sizes, {37061});
		});

		test('a zero on a thread page is unknown while the measured sizes survive it', () {
			final thread = YlilautaParser.parseThread(
				fixture('live_thread.html'),
				board: 'rikokset',
				threadId: 135614236,
				urlSlug: '28qom4',
				defaultUsername: 'Anonyymi',
				fetchedTime: DateTime(2026, 9, 20)
			);
			final sizes = thread.posts_.expand((p) => p.attachments).map((a) => a.sizeInBytes).toList(growable: false);
			// The same page carries one placeholder and two real sizes.
			expect(sizes, contains(null));
			expect(sizes, containsAll([70351, 329885]));
			expect(sizes, isNot(contains(0)));
		});

		test('the boundary is exactly zero, whatever the attribute holds', () {
			int? sizeFor(String attribute) {
				final thread = YlilautaParser.parseThread(
					_selfContainedThreadPage('<figure class="file" data-file-id="abc" '
						'data-file-src="https://i.ylilauta.org/ab/c/abc.png" data-file-type="png" '
						'data-media-type="image" $attribute></figure>'),
					board: 'b',
					threadId: 5,
					urlSlug: '1',
					defaultUsername: 'Anonyymi',
					fetchedTime: DateTime(2026, 9, 20)
				);
				return thread.posts_.single.attachments.single.sizeInBytes;
			}
			// The exact placeholder the site publishes where it has not measured.
			expect(sizeFor('data-file-size="0"'), isNull);
			// A measured size is passed through unchanged.
			expect(sizeFor('data-file-size="70351"'), 70351);
			// Nothing published, and something unparseable, are unknown as well.
			expect(sizeFor(''), isNull);
			expect(sizeFor('data-file-size="unknown"'), isNull);
		});
	});

	// `img.flag` is the country flag the site shows beside a post. The `flags`
	// group covers the ordinary case; these are the shapes it can also take.
	group('flag images', () {
		ImageboardFlag? flagOf(String img) {
			final thread = YlilautaParser.parseThread(
				'<div class="card thread" data-thread-id="5" data-url="https://ylilauta.org/international/29dbm4">'
					'<div class="post op-post op" data-post-id="7" data-user-id="0">'
					'<div class="post-meta"><span class="time" data-timestamp="1766075036">now</span>$img</div>'
					'<div class="post-message">hello</div></div></div>',
				board: 'international',
				threadId: 5,
				urlSlug: '29dbm4',
				defaultUsername: 'Anonyymi',
				fetchedTime: DateTime(2026, 9, 20)
			);
			return thread.posts_.single.flag as ImageboardFlag?;
		}

		test('absolutises a flag the page names only by path', () {
			final flag = flagOf('<img class="flag" alt="FI" title="Finland" src="/static/img/flags/fi.png">')!;
			expect(flag.name, 'Finland');
			expect(flag.imageUrl, 'https://ylilauta.org/static/img/flags/fi.png');
		});

		test('falls back to the alt text when there is no title', () {
			final flag = flagOf('<img class="flag" alt="SE" src="https://ylilauta.org/static/img/flags/se.png">')!;
			expect(flag.name, 'SE');
			expect(flag.imageUrl, 'https://ylilauta.org/static/img/flags/se.png');
		});

		test('a flag image with nothing to name it or point at is ignored', () {
			// Without a source there is nothing to draw.
			expect(flagOf('<img class="flag" alt="FI" title="Finland">'), isNull);
			// An empty source counts as none.
			expect(flagOf('<img class="flag" title="Finland" src="">'), isNull);
			// Without a name - title or alt - there is nothing to label it.
			expect(flagOf('<img class="flag" src="https://ylilauta.org/static/img/flags/fi.png">'), isNull);
		});

		test('a compact catalog card carries its flag too', () {
			// A board-page card has no `div.post`; its flag hangs off the card
			// itself, which is a separate code path from a thread page's post.
			const html = '<div class="card thread op-post op" data-thread-id="42">'
				'<a class="card-post" href="/international/29dbm4"><div class="message">hi</div></a>'
				'<button data-post-id="99"></button>'
				'<img class="flag" alt="SE" title="Sweden" src="https://ylilauta.org/static/img/flags/se.png">'
				'</div>';
			final catalog = YlilautaParser.parseCatalog(
				html,
				board: 'international',
				defaultUsername: 'Anonyymi',
				fetchedTime: DateTime(2026, 9, 20)
			);
			final flag = catalog.threads[42]!.posts_.single.flag as ImageboardFlag;
			expect(flag.name, 'Sweden');
			expect(flag.imageUrl, 'https://ylilauta.org/static/img/flags/se.png');
		});

		test('a captured listing with no flags gives every post none', () {
			final catalog = YlilautaParser.parseCatalog(
				fixture('live_board.html'),
				board: 'satunnainen',
				defaultUsername: 'Anonyymi',
				fetchedTime: DateTime(2026, 9, 20)
			);
			final posts = catalog.threads.values.expand((t) => t.posts_).toList(growable: false);
			expect(posts, isNotEmpty);
			expect(posts.every((p) => p.flag == null), isTrue);
		});
	});

	// A page's thread cards are matched by selector, and the selector matches
	// every card a page lists. The one that must be parsed is the card whose own
	// address names the thread; reading the first card instead showed posts from
	// a thread nobody opened. The `thread by slug` group covers the empty decoy;
	// these make the decoy a real, fully-formed thread and pin the rule itself.
	group('thread card selection', () {
		const decoy = '<div class="card thread" data-thread-id="1" data-url="https://ylilauta.org/rikokset/decoy">'
			'<div class="post op-post op" data-post-id="111111" data-user-id="0">'
			'<div class="post-message">a decoy thread with a real post</div></div></div>';

		test('parseThread reads the card the slug names, not the first card', () {
			final html = fixture('live_thread.html').replaceFirst('<body>', '<body>$decoy');
			final thread = YlilautaParser.parseThread(
				html,
				board: 'rikokset',
				threadId: 135614236,
				urlSlug: '28qom4',
				defaultUsername: 'Anonyymi',
				fetchedTime: DateTime(2026, 9, 20)
			);
			expect(thread.id, 135614236);
			// The decoy is a valid thread, so picking it would not throw - it
			// would silently return the wrong posts. This is what catches that.
			expect(thread.posts_.any((p) => p.id == 111111), isFalse);
			expect(thread.posts_.first.id, 298177512);
		});

		test('parseThreadBySlug ignores a decoy that has posts of its own', () {
			final html = fixture('live_thread.html').replaceFirst('<body>', '<body>$decoy');
			final thread = YlilautaParser.parseThreadBySlug(
				html,
				board: 'rikokset',
				slug: '28qom4',
				defaultUsername: 'Anonyymi',
				fetchedTime: DateTime(2026, 9, 20)
			);
			expect(thread.id, 135614236);
			expect(thread.urlSlug, '28qom4');
			expect(thread.posts_.any((p) => p.id == 111111), isFalse);
		});

		test('a card that merely ends in the same text is not the slug', () {
			// The slug is a whole path segment: /rikokset/not28qom4 is another
			// thread, and choosing it because the string ends with the slug would
			// read the wrong thread.
			const nearMiss = '<div class="card thread" data-thread-id="2" data-url="https://ylilauta.org/rikokset/not28qom4">'
				'<div class="post op-post op" data-post-id="222222" data-user-id="0">'
				'<div class="post-message">near miss</div></div></div>';
			final html = fixture('live_thread.html').replaceFirst('<body>', '<body>$nearMiss');
			final thread = YlilautaParser.parseThreadBySlug(
				html,
				board: 'rikokset',
				slug: '28qom4',
				defaultUsername: 'Anonyymi',
				fetchedTime: DateTime(2026, 9, 20)
			);
			expect(thread.id, 135614236);
			expect(thread.posts_.any((p) => p.id == 222222), isFalse);
		});

		test('cardForSlug picks the card naming the slug and falls back to the first', () {
			const html = '<div class="card thread" data-thread-id="1" data-url="https://ylilauta.org/b/first"></div>'
				'<div class="card thread" data-thread-id="2" data-url="https://ylilauta.org/b/wanted"></div>';
			final document = html_parser.parse(html);
			expect(YlilautaParser.cardForSlug(document, 'wanted')!.attributes['data-thread-id'], '2');
			// Nothing on the page names it: the first card is still the only
			// thing that can be read, and a readable thread must not become a
			// missing one just because its address is absent.
			expect(YlilautaParser.cardForSlug(document, 'missing')!.attributes['data-thread-id'], '1');
		});
	});

	// A post's own address (`/post/<id>`, which is the href the site renders
	// for every reference) is answered with the thread holding that post, and
	// nothing on that page says which thread it is except its card's own
	// `data-url`. `decodeUrl` reads the board and slug from here, so these pin
	// what that address reports.
	group('threadAddress', () {
		({String board, String slug})? addressOf(String html) => YlilautaParser.threadAddress(html);

		String pageWithAddress(String dataUrl) =>
			'<div class="card thread" data-thread-id="5" data-url="$dataUrl"></div>';

		test('a thread page names its own board and slug', () {
			final address = addressOf(fixture('live_thread.html'))!;
			expect(address.board, 'rikokset');
			expect(address.slug, '28qom4');
		});

		test('a page with no card is not a thread address', () {
			expect(addressOf('<html><body><p>nothing here</p></body></html>'), isNull);
		});

		test('a card without a data-url names no thread', () {
			expect(addressOf('<div class="card thread" data-thread-id="5"></div>'), isNull);
		});

		test('an address with fewer than two segments names no thread', () {
			// A slug on its own, a bare board - with or without its trailing
			// slash - and an empty address all have nothing to split into a
			// board and a slug.
			expect(addressOf(pageWithAddress('28qom4')), isNull);
			expect(addressOf(pageWithAddress('/rikokset')), isNull);
			expect(addressOf(pageWithAddress('/rikokset/')), isNull);
			expect(addressOf(pageWithAddress('')), isNull);
		});

		test('a trailing slash or a query still yields two non-empty segments', () {
			// A trailing slash adds an empty segment, which has to be dropped
			// rather than read as the slug: a slug of '' matches no card, so
			// `parseThreadBySlug` would fail on the page it was just served.
			for (final url in [
				'https://ylilauta.org/rikokset/28qom4/',
				'https://ylilauta.org/rikokset/28qom4?page=2',
				'https://ylilauta.org/rikokset/28qom4#post-317373496'
			]) {
				final address = addressOf(pageWithAddress(url))!;
				// Only the path counts: a query or fragment is not the slug.
				final path = url.split(RegExp(r'[?#]')).first;
				final segments = path.split('/').where((p) => p.isNotEmpty).toList(growable: false);
				expect(address.board, segments[segments.length - 2], reason: url);
				expect(address.slug, segments.last, reason: url);
				expect(address.board, isNotEmpty, reason: url);
				expect(address.slug, isNotEmpty, reason: url);
				expect(address.slug, isNot(contains('?')), reason: url);
				expect(address.slug, isNot(contains('#')), reason: url);
			}
			// The clean trailing-slash case is exact: the slash did not shift
			// the window onto the board.
			final trailing = addressOf(pageWithAddress('https://ylilauta.org/rikokset/28qom4/'))!;
			expect(trailing.board, 'rikokset');
			expect(trailing.slug, '28qom4');
			// A query rides on the segment it is attached to instead of leaving
			// an empty slug behind; the board is still the path segment before
			// it. It is not stripped here, so only what must survive is pinned.
			final query = addressOf(pageWithAddress('https://ylilauta.org/rikokset/28qom4?page=2'))!;
			expect(query.board, 'rikokset');
			expect(query.slug, startsWith('28qom4'));
		});
	});
}

/// A thread page whose card is the whole document, with one post.
///
/// Built here rather than captured so a single markup detail can be varied
/// (the size attribute, the file type) without a second fixture.
String _selfContainedThreadPage(String figure) =>
	'<div class="card thread" data-thread-id="5" data-url="https://ylilauta.org/b/1">'
	'<div class="post op-post op" data-post-id="7" data-user-id="0">'
	'$figure'
	'<div class="post-message">body</div></div></div>';
