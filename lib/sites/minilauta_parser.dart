/// Parsing for minilauta.org, which runs miniboard (github.com/minilauta/miniboard).
///
/// miniboard has no JSON API - `/boards.json` and `/api/boards` answer with the
/// HTML error page and `/<board>/index.json` is a 500 - so every part of the
/// site is parsed from HTML. The markup is futaba-like:
///
/// ```
/// <div class="thread" id="thread_b-123">          <- one thread
///   <div class="post-container" id="pc_b-123">
///     <div class="post op" id="b-123">...</div>   <- the OP, no data-parent_id
///   </div>
///   <span class="omitted">76 replies omitted...</span>
///   <div class="post-container reply-container" id="rc_b-456">
///     <div class="post reply" id="b-456" data-parent_id="123">...</div>
///   </div>
/// </div>
/// ```
///
/// The replies are siblings of the OP's `.post-container` rather than children
/// of it, and a board page renders only the tail of a long thread plus an
/// `.omitted` count, so the posts a page carries are grouped into threads by
/// `data-parent_id` rather than by markup nesting, and the reply count is the
/// posts on the page plus the omitted ones.
///
/// Everything here is total: a field the page does not state (or states in a
/// shape that is not understood) is null, never an exception, so one unfamiliar
/// post cannot blank out a whole thread.
library;

import 'package:chan/models/attachment.dart';
import 'package:chan/util.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart';

/// A board as listed on the site's home page.
class MinilautaBoard {
	final String name;
	final String title;
	final bool isWorksafe;

	const MinilautaBoard({
		required this.name,
		required this.title,
		required this.isWorksafe
	});
}

/// An attachment as the page renders it.
class MinilautaAttachment {
	final String url;
	final String thumbnailUrl;
	final String filename;
	final int? sizeInBytes;
	final int? width;
	final int? height;
	/// The original filename in brackets after the dimensions, when shown.
	final String? originalFilename;
	/// miniboard renders spoiler files exactly like normal ones, so the page
	/// does not say whether a file is spoilered; always false rather than a guess.
	final bool spoiler;

	const MinilautaAttachment({
		required this.url,
		required this.thumbnailUrl,
		required this.filename,
		required this.sizeInBytes,
		required this.width,
		required this.height,
		required this.originalFilename,
		this.spoiler = false
	});

	String get ext {
		final name = url.split('/').last;
		final i = name.lastIndexOf('.');
		return i == -1 ? '' : name.substring(i).toLowerCase();
	}

	AttachmentType get type => AttachmentType.fromFilename(url);
}

/// A `>>1234` reference in a post body.
class MinilautaReference {
	/// The board the referenced post lives on; `>>>/b/1234` can point elsewhere.
	final String board;
	/// The thread the referenced post belongs to (the board the OP is on).
	final int? threadId;
	final int postId;

	const MinilautaReference({
		required this.board,
		required this.threadId,
		required this.postId
	});
}

/// One post, whether it opened a thread or replies to one.
class MinilautaPost {
	/// The post id, i.e. `82695` for `id="b-82695"`.
	final int id;
	/// The board id, i.e. `b` for `id="b-82695"`.
	final String board;
	/// The thread this post belongs to, from `data-parent_id` on replies.
	final int? parentId;
	/// Reply index within the thread, as the site numbers it. Null for the OP,
	/// and for posts served by the replies fragment, where the numbering is
	/// relative to the whole thread and cannot be known from the fragment alone.
	final int? replyNumber;
	final String name;
	final String? email;
	final String? tripCode;
	final String? capcode;
	final String? posterId;
	final String? subject;
	final DateTime time;
	/// The message as HTML, as `makeSpan` expects it.
	final String message;
	final List<MinilautaAttachment> attachments;
	final List<MinilautaReference> references;

	const MinilautaPost({
		required this.id,
		required this.board,
		required this.parentId,
		required this.replyNumber,
		required this.name,
		required this.email,
		required this.tripCode,
		required this.capcode,
		required this.posterId,
		required this.subject,
		required this.time,
		required this.message,
		required this.attachments,
		required this.references
	});

	bool get isOp => parentId == null;
}

/// One thread, either as a card on a board page or as a full thread page.
class MinilautaThread {
	final String board;
	final int id;
	final MinilautaPost op;
	/// The OP plus every reply that this page carries, in page order.
	final List<MinilautaPost> posts;
	/// Replies the board page did not render ("76 replies omitted").
	final int omittedReplies;

	const MinilautaThread({
		required this.board,
		required this.id,
		required this.op,
		required this.posts,
		required this.omittedReplies
	});

	List<MinilautaPost> get replies => posts.skip(1).toList(growable: false);

	/// The total number of replies: the ones on this page plus the omitted ones.
	int get replyCount => replies.length + omittedReplies;

	/// The subject, or the first line of the body when there is none.
	/// The subject, or the first non-blank line of the body when there is none.
	///
	/// This mirrors miniboard's own `<title>`, which trims the rendered message
	/// and takes its first 75 characters.
	String? get title {
		final subject = op.subject;
		if (subject != null && subject.trim().isNotEmpty) {
			return subject.trim();
		}
		// The message HTML begins with newlines and indentation, so the first
		// line of the parsed text is blank rather than the post's first line.
		for (final line in (parseFragment(op.message).text ?? '').split('\n')) {
			final trimmed = line.trim();
			if (trimmed.isEmpty) {
				continue;
			}
			return trimmed.length > 75 ? trimmed.substring(0, 75) : trimmed;
		}
		return null;
	}

	/// Post id -> ids of the posts that reference it.
	///
	/// miniboard has no server-rendered backlinks: its own JavaScript walks every
	/// `a.reference` and appends `a.backreference` links to the post it points at
	/// (see `pi()` in its bundle). Parsing the references instead means the same
	/// information without depending on that script having run.
	Map<int, List<int>> get backlinks {
		final map = <int, List<int>>{};
		for (final post in posts) {
			for (final reference in post.references) {
				(map[reference.postId] ??= []).add(post.id);
			}
		}
		return {
			for (final entry in map.entries) entry.key: List.unmodifiable(entry.value)
		};
	}
}

/// What a board page, catalog or thread page says about its own pagination.
class MinilautaPage {
	final int currentPage;
	final int pageCount;

	const MinilautaPage({required this.currentPage, required this.pageCount});
}

/// A board page: the threads it renders, grouped from the flat post list.
class MinilautaBoardPage {
	final List<MinilautaThread> threads;
	final MinilautaPage? page;

	const MinilautaBoardPage({required this.threads, required this.page});
}

/// A catalog page: one card per thread.
class MinilautaCatalogEntry {
	final String board;
	final int id;
	final String name;
	final String? subject;
	final String? message;
	final int? replyCount;
	final String? thumbnailUrl;
	final bool isPinned;

	const MinilautaCatalogEntry({
		required this.board,
		required this.id,
		required this.name,
		required this.subject,
		required this.message,
		required this.replyCount,
		required this.thumbnailUrl,
		required this.isPinned
	});
}

class MinilautaCatalogPage {
	final List<MinilautaCatalogEntry> threads;
	final MinilautaPage? page;

	const MinilautaCatalogPage({required this.threads, required this.page});
}

/// A thread page, with the thread id and board the page did not necessarily say.
class MinilautaThreadPage {
	final MinilautaThread thread;

	const MinilautaThreadPage({required this.thread});
}

/// The fragment returned by `/<board>/<thread>/replies/?post_id_after=N`.
///
/// It is a bare list of `div.post-container`s with no surrounding thread, so the
/// thread id can only come from `data-parent_id`.
class MinilautaReplyFragment {
	final int? threadId;
	final List<MinilautaPost> posts;

	const MinilautaReplyFragment({
		required this.threadId,
		required this.posts
	});
}

/// A post id sits in `id="b-82695"`, where the board id may itself contain a
/// dash, so the number after the last dash is the id.
final _postIdPattern = RegExp(r'-?(\d+)$');

int? _postIdOf(String? id) {
	if (id == null) {
		return null;
	}
	final match = _postIdPattern.firstMatch(id)?.group(1);
	return match == null ? null : int.tryParse(match);
}

/// `28/08/26(Fri)10:34:48`, from miniboard's `MB_DATEFORMAT` (`d/m/y(D)H:i:s`).
final _dateTimePattern = RegExp(r'^\s*(\d{1,2})/(\d{1,2})/(\d{2})(?:\([^)]*\))?(\d{1,2}):(\d{2})(?::(\d{2}))?\s*$');

/// Built as a local time so that the digits the site printed are the digits the
/// app shows; the site publishes no offset, so an instant cannot be recovered.
DateTime? _parseDateTime(String? text) {
	final match = _dateTimePattern.firstMatch(text ?? '');
	if (match == null) {
		return null;
	}
	final year = 2000 + int.parse(match.group(3)!);
	final month = int.parse(match.group(2)!);
	final day = int.parse(match.group(1)!);
	if (month < 1 || month > 12 || day < 1 || day > 31) {
		// The format matched but the values are not a date; fail soft.
		return null;
	}
	return DateTime(
		year,
		month,
		day,
		int.parse(match.group(4)!),
		int.parse(match.group(5)!),
		int.tryParse(match.group(6) ?? '') ?? 0
	);
}

final _sizePattern = RegExp(r'^([\d.]+)\s*(B|KB|MB|GB|TB)?$', caseSensitive: false);
final _dimensionsPattern = RegExp(r'^(\d+)\s*x\s*(\d+)$');

int? _parseSizeInBytes(String text) {
	final match = _sizePattern.firstMatch(text.trim());
	if (match == null) {
		return null;
	}
	final value = double.tryParse(match.group(1)!);
	if (value == null) {
		return null;
	}
	return (value * switch ((match.group(2) ?? 'B').toUpperCase()) {
		'TB' => 1024 * 1024 * 1024 * 1024,
		'GB' => 1024 * 1024 * 1024,
		'MB' => 1024 * 1024,
		'KB' => 1024,
		_ => 1
	}).round();
}

final _omittedRepliesPattern = RegExp(r'(\d+)\s+replies?\s+omitted', caseSensitive: false);

int? _parseOmittedReplies(dom.Element? thread) {
	if (thread == null) {
		return null;
	}
	for (final omitted in thread.querySelectorAll('.omitted')) {
		final count = _omittedRepliesPattern.firstMatch(omitted.text)?.group(1);
		if (count != null) {
			return int.tryParse(count);
		}
	}
	return null;
}

/// The board list table on `/`. The site also repeats the boards in the menubar
/// (names only, no titles) and in a mobile `<select>`; the table is the one with
/// titles, so only it is read. Boards are identified by their `/b/` style hrefs
/// and the `.nsfw` marker next to a title says the board is not worksafe.
List<MinilautaBoard> parseBoardList(String html) {
	final document = parse(html);
	final boards = <MinilautaBoard>[];
	final seen = <String>{};
	for (final table in _boardListTables(document)) {
		for (final anchor in table.querySelectorAll('a[href]')) {
			final href = anchor.attributes['href']!;
			if (!href.startsWith('/') || !href.endsWith('/') || href == '/') {
				continue;
			}
			final name = href.substring(1, href.length - 1);
			if (!RegExp(r'^[a-z0-9_-]{1,16}$').hasMatch(name)) {
				continue;
			}
			final title = anchor.text.trim();
			if (title.isEmpty || !seen.add(name)) {
				continue;
			}
			boards.add(MinilautaBoard(
				name: name,
				title: title,
				isWorksafe: anchor.parent?.querySelector('.nsfw') == null
			));
		}
	}
	return boards;
}

/// The tables that hold the board list, found by their header row: miniboard
/// renders a hidden `col1 col2 col3 col4` row above the boards.
Iterable<dom.Element> _boardListTables(dom.Document document) {
	final tables = <dom.Element>[];
	for (final table in document.querySelectorAll('table')) {
		final headers = table.querySelectorAll('th').map((th) => th.text.trim()).toList(growable: false);
		if (headers.length >= 2 && headers.first == 'col1') {
			tables.add(table);
		}
	}
	return tables;
}

/// Read the `table.pagetable`. Page numbers come from the link text, because the
/// hrefs are relative query strings (`?page=1`). The page that is not a link is
/// the one being viewed.
MinilautaPage? parsePage(dom.Document document) {
	final table = document.querySelector('table.pagetable');
	if (table == null) {
		return null;
	}
	int? currentPage;
	var maxPage = 0;
	for (final cell in table.querySelectorAll('td')) {
		for (final anchor in cell.querySelectorAll('a')) {
			final page = int.tryParse(anchor.text.trim());
			if (page != null) {
				maxPage = page > maxPage ? page : maxPage;
			}
		}
		if (currentPage == null) {
			final digits = RegExp(r'\d+').firstMatch(cell.text);
			if (digits != null) {
				currentPage = int.tryParse(digits.group(0)!);
			}
		}
	}
	if (currentPage == null && maxPage == 0) {
		return null;
	}
	currentPage ??= 0;
	return MinilautaPage(
		currentPage: currentPage,
		pageCount: (maxPage > currentPage ? maxPage : currentPage) + 1
	);
}

List<MinilautaAttachment> _parseAttachments(dom.Element post) {
	final attachments = <MinilautaAttachment>[];
	for (final info in post.querySelectorAll('.file-info')) {
		final fileAnchor = info.querySelector('a[href]');
		final url = fileAnchor?.attributes['href'];
		if (url == null || !url.contains('/src/')) {
			// Embed posts link out to the embedded URL instead of the site's own
			// copy and have no thumbnail to fetch.
			continue;
		}
		final thumb = post.querySelector('.file-thumb img[src]') ?? post.querySelector('img[src]');
		final thumbnailUrl = thumb?.attributes['src'] ?? url;
		int? width;
		int? height;
		String? originalFilename;
		int? sizeInBytes;
		// `(3.34MB, 2000x1266, Hifumi_syksy.png)`. The parts are optional and
		// variably ordered (Tegaki files add tool and duration fields), so each
		// parenthesised part is classified by what it parses as rather than by
		// position.
		for (final brackets in RegExp(r'\(([^()]*)\)').allMatches(info.text)) {
			for (final part in brackets.group(1)!.split(',')) {
				final trimmed = part.trim();
				if (trimmed.isEmpty) {
					continue;
				}
				if (_dimensionsPattern.firstMatch(trimmed) case final dimensions?) {
					width ??= int.tryParse(dimensions.group(1)!);
					height ??= int.tryParse(dimensions.group(2)!);
				}
				else if (_parseSizeInBytes(trimmed) case final size?) {
					sizeInBytes ??= size;
				}
				else {
					originalFilename ??= trimmed;
				}
			}
		}
		attachments.add(MinilautaAttachment(
			url: url,
			thumbnailUrl: thumbnailUrl,
			filename: url.split('/').last,
			sizeInBytes: sizeInBytes,
			width: width,
			height: height,
			originalFilename: originalFilename
		));
	}
	return attachments;
}

/// `a.reference` is miniboard's name for a quote link. The data attributes are
/// authoritative (they survive a bare `>>1234` text that was never turned into a
/// link, and they name the board for cross-board quotes); the href is only a
/// fallback.
List<MinilautaReference> _parseReferences(String message) {
	final references = <MinilautaReference>[];
	for (final anchor in parseFragment(message).querySelectorAll('a.reference')) {
		final attributes = anchor.attributes;
		final postId = int.tryParse(attributes['data-id'] ?? '') ?? _postIdOf(Uri.tryParse(attributes['href'] ?? '')?.fragment);
		if (postId == null) {
			// A board link (`>>>/b/`) has no post to point at.
			continue;
		}
		final board = attributes['data-board_id'];
		final threadId = int.tryParse(attributes['data-parent_id'] ?? '');
		final href = attributes['href'];
		final segments = href == null ? const <String>[] : (Uri.tryParse(href)?.pathSegments ?? const <String>[]);
		references.add(MinilautaReference(
			board: board ?? (segments.isNotEmpty ? segments.first : ''),
			threadId: threadId ?? (segments.length > 1 ? int.tryParse(segments[1]) : null),
			postId: postId
		));
	}
	return references;
}

MinilautaPost? _parsePost(dom.Element post, {required String board, int? fallbackParentId}) {
	final id = _postIdOf(post.attributes['id']);
	if (id == null) {
		return null;
	}
	final info = post.querySelector('.post-info');
	final nameElement = info?.querySelector('.post-name');
	final mailtoHref = nameElement?.parent?.localName == 'a' ? nameElement?.parent?.attributes['href'] : null;
	final message = post.querySelector('.post-message')?.innerHtml ?? '';
	// An OP carries no `data-parent_id`; assigning it the enclosing thread's id
	// would make every OP a reply to itself.
	final isOp = post.classes.contains('op');
	final explicitParentId = int.tryParse(post.attributes['data-parent_id'] ?? '');
	return MinilautaPost(
		id: id,
		board: post.attributes['data-board_id'] ?? board,
		parentId: isOp ? explicitParentId : (explicitParentId ?? fallbackParentId),
		replyNumber: int.tryParse(info?.querySelector('.post-number')?.text ?? ''),
		name: nameElement?.text.trim() ?? '',
		email: mailtoHref == null ? null : (() {
			final address = mailtoHref.startsWith('mailto:') ? mailtoHref.substring(7) : mailtoHref;
			return Uri.decodeComponent(address).nonEmptyOrNull;
		})(),
		tripCode: info?.querySelector('.post-trip')?.text.trim().nonEmptyOrNull,
		capcode: info?.querySelector('.post-cap')?.text.replaceFirst('##', '').trim().nonEmptyOrNull,
		posterId: info?.querySelector('.post-hashid-hash')?.text.trim().nonEmptyOrNull,
		subject: info?.querySelector('.post-subject')?.text.nonEmptyOrNull,
		// The board-page date is rendered in the server's timezone with no
		// offset. Falling back to "now" keeps a post usable rather than dropping
		// it, which is what the app's ordering expects.
		time: _parseDateTime(info?.querySelector('.post-datetime')?.text) ?? DateTime.now(),
		message: message,
		attachments: _parseAttachments(post),
		references: _parseReferences(message)
	);
}

/// Posts on a page, in document order, paired with the thread div they came from.
///
/// Every post on a board page lives inside its thread's div - miniboard renders
/// the replies as siblings of the OP's `.post-container`, but still inside
/// `div.thread` - so this is what stops the replies of one thread being read as
/// the replies of another. The replies fragment has no thread div at all and is
/// parsed by [parseReplyFragment] instead.
List<(dom.Element, dom.Element)> _walkPosts(dom.Document document) {
	final result = <(dom.Element, dom.Element)>[];
	for (final thread in document.querySelectorAll('.thread')) {
		for (final post in thread.querySelectorAll('.post')) {
			if (!post.classes.contains('preview')) {
				result.add((post, thread));
			}
		}
	}
	return result;
}

/// Group the flat post list into threads.
///
/// The thread a post belongs to is its `data-parent_id` (or, for an OP, its own
/// id), and the `div.thread` it appeared in is only used for the omitted-reply
/// count and as the fallback parent for a post that states none.
List<MinilautaThread> _groupThreads(List<(MinilautaPost, dom.Element)> posts, {int? onlyThreadId}) {
	final order = <int>[];
	final byThread = <int, List<MinilautaPost>>{};
	final threadElements = <int, dom.Element>{};
	for (final (post, threadElement) in posts) {
		final threadId = post.isOp ? post.id : post.parentId;
		if (threadId == null) {
			continue;
		}
		if (onlyThreadId != null && threadId != onlyThreadId) {
			continue;
		}
		if (!byThread.containsKey(threadId)) {
			order.add(threadId);
			byThread[threadId] = [];
			threadElements[threadId] = threadElement;
		}
		byThread[threadId]!.add(post);
	}
	return [
		for (final threadId in order)
			MinilautaThread(
				board: byThread[threadId]!.first.board,
				id: threadId,
				op: byThread[threadId]!.firstWhere((p) => p.id == threadId, orElse: () => byThread[threadId]!.first),
				// A mutable copy: callers merge into this list when a thread is
				// refreshed, and an unmodifiable one throws.
				posts: List.of(byThread[threadId]!),
				omittedReplies: _parseOmittedReplies(threadElements[threadId]) ?? 0
			)
	];
}

List<(MinilautaPost, dom.Element)> _parsePosts(dom.Document document, {String? fallbackBoard}) {
	final posts = <(MinilautaPost, dom.Element)>[];
	for (final (element, threadElement) in _walkPosts(document)) {
		// `<div class="thread" id="thread_b-123">`; a catalog card is also a
		// `.thread` but has no such id and no `.post` inside it.
		final threadMatch = RegExp(r'^thread_(.+)-(\d+)$').firstMatch(threadElement.attributes['id'] ?? '');
		final board = threadMatch?.group(1) ?? fallbackBoard ?? '';
		final post = _parsePost(element, board: board, fallbackParentId: int.tryParse(threadMatch?.group(2) ?? ''));
		if (post != null) {
			posts.add((post, threadElement));
		}
	}
	return posts;
}

String? _boardFromFormAction(dom.Document document) {
	final action = document.querySelector('#form-post')?.attributes['action'];
	if (action == null) {
		return null;
	}
	final segments = Uri.tryParse(action)?.pathSegments ?? const <String>[];
	return segments.isEmpty ? null : segments.first;
}

/// The board a page belongs to, taken from the post form, which every board,
/// catalog and thread page renders with the board in its action.
String? boardIdOfPage(String html, {dom.Document? document}) {
	return _boardFromFormAction(document ?? parse(html));
}

/// Parse a board page (`/<board>/`): its threads, each with the replies the page
/// chose to render, and its pagination.
///
/// [board] is only needed because a bare HTML body has no other record of it.
MinilautaBoardPage parseBoardPage(String html, {String? board}) {
	final document = parse(html);
	final boardId = board ?? _boardFromFormAction(document);
	if (boardId == null) {
		// The page says nothing about which board it is; nothing can be trusted.
		return const MinilautaBoardPage(threads: [], page: null);
	}
	return MinilautaBoardPage(
		threads: _groupThreads(_parsePosts(document, fallbackBoard: boardId)),
		page: parsePage(document)
	);
}

/// Parse a thread page (`/<board>/<id>/`) or the page of a single thread.
///
/// The thread id is normally visible on the page (`id="thread_b-123"`), but a
/// page that failed to render the thread is reported as a page with no posts so
/// the caller can raise "thread not found" rather than showing an empty thread.
MinilautaThreadPage parseThreadPage(String html, {required String board, int? threadId}) {
	final document = parse(html);
	final parsed = _parsePosts(document, fallbackBoard: board);
	final threads = _groupThreads(parsed, onlyThreadId: threadId);
	final effectiveThreadId = threadId ?? threads.firstOrNull?.id;
	if (effectiveThreadId == null) {
		// No post mentions a thread, so the page is an error or an empty thread.
		return MinilautaThreadPage(thread: MinilautaThread(
			board: board,
			id: threadId ?? 0,
			op: _emptyPost(board),
			posts: const [],
			omittedReplies: 0
		));
	}
	final thread = threads.firstWhere(
		(t) => t.id == effectiveThreadId,
		orElse: () => MinilautaThread(
			board: board,
			id: effectiveThreadId,
			op: _emptyPost(board),
			posts: const [],
			omittedReplies: 0
		)
	);
	return MinilautaThreadPage(thread: thread);
}

/// Parse the `/<board>/catalog/` page into one entry per thread card.
MinilautaCatalogPage parseCatalog(String html, {required String board}) {
	final document = parse(html);
	final entries = <MinilautaCatalogEntry>[];
	for (final card in document.querySelectorAll('.thread.post-catalog')) {
		final id = _postIdOf(card.attributes['id']);
		if (id == null) {
			continue;
		}
		final header = card.querySelector('.post-catalog-header');
		final meta = card.querySelector('.post-catalog-meta');
		final title = card.querySelector('.post-catalog-title');
		final thumbnail = card.querySelector('img[src]')?.attributes['src'];
		entries.add(MinilautaCatalogEntry(
			board: card.querySelector('.post-catalog-link')?.attributes['data-board_id'] ?? board,
			id: id,
			name: header?.querySelector('.post-catalog-name')?.text.trim() ?? '',
			subject: title?.querySelector('.post-catalog-subject')?.text.nonEmptyOrNull,
			message: title?.querySelector('.post-catalog-message')?.text.nonEmptyOrNull,
			replyCount: meta?.querySelector('b')?.text.tryParseInt,
			// A card without a file renders the site's placeholder image, which is
			// not an attachment of the thread.
			thumbnailUrl: thumbnail != null && thumbnail != '/static/nofile.png' ? thumbnail : null,
			isPinned: card.classes.contains('thread-pinned')
		));
	}
	return MinilautaCatalogPage(threads: entries, page: parsePage(document));
}

/// Parse the HTML fragment `/<board>/<thread>/replies/?post_id_after=N` returns.
///
/// It carries no thread div and no pagination, so the thread a post belongs to
/// comes from `data-parent_id` and the board from `data-board_id` on the posts.
MinilautaReplyFragment parseReplyFragment(String html, {String? board, int? threadId}) {
	final document = parseFragment(html);
	final parsed = <(MinilautaPost, dom.Element?)>[];
	for (final post in document.querySelectorAll('.post')) {
		if (post.classes.contains('preview')) {
			continue;
		}
		final parsedPost = _parsePost(post, board: board ?? '', fallbackParentId: threadId);
		if (parsedPost != null) {
			parsed.add((parsedPost, null));
		}
	}
	return MinilautaReplyFragment(
		threadId: threadId ?? parsed.firstOrNull?.$1.parentId,
		posts: parsed.map((e) => e.$1).toList(growable: false)
	);
}

MinilautaPost _emptyPost(String board) => MinilautaPost(
	id: 0,
	board: board,
	parentId: null,
	replyNumber: null,
	name: '',
	email: null,
	tripCode: null,
	capcode: null,
	posterId: null,
	subject: null,
	time: DateTime.now(),
	message: '',
	attachments: const [],
	references: const []
);
