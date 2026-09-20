import 'dart:collection';

import 'package:chan/models/attachment.dart';
import 'package:chan/models/board.dart';
import 'package:chan/models/flag.dart';
import 'package:chan/models/post.dart';
import 'package:chan/models/thread.dart';
import 'package:chan/sites/imageboard_site.dart';
import 'package:chan/util.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart';

/// Parses ylilauta.org's server-rendered HTML.
///
/// Kept separate from [SiteYlilauta] so the DOM rules can be exercised against
/// captured pages without needing a site instance (and therefore without an
/// HTTP client).
///
/// Two page shapes matter, and they are *not* interchangeable:
///
///  * **Board page** (`/<board>/`) — each thread is one compact
///    `div.card.thread` carrying the full card classes (`op-post`, `op`). It
///    holds only a truncated OP preview: no `data-post-id` on the card itself,
///    no reply posts, and `footer .stats` is bare text like `898 1` rather than
///    the labelled `898 replies by 283 users` seen on a thread page. The OP post
///    id has to be read from the card's own menu button, and the thread id from
///    the `a.card-post` href.
///  * **Thread page** (`/<board>/<slug>`) — one `div.card.thread` containing
///    real `div.post[data-post-id]` elements (the OP has extra classes), with
///    `figure.file` attachments and labelled stats.
///
/// Note that a thread's *public* slug is frequently not numeric (for example
/// `29cjqi`), while `data-thread-id` is a different, internal identifier. Chance
/// models thread ids as `int`, so the numeric slug from the thread URL is the
/// canonical id and non-numeric slugs are skipped during catalog parsing.
class YlilautaParser {
	const YlilautaParser._();

	static const boardListSelector = 'p[data-board]';
	/// The poster badge ylilauta shows on posts by the thread's starter.
	///
	/// The site puts it where other posters get a number, and it is the only
	/// thing the post's info row can show for them.
	static const kOpPosterId = 'OP';

	static const threadCardSelector = 'div.card.thread';
	static const postSelector = 'div.post[data-post-id]';

	/// Compact board-page cards are the ones that mark themselves `op-post`.
	static bool isCompactCard(dom.Element card) => card.classes.contains('op-post');

	static List<ImageboardBoard> parseBoards(String html, {
		required int filesPerPost,
		required int? maxUploadSizeBytes
	}) {
		final document = parse(html);
		return document.querySelectorAll(boardListSelector).map((e) {
			final name = e.attributes['data-board'];
			// The anchor label is the human-readable board title.
			final title = e.querySelector('a')?.text.trim();
			if (name == null || title == null || title.isEmpty) {
				return null;
			}
			return ImageboardBoard(
				name: name,
				title: title,
				isWorksafe: false,
				webmAudioAllowed: true,
				filesPerPost: filesPerPost,
				maxImageSizeBytes: maxUploadSizeBytes,
				maxWebmSizeBytes: maxUploadSizeBytes
			);
		}).nonNulls.toList(growable: false);
	}

	static Catalog parseCatalog(String html, {
		required String board,
		required String defaultUsername,
		required DateTime fetchedTime
	}) {
		final document = parse(html);
		final threads = <int, Thread>{};
		for (final card in document.querySelectorAll(threadCardSelector)) {
			if (!isCompactCard(card)) {
				// Not a board-page card.
				continue;
			}
			// The thread's identity is `data-thread-id`, which is numeric and is
			// the same on this card and on the thread page. The URL slug is a
			// separate, frequently non-numeric value (`/rikokset/29cjqi`), so it
			// is carried alongside rather than used as the id: using the slug
			// meant discarding every thread whose slug was not a number, which
			// was most of them, leaving boards apparently empty.
			final threadId = card.attributes['data-thread-id']?.tryParseInt;
			if (threadId == null) {
				continue;
			}
			final op = _parseCompactCard(board, threadId, card, defaultUsername);
			if (op == null) {
				continue;
			}
			threads[threadId] = _buildThread(
				board: board,
				threadId: threadId,
				posts: [op],
				op: op,
				replyCount: _parseBareReplyCount(card),
				uniqueIPCount: null,
				urlSlug: compactCardSlug(card),
				fetchedTime: fetchedTime
			);
		}
		return Catalog(
			threads: LinkedHashMap.from(threads),
			lastModified: null,
			fetchedTime: fetchedTime
		);
	}

	/// Parses a thread page fetched by URL slug.
	///
	/// The slug in the URL is not the thread's id, so the id is read from the
	/// page itself. That makes this work for a link the user pasted, where the
	/// only thing known up front is the slug.
	static Thread parseThreadBySlug(String html, {
		required String board,
		required String slug,
		required String defaultUsername,
		required DateTime fetchedTime
	}) {
		final id = cardForSlug(parse(html), slug)?.attributes['data-thread-id']?.tryParseInt;
		if (id == null) {
			throw const ThreadNotFoundException();
		}
		return parseThread(html, board: board, threadId: id, defaultUsername: defaultUsername, urlSlug: slug, fetchedTime: fetchedTime);
	}

	/// The thread a page is showing, as the address it is at.
	///
	/// This is what a post's own address (`/post/<id>`) resolves to: the site
	/// answers it with the thread holding that post, whose card names its own
	/// board and slug. Nothing else on such a page says which thread it is.
	static ({String board, String slug})? threadAddress(String html) {
		final url = parse(html).querySelector(threadCardSelector)?.attributes['data-url'];
		if (url == null) {
			return null;
		}
		// Only the path names the thread: a query or a fragment rides on the
		// last segment otherwise, and a slug of "28qom4?page=2" matches no card.
		final path = url.split(RegExp(r'[?#]')).first;
		final parts = path.split('/').where((p) => p.isNotEmpty).toList(growable: false);
		if (parts.length < 2) {
			return null;
		}
		return (board: parts[parts.length - 2], slug: parts.last);
	}

	/// The card of the thread at [slug], out of every card a page carries.
	///
	/// A thread page shows one card today, but the selector matches any card, so
	/// the one whose own address names the thread is preferred over whichever
	/// happens to come first: a page that also lists other threads - a sidebar,
	/// a related-threads block - would otherwise be parsed as the wrong thread,
	/// and the app would show posts from a thread nobody opened.
	static dom.Element? cardForSlug(dom.Document document, String slug) {
		final cards = document.querySelectorAll(threadCardSelector);
		for (final card in cards) {
			final url = card.attributes['data-url'];
			if (url == null) {
				continue;
			}
			final parts = url.split('/').where((p) => p.isNotEmpty);
			if (parts.isNotEmpty && parts.last == slug) {
				return card;
			}
		}
		return cards.firstOrNull;
	}

	static Thread parseThread(String html, {
		required String board,
		required int threadId,
		required String defaultUsername,
		String? urlSlug,
		required DateTime fetchedTime
	}) {
		final document = parse(html);
		// The card of *this* thread rather than simply the first card on the
		// page: the selector matches every thread a page lists, and a page that
		// also shows others would have their posts read as this thread's.
		dom.Element? card = (urlSlug == null) ? document.querySelector(threadCardSelector) : cardForSlug(document, urlSlug);
		card ??= document.body;
		final elements = card?.querySelectorAll(postSelector) ?? const <dom.Element>[];
		final posts = elements
			.map((e) => parsePost(e, board: board, threadId: threadId, defaultUsername: defaultUsername))
			.nonNulls
			.toList(growable: false);
		if (posts.isEmpty) {
			// Deleted threads are served as an ordinary 200 page.
			throw const ThreadNotFoundException();
		}
		linkReplies(posts);
		return _buildThread(
			board: board,
			threadId: threadId,
			posts: posts,
			// The OP is rendered first.
			op: posts.first,
			replyCount: _parseLabelledReplyCount(card),
			uniqueIPCount: _parseUniqueUsers(card),
			// Fall back to the slug the caller fetched with, so it is recorded
			// even when the page's own card markup is missing.
			urlSlug: urlSlug ?? compactCardSlugOf(card),
			fetchedTime: fetchedTime
		);
	}

	/// The slug of an already-fetched thread page, if it exposes one.
	static String? compactCardSlugOf(dom.Element? card) {
		if (card == null) {
			return null;
		}
		// A thread page's card carries the canonical URL directly.
		final dataUrl = card.attributes['data-url'];
		if (dataUrl != null) {
			final segments = Uri.tryParse(dataUrl)?.pathSegments.where((s) => s.isNotEmpty).toList(growable: false) ?? const <String>[];
			if (segments.length >= 2) {
				return segments[1];
			}
		}
		return null;
	}

	/// The signed token the board page carries on its `.threads` container.
	///
	/// It accompanies every "load more threads" request, and pairs with the
	/// thread id to tell the server where the listing currently ends.
	static String? parseCatalogState(String html) {
		final element = parse(html).querySelector('.threads, .thread-stubs');
		return element?.attributes['data-state'];
	}

	/// Parses the fragment returned by the "load more threads" endpoint.
	///
	/// It contains the same compact cards as the board page itself, so the
	/// catalog parser handles it directly; anything unexpected simply yields no
	/// threads, which is how the caller learns the listing has ended.
	static List<Thread> parseMoreThreads(String html, {
		required String board,
		required String defaultUsername,
		required DateTime fetchedTime
	}) {
		return parseCatalog(html, board: board, defaultUsername: defaultUsername, fetchedTime: fetchedTime)
			.threads
			.values
			.toList(growable: false);
	}

	/// Board-page card OP. Everything here comes from the card's own layout
	/// because a compact card has no `div.post` to read.
	static Post? _parseCompactCard(String board, int threadId, dom.Element card, String defaultUsername) {
		final postId = card.querySelector('button[data-post-id]')?.attributes['data-post-id']?.tryParseInt;
		if (postId == null) {
			return null;
		}
		final time = _parseTime(card.querySelector('span.time')?.attributes['data-timestamp'])
			?? DateTime.now();
		final preview = card.querySelector('a.card-post div.message');
		return Post(
			board: board,
			// The preview text already carries the thread's own subject line,
			// which ylilauta does not expose as a separate field.
			text: preview?.innerHtml.trim() ?? '',
			name: defaultUsername,
			time: time,
			threadId: threadId,
			id: postId,
			spanFormat: PostSpanFormat.ylilauta,
			attachments_: [if (card.querySelector('figure.file') case final f?) f].map((f) => parseAttachment(threadId, f)).nonNulls.toList(growable: false),
			// The card previews the post that opened the thread - `a.card-post` is
			// that post, and a compact card has no `data-user-id` to read - so its
			// poster is the thread starter, which is what "OP" is here. Leaving it
			// null meant a thread opened from the board listing showed no badge on
			// its first post until a refresh replaced the card with the thread
			// page, because a fetch merges into the post the card already made.
			posterId: kOpPosterId,
			flag: parseFlag(card)
		);
	}

	/// Thread-page post.
	static Post? parsePost(dom.Element element, {
		required String board,
		required int threadId,
		required String defaultUsername
	}) {
		final id = element.attributes['data-post-id']?.tryParseInt;
		if (id == null) {
			return null;
		}
		final meta = _directChild(element, 'div', 'post-meta');
		final attachments = _directChildren(element, 'figure')
			.map((f) => parseAttachment(threadId, f))
			.nonNulls
			.toList(growable: false);
		final message = _directChild(element, 'div', 'post-message');
		// `data-user-id` is a per-thread poster number. The thread starter does
		// not get one: the site renders "OP" in the same slot instead, on the
		// thread's first post and on that poster's later replies alike (those
		// carry the `op` class too, and 0 is what the attribute holds). The badge
		// is carried through as the id rather than dropped, so those posts are
		// not the only ones with nothing to show there - and clicking it lists
		// everything the thread starter wrote, which is what the site does.
		final userId = element.attributes['data-user-id'];
		return Post(
			board: board,
			text: extractMessageHtml(message),
			name: defaultUsername,
			time: _parseTime(meta?.querySelector('span.time')?.attributes['data-timestamp']) ?? DateTime.now(),
			threadId: threadId,
			id: id,
			spanFormat: PostSpanFormat.ylilauta,
			attachments_: attachments,
			posterId: (userId == null || userId.isEmpty) ? null : (userId == '0' ? kOpPosterId : userId),
			upvotes: meta?.querySelector('span.post-upvotes')?.attributes['data-count']?.tryParseInt,
			flag: parseFlag(element)
		);
	}

	/// The flag the site shows beside a post, as the image it is.
	///
	/// `img.flag` carries the country in `title` (and its code in `alt`) and
	/// points at a PNG on the site's own host, which serves static files to a
	/// plain client. No size is published for it, so it is reported without one
	/// rather than inside a box that would stretch a flag of another shape.
	static ImageboardFlag? parseFlag(dom.Element post) {
		final image = post.querySelector('img.flag');
		if (image == null) {
			return null;
		}
		final src = image.attributes['src'];
		final name = image.attributes['title'] ?? image.attributes['alt'];
		if (src == null || src.isEmpty || name == null || name.isEmpty) {
			return null;
		}
		return ImageboardFlag.unmeasured(
			name: name,
			imageUrl: src.startsWith('http') ? src : 'https://ylilauta.org$src'
		);
	}

	/// `package:html` does not implement the `:scope` pseudo-class, so direct
	/// children are selected by hand.
	static dom.Element? _directChild(dom.Element parent, String tag, String className) {
		for (final child in parent.children) {
			if (child.localName == tag && child.classes.contains(className)) {
				return child;
			}
		}
		return null;
	}

	static Iterable<dom.Element> _directChildren(dom.Element parent, String tag) {
		return parent.children.where((c) => c.localName == tag);
	}

	/// Post body HTML with quoted-post previews removed.
	///
	/// Ylilauta renders a preview of every quoted post inline, as
	/// `<div class="post-ref short" data-post-id="…">` wrapping a full copy of
	/// the quoted post's own `div.post-message`, followed by the quoting post's
	/// real text. The preview body is redundant (the quoted post is in the same
	/// thread) and would otherwise be parsed as part of the quoting post's text,
	/// so it is replaced by a single empty `span.ref` carrying the target id.
	/// That keeps the quote link while dropping the duplicated body.
	static String extractMessageHtml(dom.Element? message) {
		if (message == null) {
			return '';
		}
		final clone = message.clone(true);
		for (final preview in clone.querySelectorAll('div.post-ref')) {
			final postId = preview.attributes['data-post-id'];
			if (postId == null) {
				preview.remove();
				continue;
			}
			preview.replaceWith(dom.Element.tag('span')
				..classes.add('ref')
				..attributes['data-post-id'] = postId);
		}
		return clone.innerHtml.trim();
	}

	static Attachment? parseAttachment(int threadId, dom.Element figure) {
		final fileId = figure.attributes['data-file-id'];
		final src = figure.attributes['data-file-src'];
		if (fileId == null || src == null) {
			return null;
		}
		final fileType = figure.attributes['data-file-type'] ?? '';
		final mediaType = figure.attributes['data-media-type'] ?? 'image';
		// The poster frame doubles as the thumbnail; fall back to the file
		// itself when no scaled preview is offered.
		final poster = figure.attributes['data-poster'] ?? src;
		// `data-file-size` is 0 wherever the site has not measured the file -
		// the board and catalog listings, and some thread posts - and real
		// bytes where it has. Zero is a placeholder there rather than a size,
		// so it is reported as unknown: printing it showed "0 B" against every
		// previewed file, and, being non-null, it also stopped the real size
		// from being merged in when the thread itself was fetched.
		final size = figure.attributes['data-file-size']?.tryParseInt;
		return Attachment(
			board: 'ylilauta',
			id: fileId,
			// With the dot, like every other site: the save path strips the
			// extension off the filename and concatenates this back on, so a
			// dotless one produced a name with no extension at all and the
			// gallery refused it.
			ext: '.$fileType',
			filename: '$fileId.$fileType',
			url: src,
			thumbnailUrl: poster,
			md5: '',
			width: figure.attributes['data-file-width']?.tryParseInt,
			height: figure.attributes['data-file-height']?.tryParseInt,
			threadId: threadId,
			sizeInBytes: (size ?? 0) > 0 ? size : null,
			type: _attachmentType(mediaType, fileType)
		);
	}

	static AttachmentType _attachmentType(String mediaType, String fileType) {
		if (mediaType == 'audio') {
			return AttachmentType.mp3;
		}
		if (mediaType == 'video') {
			return fileType.toLowerCase() == 'webm' ? AttachmentType.webm : AttachmentType.mp4;
		}
		return AttachmentType.fromFilename(fileType);
	}

	/// Attributes replies to the posts they quote.
	///
	/// Ylilauta publishes no reply tree, so it is inferred from the quote links
	/// that [extractMessageHtml] preserves.
	static void linkReplies(List<Post> posts) {
		final byId = {for (final p in posts) p.id: p};
		for (final post in posts) {
			for (final target in post.repliedToIds) {
				byId[target]?.maybeAddReplyId(post.id);
			}
		}
	}

	static Thread _buildThread({
		required String board,
		required int threadId,
		required List<Post> posts,
		required Post op,
		required int replyCount,
		required int? uniqueIPCount,
		String? urlSlug,
		required DateTime fetchedTime
	}) {
		return Thread(
			// Must be growable: Thread.mergePosts mutates this list in place with
			// removeAt/insert when a thread is refreshed, and a fixed-length list
			// makes that throw "cannot remove from a fixed-length list". Passing
			// a fixed-length list here made opening a thread fail outright.
			posts_: posts.toList(),
			replyCount: replyCount < 0 ? 0 : replyCount,
			imageCount: posts.expand((p) => p.attachments).length,
			id: threadId,
			board: board,
			// Ylilauta has no separate subject field; the OP body carries it and
			// Chance derives a title from that.
			title: null,
			isSticky: false,
			time: op.time,
			attachments: op.attachments.toList(),
			uniqueIPCount: uniqueIPCount,
			urlSlug: urlSlug
		);
	}

	/// Board-page stats are bare numbers: `<replies> <votes>`.
	static int _parseBareReplyCount(dom.Element card) {
		final text = card.querySelector('footer.thread-meta .stats')?.text.trim() ?? '';
		return _kBareCountPattern.firstMatch(text)?.group(1)?.tryParseInt ?? 0;
	}

	/// Thread-page stats are labelled: `898 replies by 283 users`.
	static int _parseLabelledReplyCount(dom.Element? card) {
		final text = card?.querySelector('footer.thread-meta .stats')?.text.trim() ?? '';
		return _kReplyCountPattern.firstMatch(text)?.group(1)?.tryParseInt ?? 0;
	}

	static int? _parseUniqueUsers(dom.Element? card) {
		final text = card?.querySelector('footer.thread-meta .stats')?.text.trim() ?? '';
		return _kUserCountPattern.firstMatch(text)?.group(1)?.tryParseInt;
	}

	static DateTime? _parseTime(String? timestamp) {
		final seconds = timestamp?.tryParseInt;
		if (seconds == null) {
			return null;
		}
		return DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true).toLocal();
	}

	/// Compact cards link to `/<board>/<slug>`. The slug addresses the thread but
	/// is not its id, so it is kept for building URLs later.
	static String? compactCardSlug(dom.Element card) {
		final href = card.querySelector('a.card-post')?.attributes['href'];
		if (href == null) {
			return null;
		}
		final segments = Uri.tryParse(href)?.pathSegments.where((s) => s.isNotEmpty).toList(growable: false) ?? const <String>[];
		if (segments.length < 2) {
			return null;
		}
		return segments[1];
	}
}

final _kBareCountPattern = RegExp(r'^(\d+)');
final _kReplyCountPattern = RegExp(r'(\d+)\s+repl');
final _kUserCountPattern = RegExp(r'by\s+(\d+)\s+user');
