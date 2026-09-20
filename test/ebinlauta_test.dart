import 'dart:io';

import 'package:chan/models/attachment.dart';
import 'package:chan/models/post.dart';
import 'package:chan/sites/ebinlauta.dart';
import 'package:chan/sites/ebinlauta_parser.dart';
import 'package:chan/sites/imageboard_site.dart';
import 'package:chan/widgets/post_spans.dart';
import 'package:flutter_test/flutter_test.dart';

/// These tests run [EbinlautaParser] against pages captured from ebinlauta.net.
///
/// The site's markup has three traps that are easy to get wrong and impossible
/// to notice without real input: the same `omittedposts` class means "replies
/// are hidden" on a board card but "this message is truncated" inside a body,
/// `a.reply` anchors appear as body quotes, as backlinks and as cross-board
/// quotes with different attribute sets, and a reply puts its file block inside
/// `messagecontainer` while an OP puts it before `postinfo`.
String fixture(String name) => File('test/ebinlauta_fixtures/$name').readAsStringSync();

final _fetchedTime = DateTime(2026, 9, 21);

DateTime _local(int seconds) => DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true).toLocal();

/// Every span in a tree, outer before inner.
Iterable<PostSpan> walk(PostSpan span) sync* {
	yield span;
	if (span is PostNodeSpan) {
		for (final child in span.children) {
			yield* walk(child);
		}
	}
	else if (span is PostSpanWithChild) {
		yield* walk(span.child);
	}
}

void main() {
	group('boards', () {
		test('parses the board list with each board\'s own limits', () {
			final boards = EbinlautaParser.parseBoards(
				fixture('boards.json'),
				filesPerPost: 1,
				maxUploadSizeBytes: null
			);
			final byName = {for (final b in boards) b.name: b};
			expect(byName.keys, containsAll(['a', 'b', 'int', 'meta']));
			expect(byName['a']!.title, 'Japanijutut');
			expect(byName['b']!.title, 'Satunnainen');
			// The limits are per board in /boards.json, not one figure for the
			// site: /a/ and /int/ take four files, the rest one.
			expect(byName['a']!.filesPerPost, 4);
			expect(byName['b']!.filesPerPost, 1);
			expect(byName['int']!.filesPerPost, 4);
			expect(byName['b']!.maxImageSizeBytes, 40971520);
			expect(byName['b']!.maxWebmSizeBytes, 40971520);
			expect(byName['b']!.maxCommentCharacters, 8000);
			expect(byName['b']!.popularity, 42179);
		});

		test('falls back to the caller\'s limits for a board without settings', () {
			final boards = EbinlautaParser.parseBoards(
				'{"boards":[{"uri":"x","title":"X","totalPosts":3}]}',
				filesPerPost: 2,
				maxUploadSizeBytes: 1234
			);
			expect(boards, hasLength(1));
			expect(boards.single.name, 'x');
			expect(boards.single.title, 'X');
			expect(boards.single.popularity, 3);
			expect(boards.single.filesPerPost, 2);
			expect(boards.single.maxImageSizeBytes, 1234);
		});

		test('reports nothing rather than throwing on a reply that is not the board list', () {
			expect(EbinlautaParser.parseBoards('{}', filesPerPost: 1, maxUploadSizeBytes: null), isEmpty);
			expect(EbinlautaParser.parseBoards('<html>', filesPerPost: 1, maxUploadSizeBytes: null), isEmpty);
		});
	});

	group('board page', () {
		test('parses the cards and the pager', () {
			final page = EbinlautaParser.parseBoardPage(
				fixture('board_page.html'),
				board: 'b',
				defaultUsername: 'Anonyymi',
				fetchedTime: _fetchedTime
			);
			// The page number is only in the pager, and 15 is the last page the
			// pager links to.
			expect(page.page, 0);
			expect(page.lastPage, 15);
			expect(page.threads.map((t) => t.id), containsAll([41806, 33736]));
		});

		test('counts a card\'s hidden replies instead of pretending they are not there', () {
			final page = EbinlautaParser.parseBoardPage(
				fixture('board_page.html'),
				board: 'b',
				defaultUsername: 'Anonyymi',
				fetchedTime: _fetchedTime
			);
			final thread = page.threads.firstWhere((t) => t.id == 41806);
			// The card renders the OP and the last three replies.
			expect(thread.posts_.map((p) => p.id), [41806, 42172, 42178, 42179]);
			// ... and says seven more were left out.
			expect(thread.replyCount, 10);
			expect(thread.posts_.first.hasOmittedReplies, isTrue);
			// The notice is thread chrome, not part of the body.
			expect(thread.posts_.first.text, isNot(contains('posts omitted')));
			// Every post on the card knows which thread it belongs to.
			expect(thread.posts_.every((p) => p.threadId == 41806), isTrue);
			final other = page.threads.firstWhere((t) => t.id == 33736);
			expect(other.replyCount, 216);
			expect(other.posts_.every((p) => p.threadId == 33736), isTrue);
		});

		test('does not mistake catalog cards for board cards', () {
			// `div.thread` matches `div.catalog-post.thread` too, and those cards
			// have no posts at all.
			final page = EbinlautaParser.parseBoardPage(
				fixture('catalog.html'),
				board: 'b',
				defaultUsername: 'Anonyymi',
				fetchedTime: _fetchedTime
			);
			expect(page.threads, isEmpty);
			expect(page.page, 0);
		});
	});

	group('thread', () {
		test('parses every post, its id, name and timestamp', () {
			final page = EbinlautaParser.parseThread(
				fixture('thread.html'),
				board: 'b',
				threadId: 33736,
				defaultUsername: 'Anonyymi',
				fetchedTime: _fetchedTime
			);
			final thread = page.thread;
			expect(thread.id, 33736);
			expect(thread.board, 'b');
			// From the page header, not from the posts: the fixture keeps a
			// sample of a thread that had 216 replies.
			expect(thread.replyCount, 216);
			// `window.threadData.archived` is false on this thread.
			expect(thread.isArchived, isFalse);
			expect(thread.posts_.map((p) => p.id), [
				33736, 33741, 33742, 33744, 33745, 33746, 33751, 33752, 33753,
				33755, 33757, 33758, 33759, 33763, 34032, 35415
			]);
			final op = thread.posts_.first;
			expect(op.id, 33736);
			expect(op.threadId, 33736);
			expect(op.name, 'Anonyymi');
			expect(op.time, _local(1787596482));
			expect(op.spanFormat, PostSpanFormat.ebinlauta);
			expect(op.text, contains('Osa 2'));
			final reply = thread.posts_.firstWhere((p) => p.id == 33741);
			expect(reply.threadId, 33736);
			expect(reply.time, _local(1787597639));
			expect(reply.time.isUtc, isFalse);
			expect(reply.text, contains('oisin varmaan'));
		});

		test('reads the thread named by the id, not just the first card on the page', () {
			// A page that also lists another thread - a sidebar, a related
			// threads block - must not have that thread's posts read as this one.
			const decoy = '<div class="thread" id="thread_1" board="b"><div class="op" id="1">'
				'<div class="postinfo"><span class="postername"><span class="name">N</span></span>'
				'<span class="timestamp" data-timestamp="1">x</span></div>'
				'<span class="messagecontainer"><blockquote class="content">decoy</blockquote></span></div></div>';
			final page = EbinlautaParser.parseThread(
				'<html><body>$decoy${fixture('thread.html')}</body></html>',
				board: 'b',
				threadId: 33736,
				defaultUsername: 'Anonyymi',
				fetchedTime: _fetchedTime
			);
			expect(page.thread.posts_.first.id, 33736);
			expect(page.thread.posts_.map((p) => p.text).join(), isNot(contains('decoy')));
		});

		test('keeps body quotes and backlinks apart', () {
			final page = EbinlautaParser.parseThread(
				fixture('thread.html'),
				board: 'b',
				threadId: 33736,
				defaultUsername: 'Anonyymi',
				fetchedTime: _fetchedTime
			);
			// 33741's body quotes nobody; its >>33742 >>33744 are its backlinks,
			// rendered twice (in postinfo and after the body) and both times as
			// a.reply, so they are the anchors most easily mistaken for quotes.
			final reply = page.thread.posts_.firstWhere((p) => p.id == 33741);
			expect(reply.text, isNot(contains('33742')));
			expect(page.backlinks[33741], containsAll([33742, 33744]));
			expect(page.backlinks[33742], containsAll([33744, 33745]));
			// A body quote is in the text and resolves to a reference.
			final quoting = page.thread.posts_.firstWhere((p) => p.id == 33742);
			expect(quoting.text, contains('data-post-id="33741"'));
			expect(quoting.repliedToIds, contains(33741));
			expect(reply.repliedToIds, isEmpty);
		});

		test('parses attachments with source, thumbnail, dimensions and size', () {
			final page = EbinlautaParser.parseThread(
				fixture('thread.html'),
				board: 'b',
				threadId: 33736,
				defaultUsername: 'Anonyymi',
				fetchedTime: _fetchedTime
			);
			final opFile = page.thread.posts_.first.attachments.single;
			expect(opFile.type, AttachmentType.image);
			expect(opFile.id, '/static/src/17875964828422431.png');
			expect(opFile.url, 'https://ebinlauta.net/static/src/17875964828422431.png');
			expect(opFile.thumbnailUrl, 'https://ebinlauta.net/static/thumb/17875964828422431.png');
			expect(opFile.filename, 'HPOXxKEXwAAJK0_.png');
			expect(opFile.ext, '.png');
			expect(opFile.threadId, 33736);
			expect(opFile.width, 679);
			expect(opFile.height, 382);
			expect(opFile.sizeInBytes, 402596);
			// A reply carries its file inside messagecontainer, so it is not part
			// of the body text either.
			final video = page.thread.posts_.firstWhere((p) => p.id == 34032);
			expect(video.attachments, hasLength(1));
			expect(video.attachments.single.type, AttachmentType.mp4);
			expect(video.attachments.single.ext, '.mp4');
			expect(video.attachments.single.width, 576);
			expect(video.attachments.single.height, 1024);
			expect(video.attachments.single.sizeInBytes, 2474639);
			expect(video.attachments.single.thumbnailUrl, endsWith('.png'));
			expect(video.text, isNot(contains('post-files')));
		});

		test('reports an embed as a link with a thumbnail and no size', () {
			final page = EbinlautaParser.parseThread(
				fixture('thread.html'),
				board: 'b',
				threadId: 33736,
				defaultUsername: 'Anonyymi',
				fetchedTime: _fetchedTime
			);
			final embed = page.thread.posts_.firstWhere((p) => p.id == 35415).attachments.single;
			// The file is somebody else's site; only the poster frame is local.
			expect(embed.type, AttachmentType.url);
			expect(embed.url, 'https://www.youtube.com/watch?v=JRB24HUAKKs');
			expect(embed.thumbnailUrl, startsWith('https://ebinlauta.net/static/thumb/'));
			expect(embed.ext, '.youtube');
			expect(embed.filename, contains('Airplane'));
			// The page states no dimensions or size for an embed.
			expect(embed.width, isNull);
			expect(embed.height, isNull);
			expect(embed.sizeInBytes, isNull);
		});
	});

	group('catalog', () {
		test('parses the cards with ids, timestamps and reply counts', () {
			final catalog = EbinlautaParser.parseCatalog(
				fixture('catalog.html'),
				board: 'b',
				defaultUsername: 'Anonyymi',
				fetchedTime: _fetchedTime
			);
			expect(catalog.threads.keys, containsAll([41806, 33736, 42158, 42117]));
			final thread = catalog.threads[41806]!;
			expect(thread.board, 'b');
			// A catalog card shows only the opening post.
			expect(thread.posts_, hasLength(1));
			expect(thread.replyCount, 10);
			final op = thread.posts_.single;
			expect(op.id, 41806);
			expect(op.threadId, 41806);
			expect(op.name, 'Anonyymi');
			expect(op.time, _local(1789761644));
			expect(op.text, 'SAATANA');
			expect(catalog.threads[42117]!.replyCount, 4);
			expect(catalog.threads[42117]!.time, _local(1789910342));
		});

		test('uses the card\'s thumbnail, and says nothing it does not know', () {
			final catalog = EbinlautaParser.parseCatalog(
				fixture('catalog.html'),
				board: 'b',
				defaultUsername: 'Anonyymi',
				fetchedTime: _fetchedTime
			);
			final file = catalog.threads[33736]!.posts_.single.attachments.single;
			// A card carries only the scaled preview: no original URL, no size,
			// no dimensions. Those stay null rather than becoming zeros.
			expect(file.url, startsWith('https://ebinlauta.net/static/thumb/'));
			expect(file.thumbnailUrl, file.url);
			expect(file.sizeInBytes, isNull);
			expect(file.width, isNull);
			expect(file.height, isNull);
			expect(file.spoiler, isFalse);
		});

		test('drops the truncation notice but flags it', () {
			final catalog = EbinlautaParser.parseCatalog(
				fixture('catalog.html'),
				board: 'b',
				defaultUsername: 'Anonyymi',
				fetchedTime: _fetchedTime
			);
			final op = catalog.threads[42158]!.posts_.single;
			expect(op.text, contains('datakeskus koulu'));
			expect(op.text, isNot(contains('Message too long')));
			expect(op.hasOmittedReplies, isTrue);
			// A card whose message fits is not flagged.
			expect(catalog.threads[41806]!.posts_.single.hasOmittedReplies, isFalse);
		});
	});

	group('fragments', () {
		test('parses the single post /api/post/get answers with', () {
			final posts = EbinlautaParser.parsePostsFragment(
				fixture('post_fragment.html'),
				board: 'b',
				threadId: 33736,
				defaultUsername: 'Anonyymi',
				fetchedTime: _fetchedTime
			);
			expect(posts, hasLength(1));
			final post = posts.single;
			expect(post.id, 33741);
			expect(post.threadId, 33736);
			expect(post.name, 'Anonyymi');
			expect(post.time, _local(1787597639));
			expect(post.text, contains('oisin varmaan'));
			// The wrapper this endpoint adds (div.postcontainer) is not a post.
			expect(post.text, isNot(contains('sidearrows')));
		});

		test('parses the posts /api/thread/new-posts/ wraps in JSON', () {
			final posts = EbinlautaParser.parseNewPostsResponse(
				fixture('new_posts.json'),
				board: 'b',
				defaultUsername: 'Anonyymi',
				fetchedTime: _fetchedTime
			);
			expect(posts.map((p) => p.id), [42023, 42177]);
			// The thread comes from the envelope, not from each post.
			expect(posts.every((p) => p.threadId == 33736), isTrue);
			expect(posts.every((p) => p.name == 'Anonyymi'), isTrue);
		});

		test('reports nothing rather than throwing on an unexpected body', () {
			expect(EbinlautaParser.parsePostsFragment('', board: 'b', threadId: 1, defaultUsername: 'A', fetchedTime: _fetchedTime), isEmpty);
			expect(EbinlautaParser.parseNewPostsResponse('<html>', board: 'b', defaultUsername: 'A', fetchedTime: _fetchedTime), isEmpty);
			expect(EbinlautaParser.parseNewPostsResponse('{"success":false}', board: 'b', defaultUsername: 'A', fetchedTime: _fetchedTime), isEmpty);
		});

		test('says a thread page with no posts is missing instead of empty', () {
			expect(
				() => EbinlautaParser.parseThread('<html><body></body></html>', board: 'b', threadId: 1, defaultUsername: 'A', fetchedTime: _fetchedTime),
				throwsA(isA<ThreadNotFoundException>())
			);
		});
	});

	group('post body spans', () {
		// The engine's formatter (Html::postMessage) is the only source for what
		// a body can contain, so these are its own replacements, not guesses.
		const html = 'plain<br />'
			'<span class="green-text">&gt;green</span>'
			'<span class="blue-text">&lt;blue</span>'
			'<span class="purple-text">~purple</span>'
			'<b>bold</b><i>italic</i><u>under</u><s>struck</s>'
			'<big>big</big><small>small</small>'
			'<span class="spoiler-text">hidden</span>'
			'<pre class="code"><code>var x = 1;</code></pre>'
			'<span style="color:red">red</span>'
			'<a href="https://example.com/">link</a>'
			'<a class="reply" data-post-id="5" data-board="b" data-thread="7" href="/b/7#5">&gt;&gt;5</a>'
			'<a class="reply dead" data-post-id="9" data-board="b">&gt;&gt;9</a>'
			'<a class="reply" data-post-id="11" data-board="other" data-thread="12" href="/other/12#11">&gt;&gt;&gt;/other/11</a>';

		test('renders every formatting tag the engine emits', () {
			final spans = walk(SiteEbinlauta.makeSpan('b', 33736, html)).toList();
			expect(spans, contains(isA<PostLineBreakSpan>()));
			expect(spans, contains(isA<PostQuoteSpan>()));
			expect(spans, contains(isA<PostBlueQuoteSpan>()));
			expect(spans, contains(isA<PostPinkQuoteSpan>()));
			expect(spans, contains(isA<PostBoldSpan>()));
			expect(spans, contains(isA<PostItalicSpan>()));
			expect(spans, contains(isA<PostUnderlinedSpan>()));
			expect(spans, contains(isA<PostStrikethroughSpan>()));
			expect(spans, contains(isA<PostBigTextSpan>()));
			expect(spans, contains(isA<PostSmallTextSpan>()));
			expect(spans, contains(isA<PostSpoilerSpan>()));
			expect(spans, contains(isA<PostCssSpan>()));
			expect(spans, contains(isA<PostLinkSpan>()));
			final code = spans.whereType<PostCodeSpan>().single;
			expect(code.text.trim(), 'var x = 1;');
		});

		test('turns reply anchors into quote links, including ones that resolve nowhere', () {
			final spans = walk(SiteEbinlauta.makeSpan('b', 33736, html)).toList();
			final links = spans.whereType<PostQuoteLinkSpan>().toList();
			expect(links, hasLength(3));
			// Same-thread quote.
			expect(links[0].board, 'b');
			expect(links[0].threadId, 7);
			expect(links[0].postId, 5);
			// A "dead" reply has no data-thread at all: it still points at the
			// thread being read.
			expect(links[1].board, 'b');
			expect(links[1].threadId, 33736);
			expect(links[1].postId, 9);
			// Cross-board quote names its own board and thread.
			expect(links[2].board, 'other');
			expect(links[2].threadId, 12);
			expect(links[2].postId, 11);
		});

		test('shows no raw HTML for markup it does not know', () {
			final text = StringBuffer();
			SiteEbinlauta.makeSpan('b', 33736, 'before<marquee><b>inside</b></marquee>after')
				.buildText(text, _postForText(), forQuoteComparison: false);
			expect(text.toString(), contains('inside'));
			expect(text.toString(), isNot(contains('marquee')));
			expect(text.toString(), isNot(contains('<b>')));
		});
	});
}

Post _postForText() => Post(
	board: 'b',
	text: '',
	name: 'Anonyymi',
	time: _fetchedTime,
	threadId: 33736,
	id: 33736,
	spanFormat: PostSpanFormat.ebinlauta,
	attachments_: const []
);
