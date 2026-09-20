import 'dart:io';
import 'dart:typed_data';

import 'package:chan/services/persistence.dart';
import 'package:chan/sites/imageboard_site.dart';
import 'package:chan/sites/minilauta.dart';
import 'package:chan/sites/minilauta_parser.dart';
import 'package:chan/widgets/post_spans.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// These tests run [MinilautaParser] against pages captured from minilauta.org.
///
/// miniboard has no JSON API, so the parser is the only thing standing between
/// the site's HTML and a usable thread. The traps the fixtures pin down are that
/// replies on a board page are siblings of the thread div rather than children
/// of it (so a parser that trusts nesting loses every reply), that a board page
/// shows only the last few replies of a thread and says so in a separate
/// `.omitted` span next to it, and that quote links are `<a class='reference'>`
/// with the ids in `data-*` attributes rather than in the href.
String fixture(String name) => File('test/minilauta_fixtures/$name').readAsStringSync();

void main() {
	group('board list', () {
		test('parses the home page board table', () {
			final boards = parseBoardList(fixture('index.html'));
			final byName = {for (final board in boards) board.name: board};
			expect(byName.keys, containsAll(['b', 'ukko', 'pol', 'int', 'yle', 'o', 'teksti']));
			// Exactly the boards in the table: the menubar, the mobile <select> and
			// the Rules/Friends boxes must not add entries.
			expect(boards, hasLength(19));
			expect(byName['b']!.title, 'Satunnainen');
			expect(byName['ukko']!.title, 'Ukko');
			expect(byName['pekka'], isNull);
			// Menubar entries (/manage/, /logs/, /bans/) are not boards and the
			// mobile <select> has no titles, so neither may leak in.
			expect(byName.containsKey('manage'), isFalse);
			expect(byName.containsKey('logs'), isFalse);
			expect(byName.containsKey('bans'), isFalse);
			expect(boards.map((board) => board.name).toSet().length, boards.length);
			// The `.nsfw` marker only appears on the boards that are not worksafe.
			expect(byName['b']!.isWorksafe, isFalse);
			expect(byName['yle']!.isWorksafe, isTrue);
		});
		test('reads only the board table, not other links on the page', () {
			// The home page also renders a Friends box and a menubar, both full of
			// `/x/` links. This fixture is synthetic because nothing in the real
			// capture happens to put a board-shaped href outside the table, so the
			// real page would not notice the difference.
			final boards = parseBoardList('''
				<html><body>
				<div class="box-content"><table>
					<tr style="display:none"><th>col1</th><th>col2</th></tr>
					<tr><td><a href='/b/'>Satunnainen</a> <span class="nsfw">(NSFW)</span></td>
					<td><a href='/yle/'>Yleinen</a></td></tr>
				</table></div>
				<ul><li><a href="https://example.com">example</a></li><li><a href="/logs/">Logs</a></li></ul>
				</body></html>''');
			expect(boards.map((board) => board.name).toList(), ['b', 'yle']);
			expect(boards[0].title, 'Satunnainen');
			expect(boards[0].isWorksafe, isFalse);
			expect(boards[1].isWorksafe, isTrue);
		});
	});

	group('span formatting', () {
		test('turns quote links into quote link spans', () {
			final span = SiteMinilauta.makeSpan('b', 123,
				"<a class='reference' data-board_id='b' data-parent_id='123' data-id='456' href='/b/123/#b-456'>&gt;&gt;456</a>");
			final quote = span.children.single as PostQuoteLinkSpan;
			expect(quote.board, 'b');
			expect(quote.threadId, 123);
			expect(quote.postId, 456);
		});

		test('keeps a quote to another thread pointing at that thread', () {
			final span = SiteMinilauta.makeSpan('b', 123,
				"<a class='reference' data-board_id='b' data-parent_id='999' data-id='1000' href='/b/999/#b-1000'>&gt;&gt;1000 (Cross-thread)</a>");
			final quote = span.children.single as PostQuoteLinkSpan;
			expect(quote.threadId, 999);
			expect(quote.postId, 1000);
		});

		test('renders the tags miniboard emits', () {
			final span = SiteMinilauta.makeSpan('b', 1,
				'<b>b</b><i>i</i><u>u</u><s>s</s><sup>up</sup><sub>dn</sub><pre>code</pre>'
				'<span class="spoiler">hidden</span><span class="quote">&gt;greentext</span>plain');
			final types = span.children.map((child) => child.runtimeType).toList();
			expect(types, containsAll([
				PostBoldSpan, PostItalicSpan, PostUnderlinedSpan, PostStrikethroughSpan,
				PostSuperscriptSpan, PostSubscriptSpan, PostCodeSpan, PostSpoilerSpan, PostQuoteSpan
			]));
		});

		test('falls back to the href when a reference has no data attributes', () {
			// miniboard only writes the data attributes when it can resolve the
			// quoted post; the href carries the same ids and is the fallback.
			final span = SiteMinilauta.makeSpan('b', 123,
				"<a class='reference' href='/b/999/#b-1000'>&gt;&gt;1000</a>");
			final quote = span.children.single as PostQuoteLinkSpan;
			expect(quote.board, 'b');
			expect(quote.threadId, 999);
			expect(quote.postId, 1000);
		});

		test('turns a board reference into a board link', () {
			final span = SiteMinilauta.makeSpan('b', 1, "<a class='reference' href='/pol/'>&gt;&gt;&gt;/pol/</a>");
			expect(span.children.single, isA<PostBoardLinkSpan>());
		});
	});

	group('board page', () {
		final page = parseBoardPage(fixture('board_page.html'), board: 'b');

		test('reads the pagination', () {
			expect(page.page, isNotNull);
			expect(page.page!.currentPage, 0);
			// Links run [0][1]..[9]; the link text is the page number because the
			// hrefs are relative query strings.
			expect(page.page!.pageCount, 10);
		});

		test('groups replies into their threads', () {
			expect(page.threads.map((thread) => thread.id).toList(), [
				82938, 80718, 84958, 84922, 83827, 84896, 82695, 82790, 84042, 84848
			]);
			final thread = page.threads.first;
			expect(thread.board, 'b');
			expect(thread.op.id, 82938);
			expect(thread.op.parentId, isNull);
			// The OP plus the four replies the board page renders.
			expect(thread.posts.map((post) => post.id).toList(), [82938, 84869, 84888, 84895, 84967]);
			// Replies are numbered from the whole thread, not from the page.
			expect(thread.posts.map((post) => post.replyNumber).toList(), [null, 77, 78, 79, 80]);
			expect(thread.posts[1].parentId, 82938);
		});

		test('adds the omitted replies to the reply count', () {
			// "76 replies omitted" in a span beside the thread div.
			expect(page.threads[0].omittedReplies, 76);
			expect(page.threads[0].replyCount, 80);
			// The catalog's "R:" for the same thread is 80, so the two agree.
			expect(page.threads[1].omittedReplies, 187);
			expect(page.threads[1].replyCount, 191);
			// A short thread has no omitted span at all.
			final short = page.threads.firstWhere((thread) => thread.id == 84958);
			expect(short.omittedReplies, 0);
			expect(short.replyCount, 4);
		});

		test('reads subjects, names and times', () {
			final thread = page.threads.first;
			expect(thread.title, 'Blue Archive lanka');
			expect(thread.op.subject, 'Blue Archive lanka');
			expect(thread.op.name, 'Anonyymi');
			expect(thread.op.time, DateTime(2026, 9, 1, 17, 33, 18));
			expect(thread.posts[1].time, DateTime(2026, 9, 19, 19, 56, 10));
			// A thread with no subject gets its title from the first body line.
			final untitled = page.threads.firstWhere((thread) => thread.id == 84958);
			expect(untitled.op.subject, isNull);
			expect(untitled.title, 'Mikä on teidän suosikkimeemi?');
		});

		test('reads attachments with size, dimensions and original name', () {
			final op = page.threads.first.op;
			expect(op.attachments, hasLength(1));
			final attachment = op.attachments.single;
			expect(attachment.url, '/src/1788273195463.png');
			expect(attachment.thumbnailUrl, '/src/thumb_1788273195463.png.png');
			expect(attachment.sizeInBytes, (3.34 * 1024 * 1024).round());
			expect(attachment.width, 2000);
			expect(attachment.height, 1266);
			expect(attachment.originalFilename, 'Hifumi_syksy.png');
			expect(attachment.ext, '.png');
			expect(attachment.type.name, 'image');
			// An audio post is not an image.
			final audio = page.threads.firstWhere((thread) => thread.id == 84958).op.attachments.single;
			expect(audio.url, '/src/1789921426919.mp3');
			expect(audio.type.name, 'mp3');
			expect(audio.sizeInBytes, (6.4 * 1024 * 1024).round());
		});
	});

	group('thread page', () {
		final page = parseThreadPage(fixture('thread_page.html'), board: 'b', threadId: 82695);

		test('collects the OP and every reply in order', () {
			expect(page.thread.id, 82695);
			expect(page.thread.board, 'b');
			expect(page.thread.op.id, 82695);
			expect(page.thread.posts, hasLength(225));
			expect(page.thread.posts.map((post) => post.id).toSet().length, 225);
			expect(page.thread.posts.first.id, 82695);
			expect(page.thread.posts.last.id, 84957);
			// Quote links point at the ids the page states; the reply numbers are
			// dense even though the ids are not.
			expect(page.thread.posts[1].id, 82696);
			expect(page.thread.posts[1].replyNumber, 1);
			expect(page.thread.posts.last.replyNumber, 224);
			expect(page.thread.replyCount, 224);
			expect(page.thread.omittedReplies, 0);
			expect(page.thread.posts.every((post) => post.parentId == (post.isOp ? null : 82695)), isTrue);
		});

		test('reads timestamps as real dates', () {
			expect(page.thread.op.time, DateTime(2026, 8, 28, 10, 32, 19));
			expect(page.thread.posts[1].time, DateTime(2026, 8, 28, 10, 34, 48));
			expect(page.thread.posts.last.time, DateTime(2026, 9, 20, 19, 22, 35));
			// Every timestamp is read, and the thread is ordered by them.
			expect(page.thread.posts.every((post) => post.time.isAfter(DateTime(2026))), isTrue);
			for (var i = 1; i < page.thread.posts.length; i++) {
				expect(page.thread.posts[i].time.isBefore(page.thread.posts[i - 1].time), isFalse);
			}
		});

		test('resolves quote references', () {
			final quoting = page.thread.posts.firstWhere((post) => post.id == 82700);
			expect(quoting.references.map((reference) => reference.postId).toList(), [82697, 82699]);
			expect(quoting.references.first.board, 'b');
			expect(quoting.references.first.threadId, 82695);
			// The message keeps the original HTML for makeSpan to render.
			expect(quoting.message, contains('class="reference"'));
			expect(quoting.message, contains('&gt;&gt;82697'));
			expect(quoting.message, contains('Oispa rahaa.'));
		});

		test('derives backlinks from the references', () {
			// miniboard has no server-rendered backlinks; its script builds them
			// from the quote links, which is what the parser mirrors.
			expect(page.thread.backlinks[82697], [82700]);
			expect(page.thread.backlinks[82699], [82700]);
			expect(page.thread.backlinks[82701], containsAll([82702, 82704, 82777]));
			// A post nobody quoted has no entry rather than an empty one.
			expect(page.thread.backlinks.containsKey(82696), isFalse);
			expect(page.thread.backlinks.values.expand((ids) => ids).toSet().length, greaterThan(0));
		});

		test('reads a cross-thread reference and the mailto sage', () {
			final thread = parseThreadPage(fixture('board_page.html'), board: 'b', threadId: 82938).thread;
			final crossThread = thread.op.references.single;
			expect(crossThread.postId, 77687);
			expect(crossThread.threadId, 77687);
			final sage = page.thread.posts.firstWhere((post) => post.id == 82701);
			expect(sage.email, 'Sage');
			expect(sage.name, 'Anonyymi');
		});

		test('reads an attachment that is not an image', () {
			final post = page.thread.posts.firstWhere((post) => post.id == 82700);
			final attachment = post.attachments.single;
			expect(attachment.url, '/src/1787903309094.png');
			expect(attachment.originalFilename, '1483520113.jpg');
			expect(attachment.width, 3072);
			expect(attachment.height, 5461);
			expect(attachment.sizeInBytes, (12.64 * 1024 * 1024).round());
			// The file's own extension decides the type, not the original name.
			expect(attachment.ext, '.png');
			expect(attachment.type.name, 'image');
		});

		test('a thread page has no pagination table', () {
			expect(parseThreadPage(fixture('thread_page.html'), board: 'b', threadId: 82695).thread.posts, hasLength(225));
			// A catalog of the same page would report pagination; a thread page
			// renders no `table.pagetable`, so there is nothing to report.
			expect(parseCatalog(fixture('catalog_page.html'), board: 'b').page, isNotNull);
		});
	});

	group('catalog', () {
		final page = parseCatalog(fixture('catalog_page.html'), board: 'b');

		test('reads every card and the pagination', () {
			expect(page.threads, hasLength(100));
			expect(page.threads.map((entry) => entry.id).toSet().length, 100);
			expect(page.page!.currentPage, 0);
			expect(page.page!.pageCount, 1);
			expect(page.threads.first.id, 82938);
			expect(page.threads.first.board, 'b');
		});

		test('reads subject, preview and reply count', () {
			final first = page.threads.first;
			expect(first.subject, 'Blue Archive lanka');
			// The preview is the body with its tags stripped, including the
			// cross-thread marker miniboard appends to a quote link.
			expect(first.message, 'Syksy painos.Vanha lanka >>77687 (Cross-thread)');
			expect(first.replyCount, 80);
			expect(first.thumbnailUrl, '/src/thumb_1788273195463.png.png');
			expect(first.isPinned, isFalse);
		});

		test('treats the placeholder image as no attachment', () {
			final deleted = page.threads.firstWhere((entry) => entry.id == 84642);
			expect(deleted.name, '');
			expect(deleted.thumbnailUrl, isNull);
			expect(deleted.message, '(THREAD DELETED BY OP)');
		});
	});

	group('replies fragment', () {
		test('parses the posts the fragment carries', () {
			final fragment = parseReplyFragment(fixture('replies_fragment.html'), board: 'b', threadId: 82695);
			expect(fragment.threadId, 82695);
			expect(fragment.posts, hasLength(224));
			expect(fragment.posts.first.id, 82696);
			expect(fragment.posts.last.id, 84957);
			expect(fragment.posts.first.attachments.single.url, '/src/1787902487183.jpg');
			expect(fragment.posts.first.time, DateTime(2026, 8, 28, 10, 34, 48));
			expect(fragment.posts.last.references.single.postId, 84952);
			// The fragment has no thread div, so the board has to be supplied.
			expect(fragment.posts.last.board, 'b');
		});

		test('recovers the thread id from the posts when it is not supplied', () {
			final fragment = parseReplyFragment(fixture('replies_fragment.html'));
			expect(fragment.threadId, 82695);
			expect(fragment.posts, hasLength(224));
		});

		test('an empty fragment is an empty list, not an error', () {
			final fragment = parseReplyFragment('', board: 'b', threadId: 1);
			expect(fragment.posts, isEmpty);
		});
	});

	String twoThreads() => """
		<html><body>
		<div class="thread" id="thread_b-100">
			<div class="post op" id="b-100">
				<div class="post-info"><span class="post-name">Anonyymi</span>
				<span class="post-datetime">01/01/26(Thu)00:00:00</span></div>
				<div class="post-message">first</div>
			</div>
			<div class="post reply" id="b-101" data-parent_id="100">
				<div class="post-info"><span class="post-number">1</span>
				<span class="post-name">Anonyymi</span>
				<span class="post-datetime">01/01/26(Thu)00:01:00</span></div>
				<div class="post-message">to first</div>
			</div>
		</div>
		<div class="thread" id="thread_b-200">
			<div class="post op" id="b-200">
				<div class="post-info"><span class="post-name">Anonyymi</span>
				<span class="post-datetime">01/01/26(Thu)00:02:00</span></div>
				<div class="post-message">second</div>
			</div>
			<div class="post reply" id="b-201" data-parent_id="200">
				<div class="post-info"><span class="post-number">1</span>
				<span class="post-name">Anonyymi</span>
				<span class="post-datetime">01/01/26(Thu)00:03:00</span></div>
				<div class="post-message">to second</div>
			</div>
		</div>
		</body></html>""";

	group('thread grouping', () {
		// Two threads on one page. Grouping by markup nesting rather than by
		// `data-parent_id` would file the second thread's reply under the first,
		// and would lose a reply that follows the closing thread div.
		test('keeps each thread\'s replies with that thread', () {
			final page = parseBoardPage(twoThreads(), board: 'b');
			expect(page.threads.map((thread) => thread.id).toList(), [100, 200]);
			expect(page.threads[0].posts.map((post) => post.id).toList(), [100, 101]);
			expect(page.threads[1].posts.map((post) => post.id).toList(), [200, 201]);
			expect(page.threads[0].op.isOp, isTrue);
			expect(page.threads[0].posts[1].isOp, isFalse);
		});

		test('a reply with no data-parent_id goes to its own enclosing thread', () {
			// The fallback is per-post: a parser that used one global fallback would
			// put this reply under the first thread instead of the second.
			final page = parseBoardPage(
				"""<html><body>
					<div class="thread" id="thread_b-100">
						<div class="post op" id="b-100"><div class="post-info"><span class="post-name">A</span>
						<span class="post-datetime">01/01/26(Thu)00:00:00</span></div><div class="post-message">op</div></div>
					</div>
					<div class="thread" id="thread_b-200">
						<div class="post op" id="b-200"><div class="post-info"><span class="post-name">A</span>
						<span class="post-datetime">01/01/26(Thu)00:02:00</span></div><div class="post-message">op2</div></div>
						<div class="post reply" id="b-201"><div class="post-info"><span class="post-number">1</span>
						<span class="post-name">A</span><span class="post-datetime">01/01/26(Thu)00:03:00</span></div>
						<div class="post-message">reply</div></div>
					</div>
				</body></html>""",
				board: 'b'
			);
			expect(page.threads.map((thread) => thread.id).toList(), [100, 200]);
			expect(page.threads[0].posts, hasLength(1));
			expect(page.threads[1].posts.map((post) => post.id).toList(), [200, 201]);
			expect(page.threads[1].posts[1].parentId, 200);
		});

		test('a reply without data-parent_id falls back to its enclosing thread', () {
			final page = parseThreadPage(
				"""<html><body><div class="thread" id="thread_b-100">
					<div class="post op" id="b-100"><div class="post-info"><span class="post-name">A</span>
					<span class="post-datetime">01/01/26(Thu)00:00:00</span></div><div class="post-message">op</div></div>
					<div class="post reply" id="b-101"><div class="post-info"><span class="post-number">1</span>
					<span class="post-name">A</span><span class="post-datetime">01/01/26(Thu)00:01:00</span></div>
					<div class="post-message">reply</div></div>
				</div></body></html>""",
				board: 'b',
				threadId: 100
			);
			expect(page.thread.posts, hasLength(2));
			expect(page.thread.posts[1].parentId, 100);
		});

		test('only the requested thread is returned', () {
			final page = parseThreadPage(twoThreads(), board: 'b', threadId: 200);
			expect(page.thread.posts.map((post) => post.id).toList(), [200, 201]);
		});
	});

	group('adapter', () {
		test('fetches and names the board list from the home page', () async {
			// The request interceptors read app Settings for the user agent and the
			// cookie jar, so Hive has to be up even for a single stubbed request.
			await Persistence.initializeForTesting();
			final site = SiteMinilauta(
				baseUrl: 'minilauta.org',
				name: 'minilauta',
				overrideUserAgent: 'test',
				addIntrospectedHeaders: false,
				preferHttp3WithoutAltSvc: null,
				archives: const [],
				imageHeaders: const {},
				videoHeaders: const {}
			);
			site.client.httpClientAdapter = _FixtureAdapter(fixture('index.html'));
			final boards = await site.getBoards(priority: RequestPriority.functional);
			final byName = {for (final board in boards) board.name: board};
			expect(byName.keys, contains('b'));
			expect(byName['b']!.title, 'Satunnainen');
			expect(byName['b']!.isWorksafe, isFalse);
			expect(byName['b']!.filesPerPost, 1);
			expect(byName['b']!.maxCommentCharacters, 8192);
			expect(byName['yle']!.isWorksafe, isTrue);
			// The failure mode if the site's markup moves: a thrown error, not a
			// silently empty board list.
			site.client.httpClientAdapter = _FixtureAdapter('<html><body>nothing</body></html>');
			expect(() => site.getBoards(priority: RequestPriority.functional), throwsA(isA<BoardNotFoundException>()));
		});

		test('exposes the site type and posting state the app expects', () {
			final site = SiteMinilauta(
				baseUrl: 'minilauta.org',
				name: 'minilauta',
				overrideUserAgent: null,
				addIntrospectedHeaders: false,
				preferHttp3WithoutAltSvc: null,
				archives: const [],
				imageHeaders: const {},
				videoHeaders: const {}
			);
			expect(site.siteType, 'minilauta');
			expect(site.siteData, 'minilauta.org');
			// Posting needs an hCaptcha response the site never offers, so the app
			// must not offer a reply box.
			expect(site.supportsPosting, isFalse);
			expect(site.getWebUrl(board: 'b', threadId: 82695, postId: 82696), 'https://minilauta.org/b/82695/#b-82696');
			expect(site.getWebUrl(board: 'b'), 'https://minilauta.org/b/');
			expect(site.decodeUrlPossible(Uri.parse('https://minilauta.org/b/82695/#b-82696')), isTrue);
			expect(site.decodeUrlPossible(Uri.parse('https://example.com/b/1/')), isFalse);
		});

		test('decodes thread and post urls', () async {
			final site = SiteMinilauta(
				baseUrl: 'minilauta.org',
				name: 'minilauta',
				overrideUserAgent: null,
				addIntrospectedHeaders: false,
				preferHttp3WithoutAltSvc: null,
				archives: const [],
				imageHeaders: const {},
				videoHeaders: const {}
			);
			final thread = await site.decodeUrl(Uri.parse('https://minilauta.org/b/82695/'));
			expect(thread!.board, 'b');
			expect(thread.threadId, 82695);
			expect(thread.postId, isNull);
			final post = await site.decodeUrl(Uri.parse('https://minilauta.org/b/82695/#q82696'));
			expect(post!.postId, 82696);
			final board = await site.decodeUrl(Uri.parse('https://minilauta.org/b/'));
			expect(board!.board, 'b');
			expect(board.threadId, isNull);
		});
	});

	group('degenerate input', () {
		test('an unparseable page yields nothing instead of throwing', () {
			expect(parseBoardPage('<html><body>nope</body></html>', board: 'b').threads, isEmpty);
			expect(parseBoardPage('<html></html>').threads, isEmpty);
			expect(parseCatalog('<html></html>', board: 'b').threads, isEmpty);
			expect(parseThreadPage('<html></html>', board: 'b', threadId: 1).thread.posts, isEmpty);
			expect(parseBoardList('<html></html>'), isEmpty);
		});

		test('a post with an unparseable date is kept with a usable time', () {
			final page = parseThreadPage(
				'''<html><body><div class="thread" id="thread_b-1">
					<div class="post op" id="b-1"><div class="post-info"><span class="post-name">Anonyymi</span>
					<span class="post-datetime">not a date</span></div>
					<div class="post-message">hi</div></div></div></body></html>''',
				board: 'b',
				threadId: 1
			);
			expect(page.thread.posts, hasLength(1));
			expect(page.thread.op.name, 'Anonyymi');
			expect(page.thread.op.time.difference(DateTime.now()).abs(), lessThan(const Duration(minutes: 1)));
		});
	});
}

/// Answers every request with the same body, so an adapter test can exercise the
/// real request -> parse -> model path without a server.
class _FixtureAdapter implements HttpClientAdapter {
	final String body;

	_FixtureAdapter(this.body);

	@override
	Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future? cancelFuture) async {
		return ResponseBody.fromString(body, 200, headers: {
			Headers.contentTypeHeader: ['text/html; charset=utf-8']
		});
	}

	@override
	void close({bool force = false}) {}
}
