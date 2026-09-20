import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:chan/models/attachment.dart';
import 'package:chan/models/post.dart';
import 'package:chan/models/thread.dart';
import 'package:chan/services/persistence.dart';
import 'package:chan/sites/imageboard_site.dart' as ibs;
import 'package:chan/sites/lainchan.dart';
import 'package:chan/sites/loistolauta.dart';
import 'package:chan/widgets/post_spans.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;

/// These tests run [SiteLoistolauta] against pages captured from loistolauta.org.
///
/// The adapter is lainchan's, so what can go wrong here is not the markup but
/// the wiring: which endpoints the engine actually serves, whether the board
/// list drops the board that publishes no title, and whether the reply form
/// this site renders is the one `SiteLainchan.submitPost` reads.
String fixture(String name) => File('test/loistolauta_fixtures/$name').readAsStringSync();

DateTime _local(int seconds) => DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true).toLocal();

SiteLoistolauta makeSite() => SiteLoistolauta(
	name: 'loistolauta',
	baseUrl: 'loistolauta.org',
	imageUrl: null,
	overrideUserAgent: null,
	addIntrospectedHeaders: false,
	preferHttp3WithoutAltSvc: null,
	boardsWithHtmlOnlyFlags: const [],
	boardsWithMemeFlags: null,
	archives: const [],
	imageHeaders: const {},
	videoHeaders: const {},
	additionalCookies: const {},
	turnstileSiteKey: null
);

Response _jsonResponse(String url, String body) => Response(
	requestOptions: RequestOptions(path: Uri.parse(url).path),
	statusCode: 200,
	data: jsonDecode(body),
	headers: Headers.fromMap({
		Headers.contentTypeHeader: ['application/json'],
		'last-modified': ['Tue, 15 Sep 2026 20:14:59 GMT']
	})
);

/// Two canned responses: the page whose form `submitPost` reads, then whatever
/// the POST to /post.php gets back. The requests are kept so the test can see
/// exactly what would go on the wire.
class _CannedAdapter implements HttpClientAdapter {
	final List<ResponseBody Function(RequestOptions options)> responses;
	final captured = <RequestOptions>[];
	_CannedAdapter(this.responses);

	@override
	Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future? cancelFuture) async {
		captured.add(options);
		return responses[captured.length - 1](options);
	}

	@override
	void close({bool force = false}) {}
}

ResponseBody _html(String body, [int statusCode = 200]) => ResponseBody.fromString(body, statusCode, headers: {
	Headers.contentTypeHeader: ['text/html; charset=utf-8']
});

ibs.DraftPost _draft({String? name = 'Anonyymi', String text = 'testiviesti'}) => ibs.DraftPost(
	board: 'a',
	threadId: 1999,
	name: name,
	options: null,
	text: text,
	useLoginSystem: null,
	files: []
);

void main() {
	setUpAll(Persistence.initializeForTesting);

	group('boards', () {
		test('reads every board from the root page, including the untitled one', () async {
			final site = makeSite();
			final adapter = _CannedAdapter([
				(_) => _html(fixture('boards.html'))
			]);
			site.client.httpClientAdapter = adapter;
			final boards = await site.getBoards(priority: ibs.RequestPriority.interactive);
			// There is no /boards.json on this engine, so this is the root page.
			expect(adapter.captured.single.uri, Uri.https('loistolauta.org', '/'));
			// /ukko/ carries no title attribute at all, which is why
			// SiteLainchanOrg's scraper cannot be reused unchanged: its
			// `title != null` filter would drop the board silently.
			expect(boards.map((b) => b.name), ['b', 'a', 'int', 'meta', 'ukko']);
			expect(boards.map((b) => b.title), [
				'Sporadinen',
				'Animesatunnainen',
				'Interdimensional',
				'Pervitiini ja palaute',
				'ukko'
			]);
			expect(boards.every((b) => b.filesPerPost == 4), isTrue);
			expect(boards.every((b) => b.maxImageSizeBytes == 25000000), isTrue);
			expect(boards.every((b) => b.isWorksafe), isFalse);
		});
	});

	group('catalog', () {
		late final List<Thread> threads;
		setUpAll(() async {
			threads = await makeSite().makeCatalog(
				'a',
				_jsonResponse('https://loistolauta.org/a/catalog.json', fixture('catalog.json')),
				priority: ibs.RequestPriority.interactive
			);
		});

		test('makes a thread per card, with the card\'s own counts', () {
			// The capture keeps three of the board's 26 pages.
			expect(threads.map((t) => t.id), [1635, 1494, 1615, 1576, 695, 691, 676, 689, 31, 30, 28, 26]);
			final first = threads.first;
			expect(first.board, 'a');
			expect(first.id, 1635);
			expect(first.title, isNull);
			expect(first.isSticky, isFalse);
			expect(first.replyCount, 0);
			expect(first.imageCount, 0);
			expect(first.time, _local(1727876760));
			expect(first.posts_.single.text, isNotEmpty);
		});

		test('keeps the omitted image count in the thread total', () {
			// vichan publishes `images` and `omitted_images` separately; the
			// adapter has to add them or a busy thread looks emptier than it is.
			final card = threads.firstWhere((t) => t.id == 676);
			expect(card.replyCount, 8);
			expect(card.imageCount, 0 + 2);
			expect(threads.firstWhere((t) => t.id == 1494).imageCount, 1);
		});

		test('numbers the catalog pages the way the engine does', () {
			// `page` is zero-based in the JSON and stored one-based; the board
			// page's own pager links to 1..26, so those numbers are what the
			// catalog has to agree with.
			final byId = {for (final t in threads) t.id: t.currentPage};
			expect(byId[1635], 3);
			expect(byId[695], 13);
			expect(byId[26], 26);
			expect(byId.values.toSet(), {3, 13, 26});
		});

		test('carries a card\'s attachment, including its type', () {
			final card = threads.firstWhere((t) => t.id == 691);
			final attachment = card.attachments.single;
			expect(attachment.type, AttachmentType.image);
			expect(attachment.ext, '.png');
			expect(attachment.filename, 'anyone wanna fap on vc.png');
			expect(attachment.url, 'https://loistolauta.org/a/src/1699878631178.png');
			// A catalog card is JSON only, so the thumbnail is the one the app
			// derives from `ext`; the thread page corrects it (see below).
			expect(attachment.thumbnailUrl, 'https://loistolauta.org/a/thumb/1699878631178.png');
		});
	});

	group('thread', () {
		test('reads every post\'s id, name and timestamp', () async {
			final thread = await makeSite().makeThread(
				ThreadIdentifier('a', 2148),
				_jsonResponse('https://loistolauta.org/a/res/2148.json', fixture('thread.json')),
				priority: ibs.RequestPriority.interactive
			);
			expect(thread.board, 'a');
			expect(thread.id, 2148);
			expect(thread.posts_.map((p) => p.id), [2148, 2156, 2157, 2158]);
			expect(thread.posts_.map((p) => p.threadId), everyElement(2148));
			expect(thread.posts_.first.name, 'harasoo');
			expect(thread.posts_.first.time, _local(1780928072));
			expect(thread.posts_.first.spanFormat, PostSpanFormat.lainchan);
			expect(thread.posts_[1].name, 'Anonyymi');
			expect(thread.posts_[1].time, _local(1783037544));
			// The thread payload carries no `replies` count, so it comes from
			// the posts present.
			expect(thread.replyCount, 3);
			expect(thread.imageCount, 1);
			expect(thread.isSticky, isFalse);
			// The engine sends no flag, poster id or capcode on this board.
			expect(thread.posts_.every((p) => p.flag == null), isTrue);
			expect(thread.posts_.every((p) => p.posterId == null), isTrue);
			expect(thread.posts_.every((p) => p.capcode == null), isTrue);
		});

		test('parses an attachment with its source, size and dimensions', () async {
			final thread = await makeSite().makeThread(
				ThreadIdentifier('a', 2148),
				_jsonResponse('https://loistolauta.org/a/res/2148.json', fixture('thread.json')),
				priority: ibs.RequestPriority.interactive
			);
			final attachment = thread.posts_.firstWhere((p) => p.id == 2158).attachments.single;
			expect(attachment.id, '1784877334467');
			expect(attachment.type, AttachmentType.image);
			expect(attachment.ext, '.png');
			expect(attachment.filename, 'Näyttökuva 2026-07-23 232144.png');
			expect(attachment.url, 'https://loistolauta.org/a/src/1784877334467.png');
			expect(attachment.thumbnailUrl, 'https://loistolauta.org/a/thumb/1784877334467.jpg');
			expect(attachment.md5, 'WvZOWY0G4ZNoG/6OxRPung==');
			expect(attachment.sizeInBytes, 5748);
			expect(attachment.width, 335);
			expect(attachment.height, 109);
			expect(attachment.spoiler, isFalse);
			// An image-less reply reports no attachments rather than an empty one.
			expect(thread.posts_.firstWhere((p) => p.id == 2156).attachments, isEmpty);
		});

		test('corrects the thumbnail from the thread page, which names it .jpg', () async {
			// The JSON payload has no `thumb`, so the app guesses a thumbnail
			// named after `ext`. vichan never serves those - every image and
			// video preview is `<tim>.jpg`, and a sound file gets a generic
			// icon - so the inherited makeThread re-reads the rendered thread
			// page to correct them. This runs that against the capture.
			final site = makeSite();
			final adapter = _CannedAdapter([
				(_) => _html(fixture('thread_2148.html'))
			]);
			site.client.httpClientAdapter = adapter;
			final thread = await site.makeThread(
				ThreadIdentifier('a', 2148),
				_jsonResponse('https://loistolauta.org/a/res/2148.json', fixture('thread.json')),
				priority: ibs.RequestPriority.interactive
			);
			expect(adapter.captured.single.uri, Uri.https('loistolauta.org', '/a/res/2148.html'));
			expect(thread.posts_.firstWhere((p) => p.id == 2158).attachments.single.thumbnailUrl,
				'https://loistolauta.org/a/thumb/1784877334467.jpg');
		});

		test('types a video post as a video and still finds its thumbnail', () async {
			final thread = await makeSite().makeThread(
				ThreadIdentifier('a', 1130),
				_jsonResponse('https://loistolauta.org/a/res/1130.json', fixture('thread_video.json')),
				priority: ibs.RequestPriority.interactive
			);
			final video = thread.posts_.first.attachments.single;
			expect(video.type, AttachmentType.mp4);
			expect(video.ext, '.mp4');
			expect(video.url, 'https://loistolauta.org/a/src/1702934215110.mp4');
			// vichan names the poster frame <tim>.jpg, whatever the format.
			expect(video.thumbnailUrl, 'https://loistolauta.org/a/thumb/1702934215110.jpg');
			expect(video.width, 426);
			expect(video.height, 240);
			expect(video.sizeInBytes, 38051);
		});

		test('keeps the quotes a reply carries', () async {
			final thread = await makeSite().makeThread(
				ThreadIdentifier('a', 1999),
				_jsonResponse('https://loistolauta.org/a/res/1999.json', fixture('thread_backlinks.json')),
				priority: ibs.RequestPriority.interactive
			);
			// Quotes arrive as anchors to #<id>, not as spans.
			final quoting = thread.posts_.firstWhere((p) => p.id == 2001);
			expect(quoting.text, contains('/a/res/1999.html#2000'));
			final spans = quoting.span.children;
			expect(spans.first, isA<PostQuoteLinkSpan>());
			final quote = spans.first as PostQuoteLinkSpan;
			expect(quote.postId, 2000);
			expect(quote.threadId, 1999);
			expect(quote.board, 'a');
			// ... and a post that quotes nothing reports no references.
			expect(quoting.repliedToIds, contains(2000));
			expect(thread.posts_.firstWhere((p) => p.id == 2000).repliedToIds, isEmpty);
		});
	});

	// The engine's markup here is lainchan's, which is why the site shares
	// PostSpanFormat.lainchan instead of getting an enum value of its own.
	// These run real captures through the span the app will render.
	group('post spans', () {
		test('renders a quote link, the line breaks and the text around them', () {
			final span = SiteLainchan.makeSpan('a', 1999, fixture('post_body.html').trim());
			expect(span.children, hasLength(4));
			final quote = span.children[0] as PostQuoteLinkSpan;
			expect(quote.board, 'a');
			expect(quote.threadId, 1999);
			expect(quote.postId, 2000);
			expect(span.children[1], isA<PostLineBreakSpan>());
			expect(span.children[2], isA<PostLineBreakSpan>());
			expect((span.children[3] as PostTextSpan).text, 'Mop mop tän langan salasana on paska');
		});

		test('renders the inline markup the engine writes in a body', () {
			final span = SiteLainchan.makeSpan('a', 2148, '<span class="quote">&gt;7 f b b a</span><br/>fobba lol');
			expect(span.children, hasLength(3));
			final quote = span.children[0] as PostQuoteSpan;
			expect(((quote.child as PostNodeSpan).children.single as PostTextSpan).text, '>7 f b b a');
			expect(span.children[1], isA<PostLineBreakSpan>());
			expect((span.children[2] as PostTextSpan).text, 'fobba lol');
		});

		test('makes a plain URL a link', () {
			final span = SiteLainchan.makeSpan('a', 1, 'look at https://example.com/x now');
			final link = span.children.whereType<PostLinkSpan>().single;
			expect(link.url, 'https://example.com/x');
		});

		test('a green text line is a quote, not bold markup', () {
			// The engine emits `<span class="quote">`, which is what stops a
			// greentext line from being rendered as an ordinary paragraph.
			final span = SiteLainchan.makeSpan('a', 1, '<span class="quote">&gt;tfw</span>');
			expect(span.children.single, isA<PostQuoteSpan>());
		});
	});

	// The site answers an ordinary HTTP client - every fixture here was fetched
	// with one - so nothing in the posting path needs a WebView. What it does
	// need is the engine's own form and field names, which is what these pin
	// down. No post was ever made.
	group('posting', () {
		test('the captured form is the engine\'s multipart post form', () {
			final form = html_parser.parseFragment(fixture('post_form.html')).querySelector('form')!;
			expect(form.attributes['action'], '/post.php');
			expect(form.attributes['enctype'], 'multipart/form-data');
			expect(form.attributes['name'], 'post');
			final names = form.querySelectorAll('input, textarea').map((e) => e.attributes['name']).whereType<String>().toSet();
			// These are the engine's names, and submitPost writes to exactly
			// them.
			// This is the block page's form, so it has no `thread` field; the
			// reply form on a thread page adds one. submitPost writes both by
			// setting `thread` from the DraftPost rather than relying on the
			// page it fetched.
			expect(names, containsAll(['board', 'name', 'email', 'subject', 'body', 'file', 'embed', 'password', 'post']));
			expect(names, isNot(contains('thread')));
			// The site also renders a per-visit set of honeypot fields with
			// random names, wrapped around `hash`. submitPost echoes them all
			// back because it collects the whole form.
			expect(names, contains('hash'));
			expect(form.querySelector('input[type="file"]')?.attributes['name'], 'file');
			expect(form.querySelector('textarea[name="body"]'), isNotNull);
		});

		test('submits the engine\'s fields, and reports the id from the redirect', () async {
			final site = makeSite();
			final adapter = _CannedAdapter([
				(_) => _html(fixture('post_form.html')),
				(_) {
					final body = ResponseBody.fromString('', 302, headers: {
						Headers.contentTypeHeader: ['text/html; charset=utf-8'],
						'location': ['https://loistolauta.org/a/res/1999.html#2003']
					}, isRedirect: true);
					body.redirects = [RedirectRecord(302, 'POST', Uri.parse('https://loistolauta.org/a/res/1999.html#2003'))];
					return body;
				}
			]);
			site.client.httpClientAdapter = adapter;
			final receipt = await site.submitPost(_draft(), ibs.NoCaptchaSolution(DateTime.now()), CancelToken());
			expect(receipt.id, 2003);
			// The first request is the page that carries the form; the second is
			// the post itself.
			expect(adapter.captured, hasLength(2));
			expect(adapter.captured[0].uri, Uri.https('loistolauta.org', '/a/res/1999.html'));
			final post = adapter.captured[1];
			expect(post.uri, Uri.https('loistolauta.org', '/post.php'));
			expect(post.headers['Origin'], 'https://loistolauta.org');
			expect(post.headers['Referer'], 'https://loistolauta.org/a/res/1999.html');
			final data = post.data as FormData;
			final fields = {for (final f in data.fields) f.key: f.value};
			expect(fields['body'], 'testiviesti');
			expect(fields['board'], 'a');
			expect(fields['thread'], '1999');
			expect(fields['name'], 'Anonyymi');
			expect(fields['password'], isNotEmpty);
			expect(fields['post'], 'Lähetä');
			// The honeypots and the form's hash have to come along, or the
			// engine's spam checks see a request it never rendered.
			expect(fields['hash'], '965d146fbfb4af253c53ee52056acf0aa90731db');
			expect(fields.keys.where((k) => k.length > 20), isNotEmpty);
		});

		test('reports a refusal by the message the engine rendered', () async {
			// Captured from a POST to /post.php for a board that does not exist.
			// This is the shape of every refusal the engine makes: HTTP >= 400
			// with <h2> carrying the reason.
			final site = makeSite();
			site.client.httpClientAdapter = _CannedAdapter([
				(_) => _html(fixture('post_form.html')),
				(_) => _html(fixture('refusal_page.html'), 400)
			]);
			await expectLater(
				site.submitPost(_draft(name: null, text: 'x'), ibs.NoCaptchaSolution(DateTime.now()), CancelToken()),
				throwsA(isA<ibs.PostFailedException>().having((e) => e.reason, 'reason', 'Invalid board!'))
			);
		});

		test('a board list is not served as JSON', () async {
			// The engine answers /boards.json with the server's own 404 page,
			// which is why the board list cannot be read the way lainchan's own
			// getBoards reads it.
			final site = makeSite();
			site.client.httpClientAdapter = _CannedAdapter([
				(_) => _html('<!DOCTYPE HTML PUBLIC "-//IETF//DTD HTML 2.0//EN"><html><head><title>404 Not Found</title></head><body><h1>Not Found</h1></body></html>', 404)
			]);
			await expectLater(
				site.getBoards(priority: ibs.RequestPriority.interactive),
				throwsA(isA<ibs.HTTPStatusException>())
			);
		});
	});

	group('registration', () {
		test('makeSite builds the adapter from the config the parent writes', () {
			final site = makeSiteFromConfig();
			expect(site, isA<SiteLoistolauta>());
			expect(site.siteType, 'loistolauta');
			expect(site.baseUrl, 'loistolauta.org');
			expect(site.defaultUsername, 'Anonyymi');
			// vichan's own url shape, which the inherited decoder understands.
			expect(site.getWebUrl(board: 'a', threadId: 1999), 'https://loistolauta.org/a/res/1999.html');
			expect(site.getWebUrl(board: 'a'), 'https://loistolauta.org/a/');
		});

		test('the config\'s posting limits reach the adapter', () {
			// A definition that says nothing about limits still gets usable
			// ones, and one that does is not ignored.
			expect((makeSiteFromConfig() as SiteLoistolauta).filesPerPost, 4);
			final configured = ibs.makeSite(<String, dynamic>{
				'type': 'loistolauta',
				'name': 'loistolauta',
				'baseUrl': 'loistolauta.org',
				'filesPerPost': 2,
				'maxUploadSizeBytes': 1234
			}) as SiteLoistolauta;
			expect(configured.filesPerPost, 2);
			expect(configured.maxUploadSizeBytes, 1234);
		});

		test('decodes a thread url back to its board and id', () async {
			final site = makeSite();
			expect(await site.decodeUrl(Uri.parse('https://loistolauta.org/a/res/1999.html#q2000')),
				BoardThreadOrPostIdentifier('a', 1999, 2000));
			expect(await site.decodeUrl(Uri.parse('https://loistolauta.org/a/')), BoardThreadOrPostIdentifier('a'));
			expect(await site.decodeUrl(Uri.parse('https://loistolauta.org/')), isNull);
		});
	});
}

ibs.ImageboardSite makeSiteFromConfig() => ibs.makeSite(<String, dynamic>{
	'type': 'loistolauta',
	'name': 'loistolauta',
	'baseUrl': 'loistolauta.org',
	'defaultUsername': 'Anonyymi',
	'filesPerPost': 4
});
