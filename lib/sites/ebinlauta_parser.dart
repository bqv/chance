import 'dart:collection';
import 'dart:convert';

import 'package:chan/models/attachment.dart';
import 'package:chan/models/board.dart';
import 'package:chan/models/post.dart';
import 'package:chan/models/thread.dart';
import 'package:chan/sites/imageboard_site.dart';
import 'package:chan/util.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart';

/// A board page: the threads it shows, and the pager under them.
///
/// The page number is not in the posts, only in the address that was fetched
/// and in `table.pagelink`, so it is read from the pager.
typedef EbinlautaBoardPage = ({List<Thread> threads, int page, int lastPage});

/// A thread page: the thread, plus the reply relationships the page states in
/// its own backlink lists.
///
/// The link lists are what the site itself considers "who replied to this
/// post". Chance normally derives that from the quote links in post bodies,
/// which is the same set as long as every quoting post is on the page - a
/// board-page card, however, shows only the last three replies, so what it
/// omits is only knowable from the omission notice and from these lists.
typedef EbinlautaThreadPage = ({Thread thread, Map<int, List<int>> backlinks});

/// Parses ebinlauta.net's server-rendered HTML (the site's own "ebinboard"
/// engine, v0.5.7).
///
/// Kept separate from the site adapter so the DOM rules can be exercised
/// against captured pages without a site instance (and therefore without an
/// HTTP client). Everything here is pure: the only input is a string.
///
/// The site has no usable JSON for pages one at a time reads - `/<board>/<id>`
/// answers with HTML whatever extension is asked for - so the markup is the API.
/// Four shapes matter and they are *not* interchangeable:
///
///  * **Board page** (`/<board>/`, `/<board>-<n>/`) - one `div.thread` per
///    thread, each holding the OP and only the last three replies, with the
///    number of the ones it skipped in a `div.omittedposts` that is a *direct
///    child of the card*. That class is also used for a truncated post body
///    ("Message too long..."), which lives inside the message instead, so the
///    two are told apart by where they sit.
///  * **Catalog** (`/<board>/catalog`) - one `div.catalog-post.thread` per
///    thread, addressed by its own `id` attribute rather than by a
///    `thread_<id>` wrapper, and showing only a thumbnail, a bare reply count
///    (`R:10`) and a possibly truncated body. No pager: the site's 160-thread
///    board limit is the whole catalog.
///  * **Thread** (`/<board>/<id>`) - one `div.thread` holding every post,
///    addressed as `div.op#<id>` for the opening post and `div.post.reply#<id>`
///    for the rest. The post's numeric id is the element's own `id`; a
///    `a.postid[data-id]` in the same post repeats it.
///  * **Post fragment** (`/api/post/get?board=&post_id=`) - one post, either
///    bare (`div.op`) or wrapped in a `div.postcontainer`, with no `div.thread`
///    around it. The site's own thread auto-update (`/api/thread/new-posts/`)
///    wraps this same markup in a JSON envelope, which is why
///    [parseNewPostsResponse] exists.
///
/// The engine's formatter (`Html::postMessage`) is the reference for what a
/// body can contain: `<b>`, `<i>`, `<s>`, `<u>`, `<big>`, `<small>`,
/// `<span class="spoiler-text">`, `<pre class="code">`, `<span style=...>`
/// colour spans, `a.reply` quote links, `span.green-text`/`blue-text`/
/// `purple-text`, plain `<a>` links and `<br>`. The span rules live in
/// `SiteEbinlauta.makeSpan`; this file only decides which parts of the page
/// become a post's `text`.
class EbinlautaParser {
	const EbinlautaParser._();

	static const threadSelector = 'div.thread';
	/// The opening post of a thread, on either a thread page or a board card.
	static const opSelector = 'div.op';
	/// A reply. Only ever a descendant of a [threadSelector].
	static const replySelector = 'div.post.reply';
	/// Both kinds of post, in document order.
	static const postSelector = '$opSelector, $replySelector';
	static const catalogCardSelector = 'div.catalog-post.thread';

	/// The host every relative file path on the site is served from.
	static const _host = 'https://ebinlauta.net';

	static final _omittedRepliesPattern = RegExp(r'(\d+)\s+posts? omitted');
	static final _replyCountPattern = RegExp(r'(\d+)\s+Repl');
	static final _dimensionsPattern = RegExp(r'(\d+)\s*x\s*(\d+)');
	static final _fileSizePattern = RegExp(r'(\d+(?:\.\d+)?)\s*(KB|MB|GB|B)');
	static final _catalogReplyCountPattern = RegExp(r'R:\s*(\d+)');
	static final _threadIdAttributePattern = RegExp(r'^thread_(\d+)$');
	static final _archivedPattern = RegExp(r'archived\s*:\s*(true|false)');

	/// The board list, from `/boards.json` (JSON despite the name).
	///
	/// The file carries each board's own limits, so those are used per board
	/// instead of one figure for the whole site: `max_files` is how many files
	/// a post may carry and `file_size` the upload limit in bytes. Both are
	/// missing on nothing today, but a board added without them falls back to
	/// the caller's values rather than to zero.
	static List<ImageboardBoard> parseBoards(String json, {
		required int filesPerPost,
		required int? maxUploadSizeBytes
	}) {
		final data = _decodeJson(json);
		if (data is! Map) {
			return const [];
		}
		final boards = data['boards'];
		if (boards is! List) {
			return const [];
		}
		return boards.cast<Map>().map((board) {
			final settings = (board['settings'] as Map?) ?? const {};
			final name = board['uri'] as String?;
			if (name == null || name.isEmpty) {
				return null;
			}
			final fileSize = settings['file_size'] as int? ?? maxUploadSizeBytes;
			return ImageboardBoard(
				name: name,
				title: board['title'] as String? ?? name,
				// The site marks no board as worksafe or not; every board carries
				// the same content warning.
				isWorksafe: false,
				webmAudioAllowed: true,
				filesPerPost: settings['max_files'] as int? ?? filesPerPost,
				maxImageSizeBytes: fileSize,
				maxWebmSizeBytes: fileSize,
				maxCommentCharacters: settings['max_message'] as int?,
				popularity: board['totalPosts'] as int?
			);
		}).nonNulls.toList(growable: false);
	}

	/// One page of a board listing, with the pager it carries.
	///
	/// `div.thread` also matches a catalog card (`div.catalog-post.thread`),
	/// which has no posts at all: such a card parses to nothing and is dropped,
	/// so running this over a catalog yields an empty list rather than junk.
	static EbinlautaBoardPage parseBoardPage(String html, {
		required String board,
		required String defaultUsername,
		required DateTime fetchedTime
	}) {
		final document = parse(html);
		final threads = document.querySelectorAll(threadSelector)
			.map((card) => parseBoardCard(card, board: board, defaultUsername: defaultUsername, fetchedTime: fetchedTime))
			.nonNulls
			.toList(growable: false);
		final pager = document.querySelector('table.pagelink');
		final page = pager?.querySelector('span.activepage')?.text.tryParseInt ?? 0;
		var lastPage = page;
		for (final link in pager?.querySelectorAll('a') ?? const <dom.Element>[]) {
			final linked = _pageOfHref(link.attributes['href']);
			if (linked != null && linked > lastPage) {
				lastPage = linked;
			}
		}
		return (threads: threads, page: page, lastPage: lastPage);
	}

	/// One thread card of a board page.
	///
	/// The card shows the OP and only the last few replies; the ones left out
	/// are counted in the card's own `div.omittedposts`, which is the only
	/// statement of the thread's true reply count on this page.
	static Thread? parseBoardCard(dom.Element card, {
		required String board,
		required String defaultUsername,
		required DateTime fetchedTime
	}) {
		// The card's own id hands out the thread id; the OP alone can too, but
		// not the replies, which have to be told which thread they belong to
		// before they are parsed.
		final threadId = _threadIdOf(card) ?? card.querySelector(opSelector)?.attributes['id']?.tryParseInt;
		if (threadId == null) {
			return null;
		}
		final posts = card.querySelectorAll(postSelector)
			.map((element) => parsePost(element, board: board, threadId: threadId, defaultUsername: defaultUsername, fetchedTime: fetchedTime))
			.nonNulls
			.toList(growable: false);
		if (posts.isEmpty) {
			return null;
		}
		final op = posts.first;
		final omitted = omittedReplyCount(card);
		op.hasOmittedReplies = op.hasOmittedReplies || omitted > 0;
		return Thread(
			posts_: posts,
			replyCount: (posts.length - 1) + omitted,
			imageCount: posts.fold(0, (count, post) => count + post.attachments_.length),
			id: threadId,
			board: board,
			// ebinboard has no subject of its own: a thread is named by its OP.
			title: null,
			// Stickies are not marked in any capture, so assuming false means a
			// sticky is merely ordered like any other thread.
			isSticky: false,
			time: op.time,
			attachments: op.attachments_
		);
	}

	/// Every thread on a catalog page.
	///
	/// The catalog is one page - the site caps a board at 160 threads - so there
	/// is no pager to read.
	static Catalog parseCatalog(String html, {
		required String board,
		required String defaultUsername,
		required DateTime fetchedTime
	}) {
		final document = parse(html);
		final threads = <int, Thread>{};
		for (final card in document.querySelectorAll(catalogCardSelector)) {
			final thread = parseCatalogCard(card, board: board, defaultUsername: defaultUsername, fetchedTime: fetchedTime);
			if (thread != null) {
				threads[thread.id] = thread;
			}
		}
		return Catalog(
			threads: LinkedHashMap.from(threads),
			lastModified: null,
			fetchedTime: fetchedTime
		);
	}

	/// One catalog card.
	static Thread? parseCatalogCard(dom.Element card, {
		required String board,
		required String defaultUsername,
		required DateTime fetchedTime
	}) {
		final id = card.attributes['id']?.tryParseInt;
		if (id == null) {
			return null;
		}
		final stats = card.querySelector('.catalog-stats');
		final time = parseTimestamp(stats?.querySelector('span.timestamp')?.attributes['data-timestamp']) ?? fetchedTime;
		final message = card.querySelector('.catalog-message');
		final thumbnail = catalogThumbnail(card, board: board, threadId: id);
		final attachments = thumbnail == null ? const <Attachment>[] : [thumbnail];
		final op = Post(
			board: board,
			text: _messageHtml(message),
			name: card.querySelector('.catalog-info .postername .name')?.text.trim().nonEmptyOrNull ?? defaultUsername,
			time: time,
			threadId: id,
			id: id,
			spanFormat: PostSpanFormat.ebinlauta,
			attachments_: attachments,
			hasOmittedReplies: message?.querySelector('.omittedposts') != null
		);
		return Thread(
			posts_: [op],
			replyCount: _catalogReplyCountPattern.firstMatch(stats?.text ?? '')?.group(1)?.tryParseInt ?? 0,
			imageCount: attachments.length,
			id: id,
			board: board,
			title: null,
			isSticky: false,
			time: time,
			attachments: attachments
		);
	}

	/// The whole thread page at `/<board>/<id>`.
	///
	/// The site serves the entire thread on that one URL: offset paging
	/// (`/<board>/<id>/<offset>`) exists in its route table, but no captured
	/// page links to it and a 216-reply thread is not split, so nothing here
	/// needs it.
	static EbinlautaThreadPage parseThread(String html, {
		required String board,
		required int threadId,
		required String defaultUsername,
		required DateTime fetchedTime
	}) {
		final document = parse(html);
		// The thread this page is about, rather than simply the first one: a
		// page that also lists other threads must not have their posts read as
		// this thread's.
		dom.Element? card = document.querySelector('$threadSelector#thread_$threadId');
		card ??= document.querySelector(threadSelector);
		// A fragment-shaped page has no div.thread; fall back to the document so
		// a caller that hands one to parseThread still gets its posts.
		final root = card ?? document.body;
		final elements = root?.querySelectorAll(postSelector).toList(growable: false) ?? const <dom.Element>[];
		final posts = elements
			.map((element) => parsePost(element, board: board, threadId: threadId, defaultUsername: defaultUsername, fetchedTime: fetchedTime))
			.nonNulls
			.toList(growable: false);
		if (posts.isEmpty) {
			throw const ThreadNotFoundException();
		}
		final op = posts.firstWhere((p) => p.id == threadId, orElse: () => posts.first);
		// Read the backlinks off the elements, since the anchors they are made
		// of are not part of the parsed post.
		final backlinks = <int, List<int>>{};
		for (final element in elements) {
			final id = element.attributes['id']?.tryParseInt;
			if (id == null) {
				continue;
			}
			final ids = backlinkIds(element);
			if (ids.isNotEmpty) {
				backlinks[id] = ids;
			}
		}
		return (
			thread: Thread(
				posts_: posts,
				replyCount: _replyCountPattern.firstMatch(replyCountText(document) ?? '')?.group(1)?.tryParseInt ?? posts.length - 1,
				imageCount: posts.fold(0, (count, post) => count + post.attachments_.length),
				id: threadId,
				board: board,
				title: null,
				isSticky: false,
				time: op.time,
				attachments: op.attachments_,
				// `window.threadData.archived` is the site's own statement.
				isArchived: threadArchived(document) ?? false
			),
			backlinks: backlinks
		);
	}

	/// The posts in a page fragment, in document order.
	///
	/// Handles both fragment shapes the site produces: `/api/post/get`, which
	/// wraps one post in a `div.postcontainer` (or answers with a bare `div.op`
	/// for an OP), and the `html` field of `/api/thread/new-posts/`, which is a
	/// run of `div.postcontainer`s.
	static List<Post> parsePostsFragment(String html, {
		required String board,
		required int threadId,
		required String defaultUsername,
		required DateTime fetchedTime
	}) {
		return parse(html).querySelectorAll(postSelector)
			.map((element) => parsePost(element, board: board, threadId: threadId, defaultUsername: defaultUsername, fetchedTime: fetchedTime))
			.nonNulls
			.toList(growable: false);
	}

	/// The new posts in the reply of `/api/thread/new-posts/`.
	///
	/// That endpoint, and not `/api/post/get`, is what `threadAutoUpdate` polls:
	/// it answers `{"success":true,"thread_id":N,"html":"<div class=...>"}`, so
	/// the posts are one JSON string away from the page markup.
	static List<Post> parseNewPostsResponse(String json, {
		required String board,
		required String defaultUsername,
		required DateTime fetchedTime
	}) {
		final data = _decodeJson(json);
		if (data is! Map) {
			return const [];
		}
		final html = data['html'];
		final threadId = data['thread_id'] as int?;
		if (html is! String || threadId == null) {
			return const [];
		}
		return parsePostsFragment(html, board: board, threadId: threadId, defaultUsername: defaultUsername, fetchedTime: fetchedTime);
	}

	/// One post, from a `div.op` or a `div.post.reply`.
	///
	/// The body is kept as HTML because its `spanFormat` tells the app how to
	/// turn it into spans; only markup that would be read as part of the message
	/// but is not (the truncation notice) is removed first.
	static Post? parsePost(dom.Element element, {
		required String board,
		required int threadId,
		required String defaultUsername,
		required DateTime fetchedTime
	}) {
		final id = element.attributes['id']?.tryParseInt;
		if (id == null) {
			return null;
		}
		final content = element.querySelector('.messagecontainer .content');
		return Post(
			board: board,
			text: _messageHtml(content),
			name: element.querySelector('.postername .name')?.text.trim().nonEmptyOrNull ?? defaultUsername,
			time: parseTimestamp(element.querySelector('span.timestamp')?.attributes['data-timestamp']) ?? fetchedTime,
			threadId: threadId,
			id: id,
			spanFormat: PostSpanFormat.ebinlauta,
			attachments_: parseAttachments(element, board: board, threadId: threadId),
			// A listing truncates a long body; the notice that says so is not
			// part of the text, but the fact that text is missing is worth
			// keeping.
			hasOmittedReplies: content?.querySelector('.omittedposts') != null
		);
	}

	/// Every file on a post, in the order the page shows them.
	static List<Attachment> parseAttachments(dom.Element post, {
		required String board,
		required int threadId
	}) {
		return post.querySelectorAll('.post-files .file-slide')
			.map((slide) => parseAttachment(slide, board: board, threadId: threadId))
			.nonNulls
			.toList(growable: false);
	}

	/// One `div.file-slide`.
	///
	/// A file's real address is the `.filelink` anchor (or `data-full` on the
	/// expander, which is the same URL), never the `img.thumb`, which is a
	/// scaled copy. The page states dimensions and a byte size only in the
	/// `fileinfo` text, and does not state them at all for an embed, whose
	/// `data-full` is somebody else's site - so both stay null there rather than
	/// becoming a zero-sized file.
	static Attachment? parseAttachment(dom.Element slide, {
		required String board,
		required int threadId
	}) {
		final link = slide.querySelector('.filelink a');
		final expand = slide.querySelector('a.file-expand');
		final source = link?.attributes['href'] ?? expand?.attributes['data-full'];
		if (source == null || source.isEmpty) {
			return null;
		}
		final kind = expand?.attributes['data-type'];
		final url = _absolute(source);
		final thumb = slide.querySelector('img.thumb')?.attributes['src'] ?? expand?.attributes['data-thumb'];
		final info = slide.querySelector('.fileinfo')?.text ?? '';
		final dimensions = _dimensionsPattern.firstMatch(info);
		final size = _fileSizePattern.firstMatch(info);
		return Attachment(
			type: _attachmentType(kind, source),
			board: board,
			id: source,
			ext: _extensionOf(source, fallback: expand?.attributes['data-embed']),
			filename: link?.attributes['title']?.trim().nonEmptyOrNull ?? source.afterLast('/'),
			url: url,
			// Every captured file has a thumbnail; the file itself is a sane
			// stand-in if one ever does not.
			thumbnailUrl: thumb == null ? url : _absolute(thumb),
			md5: '',
			// The site renders no spoiler state for files at all.
			spoiler: false,
			width: dimensions?.group(1)?.tryParseInt,
			height: dimensions?.group(2)?.tryParseInt,
			threadId: threadId,
			sizeInBytes: size == null ? null : _bytes(size.group(1)!, size.group(2)!)
		);
	}

	/// The thumbnail a catalog card shows for a thread.
	///
	/// A catalog card carries nothing but the scaled preview - no original URL,
	/// no size and no dimensions - so the preview stands in for the file until
	/// the thread itself is fetched. The card's `id` is the thread's, as the
	/// card is not a post.
	static Attachment? catalogThumbnail(dom.Element card, {
		required String board,
		required int threadId
	}) {
		final image = card.querySelector('a.catalog-thumb img');
		final source = image?.attributes['src'];
		if (source == null || source.isEmpty) {
			return null;
		}
		final url = _absolute(source);
		return Attachment(
			type: AttachmentType.fromFilename(source),
			board: board,
			id: source,
			ext: _extensionOf(source, fallback: null),
			filename: image?.attributes['alt']?.trim().nonEmptyOrNull ?? source.afterLast('/'),
			url: url,
			thumbnailUrl: url,
			md5: '',
			spoiler: false,
			width: null,
			height: null,
			threadId: threadId,
			sizeInBytes: null
		);
	}

	/// The post ids a post's own backlink lists name.
	///
	/// The site renders the same list twice: as `small.backlinks` in the info
	/// row and as `div.backlinks` after the body, both with `a.reply`. Only
	/// those two containers are read; the body's quote links look identical and
	/// say the opposite thing (who this post replies to).
	static List<int> backlinkIds(dom.Element post) {
		final ids = <int>{};
		for (final anchor in post.querySelectorAll('.backlinks a.reply')) {
			final id = anchor.attributes['data-post-id']?.tryParseInt;
			if (id != null) {
				ids.add(id);
			}
		}
		return ids.toList(growable: false);
	}

	/// How many replies a board card says it left out.
	static int omittedReplyCount(dom.Element card) {
		// Only the card's own notice counts: the same class is also used for a
		// truncated message, and that one sits inside the post's body.
		for (final child in card.children) {
			if (child.localName == 'div' && child.classes.contains('omittedposts')) {
				return _omittedRepliesPattern.firstMatch(child.text)?.group(1)?.tryParseInt ?? 0;
			}
		}
		return 0;
	}

	/// The `N Replies` figure from the page's top navigation, as raw text.
	static String? replyCountText(dom.Document document) => document.querySelector('.top-nav .right.classic')?.text;

	/// Whether `window.threadData` says this thread is archived, if it says.
	static bool? threadArchived(dom.Document document) {
		final script = document.querySelectorAll('script').map((s) => s.text).firstWhere((t) => t.contains('window.threadData'), orElse: () => '');
		final match = _archivedPattern.firstMatch(script);
		return match == null ? null : match.group(1) == 'true';
	}

	/// A `data-timestamp` (epoch seconds) as local time.
	static DateTime? parseTimestamp(String? timestamp) {
		final seconds = timestamp?.tryParseInt;
		if (seconds == null) {
			return null;
		}
		return DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true).toLocal();
	}

	/// A post body as HTML, without the truncation notice.
	///
	/// The notice is markup the site injected, not something the poster wrote,
	/// and its text is a link to the full body rather than part of it.
	static String _messageHtml(dom.Element? container) {
		if (container == null) {
			return '';
		}
		final clone = container.clone(true);
		for (final notice in clone.querySelectorAll('.omittedposts')) {
			notice.remove();
		}
		return clone.innerHtml.trim();
	}

	/// The thread a board card belongs to, from its wrapper's `id`.
	static int? _threadIdOf(dom.Element card) {
		final id = card.attributes['id'];
		return id == null ? null : _threadIdAttributePattern.firstMatch(id)?.group(1)?.tryParseInt;
	}

	/// The page a pager link points at: `/b/` is page 0, `/b-3/` is page 3.
	static int? _pageOfHref(String? href) {
		if (href == null) {
			return null;
		}
		final parts = href.split('/').where((s) => s.isNotEmpty).toList(growable: false);
		if (parts.isEmpty) {
			return null;
		}
		final segment = parts.last;
		final dash = segment.lastIndexOf('-');
		return dash == -1 ? 0 : segment.substring(dash + 1).tryParseInt;
	}

	static AttachmentType _attachmentType(String? kind, String source) {
		// `data-type` is the site's own classification, so it is preferred over
		// the extension: the captured videos are `.mp4` and `.webm`, but the
		// board settings also accept `.mkv`, which the extension table used by
		// every other site reads as an image.
		return switch (kind) {
			'embed' => AttachmentType.url,
			'video' => _extensionOf(source, fallback: null) == '.webm' ? AttachmentType.webm : AttachmentType.mp4,
			_ => AttachmentType.fromFilename(source)
		};
	}

	static String _absolute(String path) => path.startsWith('http') ? path : '$_host$path';

	/// Parses JSON, or nothing when the answer was not JSON at all.
	///
	/// The site sits behind Cloudflare, whose interstitials are HTML with a 200
	/// or 403 status, so a "JSON" endpoint can answer with a page. That is a
	/// missing board list or update, not a crash.
	static dynamic _decodeJson(String json) {
		try {
			return jsonDecode(json);
		}
		catch (_) {
			return null;
		}
	}

	static String _extensionOf(String source, {required String? fallback}) {
		final name = source.split(RegExp(r'[?#]')).first.afterLast('/');
		final dot = name.lastIndexOf('.');
		if (dot == -1 || dot == name.length - 1) {
			return fallback == null ? '' : '.$fallback';
		}
		return '.${name.substring(dot + 1).toLowerCase()}';
	}

	static int _bytes(String value, String unit) {
		final number = double.tryParse(value) ?? 0;
		return (number * switch (unit) {
			'KB' => 1024,
			'MB' => 1024 * 1024,
			'GB' => 1024 * 1024 * 1024,
			_ => 1
		}).round();
	}
}
