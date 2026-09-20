import 'dart:async';

import 'package:chan/models/attachment.dart';
import 'package:chan/models/board.dart';
import 'package:chan/models/post.dart';
import 'package:chan/models/thread.dart';
import 'package:chan/services/persistence.dart';
import 'package:chan/sites/imageboard_site.dart';
import 'package:chan/sites/lainchan.dart';
import 'package:chan/sites/minilauta_parser.dart';
import 'package:chan/sites/util.dart';
import 'package:chan/util.dart';
import 'package:chan/widgets/post_spans.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart';

/// minilauta.org, a Finnish imageboard running miniboard.
///
/// Everything is HTML: miniboard has no JSON API at all, and the one machine
/// friendly endpoint it does have - `/<board>/<id>/replies/?post_id_after=N` -
/// answers with an HTML fragment of the posts that follow a given post id, which
/// the site's own JavaScript polls every ten seconds. Reading is therefore
/// [Site4Chan]-style parsing plus that fragment as the thread tail.
///
/// Posting is deliberately not implemented: the form markup shows the fields and
/// the per-session `csrf_token`, but miniboard also validates an
/// `h-captcha-response` on every post from a logged-out client
/// (`funcs_common_validate_captcha` in its `src/common/funcs_common.php`), and
/// neither the token nor a captcha can be obtained or checked without actually
/// posting. See [supportsPosting].
class SiteMinilauta extends ImageboardSite with DecodeGenericUrlMixin {
	@override
	final String baseUrl;
	@override
	final String name;
	@override
	final String defaultUsername;
	/// miniboard's post form has a single, non-`multiple` `<input type="file">`,
	/// so a post carries at most one file even though the field is named
	/// `file[]` and the server would read a second one from `$files[1]` for its
	/// own two-file Tegaki format.
	final int defaultFilesPerPost;
	final int? maxUploadSizeBytes;
	/// Boards the site exposes. Kept for the config-file style of site
	/// definition, where the list is known in advance and fetching `/` is
	/// unnecessary.
	final List<ImageboardBoard>? boards;

	/// The number of catalog pages each board reported on its last catalog fetch.
	/// miniboard's catalog is paged (`?page=N`) and says how many pages there are
	/// only on the page itself, so the count has to be carried from the fetch.
	final Map<String, int> _pageCounts = {};

	/// miniboard renders quotes as `<a class='reference' data-board_id='b'
	/// data-parent_id='82695' data-id='82697' href='/b/82695/#b-82697'>`.
	/// A reference with no `data-id` is a board link (`>>>/b/`).
	static PostNodeSpan makeSpan(String board, int threadId, String data) {
		final body = parseFragment(data);
		int spoilerSpanId = 0;
		List<PostSpan> visit(Iterable<dom.Node> nodes) {
			final elements = <PostSpan>[];
			for (final node in nodes) {
				if (node is! dom.Element) {
					elements.addAll(SiteLainchan.parsePlaintext(node.text ?? ''));
					continue;
				}
				final classes = node.classes;
				final attributes = node.attributes;
				if (node.localName == 'br') {
					elements.add(const PostLineBreakSpan());
				}
				else if (node.localName == 'a' && classes.contains('reference')) {
					// The ids are in the data attributes when miniboard resolved the
					// quoted post, and in the href (`/b/999/#b-1000`) either way.
					final postId = int.tryParse(attributes['data-id'] ?? '') ?? _postIdFromFragment(attributes['href']);
					final referenceBoard = attributes['data-board_id'] ?? _boardOfReferenceHref(attributes['href']);
					if (postId == null || referenceBoard == null) {
						// `>>>/b/` is a link to a board, not to a post.
						if (referenceBoard != null) {
							elements.add(PostBoardLinkSpan(referenceBoard));
						}
						else if (attributes['href'] case final href?) {
							elements.add(PostLinkSpan(href, name: node.text.nonEmptyOrNull));
						}
						else {
							elements.addAll(SiteLainchan.parsePlaintext(node.outerHtml));
						}
					}
					else {
						elements.add(PostQuoteLinkSpan(
							board: referenceBoard,
							threadId: int.tryParse(attributes['data-parent_id'] ?? '') ?? _threadIdOfReferenceHref(attributes['href']) ?? threadId,
							postId: postId
						));
					}
				}
				else if (node.localName == 'a') {
					elements.add(PostLinkSpan(
						attributes['href'] ?? node.text,
						name: node.text.nonEmptyOrNull
					));
				}
				else if (classes.contains('quote')) {
					elements.add(PostQuoteSpan(PostNodeSpan(visit(node.nodes))));
				}
				else if (classes.contains('spoiler')) {
					elements.add(PostSpoilerSpan(PostNodeSpan(visit(node.nodes)), spoilerSpanId++));
				}
				else if (node.localName == 'pre' || classes.contains('code')) {
					elements.add(PostCodeSpan(node.text.trimRight()));
				}
				else if (node.localName == 'b' || node.localName == 'strong') {
					elements.add(PostBoldSpan(PostNodeSpan(visit(node.nodes))));
				}
				else if (node.localName == 'i' || node.localName == 'em') {
					elements.add(PostItalicSpan(PostNodeSpan(visit(node.nodes))));
				}
				else if (node.localName == 'u') {
					elements.add(PostUnderlinedSpan(PostNodeSpan(visit(node.nodes))));
				}
				else if (node.localName == 's' || node.localName == 'strike' || node.localName == 'del') {
					elements.add(PostStrikethroughSpan(PostNodeSpan(visit(node.nodes))));
				}
				else if (node.localName == 'sup') {
					elements.add(PostSuperscriptSpan(PostNodeSpan(visit(node.nodes))));
				}
				else if (node.localName == 'sub') {
					elements.add(PostSubscriptSpan(PostNodeSpan(visit(node.nodes))));
				}
				else if (attributes['src'] case final src? when node.localName == 'img') {
					elements.add(PostInlineImageSpan(
						src: src,
						width: attributes['width']?.tryParseInt ?? 16,
						height: attributes['height']?.tryParseInt ?? 16
					));
				}
				else if (classes.isEmpty && !['span', 'div', 'label', 'p'].contains(node.localName)) {
					// miniboard only emits b/i/u/s/sup/sub/pre/span/a/br itself;
					// anything else is preserved as text rather than guessed at.
					elements.addAll(SiteLainchan.parsePlaintext(node.outerHtml));
				}
				else {
					elements.addAll(visit(node.nodes));
				}
			}
			return elements;
		}
		return PostNodeSpan(visit(body.nodes).toList(growable: false));
	}

	/// `/b/123/#b-456` -> `b`, for a reference whose `data-board_id` is missing.
	static String? _boardOfReferenceHref(String? href) {
		final segments = href == null ? const <String>[] : (Uri.tryParse(href)?.pathSegments ?? const <String>[]);
		return segments.isEmpty ? null : segments.first.nonEmptyOrNull;
	}

	/// `/b/123/#b-456` -> `123`.
	static int? _threadIdOfReferenceHref(String? href) {
		final segments = href == null ? const <String>[] : (Uri.tryParse(href)?.pathSegments ?? const <String>[]);
		return segments.length > 1 ? int.tryParse(segments[1]) : null;
	}

	/// `/b/123/#b-456` -> `456`. The fragment is `#b-<id>` for a post anchor and
	/// `#q<id>` for the quote anchor; both end in the post id.
	static int? _postIdFromFragment(String? href) {
		final fragment = href == null ? null : Uri.tryParse(href)?.fragment;
		if (fragment == null || fragment.isEmpty) {
			return null;
		}
		final digits = RegExp(r'(\d+)$').firstMatch(fragment);
		return digits == null ? null : int.tryParse(digits.group(1)!);
	}

	SiteMinilauta({
		required this.baseUrl,
		required this.name,
		this.defaultUsername = 'Anonyymi',
		this.defaultFilesPerPost = 1,
		this.maxUploadSizeBytes,
		this.boards,
		required super.overrideUserAgent,
		required super.addIntrospectedHeaders,
		required super.preferHttp3WithoutAltSvc,
		required super.archives,
		required super.imageHeaders,
		required super.videoHeaders
	});

	@override
	@protected
	String get res => '';

	@override
	Uri? get iconUrl => Uri.https(baseUrl, '/favicon.ico');

	@override
	String get siteData => baseUrl;

	@override
	String get siteType => 'minilauta';

	@override
	bool get hasPagedCatalog => true;

	/// The site has a fixed, short board list, so no paged catalogs.
	@override
	bool get allowsArbitraryBoards => false;

	@override
	String get imageUrl => baseUrl;

	@override
	bool get supportsPosting => false;

	@override
	ImageboardBoardPopularityType? get boardPopularityType => null;

	@override
	Future<List<ImageboardBoard>> getBoards({required RequestPriority priority, CancelToken? cancelToken}) async {
		if (boards != null) {
			return boards!;
		}
		final response = await client.getUri(Uri.https(baseUrl, '/'), options: Options(
			responseType: ResponseType.plain,
			extra: {
				kPriority: priority
			}
		), cancelToken: cancelToken);
		final parsed = parseBoardList(response.data as String);
		if (parsed.isEmpty) {
			// The home page renders the list in a table; if a future version moves
			// it, an empty board list is better explained than silently empty.
			throw BoardNotFoundException('');
		}
		return parsed.map((board) => _makeBoard(board.name, board.title, board.isWorksafe)).toList(growable: false);
	}

	ImageboardBoard _makeBoard(String boardName, String title, bool isWorksafe) => ImageboardBoard(
		name: boardName,
		title: title,
		isWorksafe: isWorksafe,
		webmAudioAllowed: true,
		maxImageSizeBytes: maxUploadSizeBytes ?? kMB * 100,
		maxWebmSizeBytes: maxUploadSizeBytes ?? kMB * 100,
		maxCommentCharacters: 8192,
		filesPerPost: defaultFilesPerPost
	);

	Post _makePost(MinilautaPost post, {required String board, required int threadId}) => Post(
		board: board,
		text: post.message,
		name: post.name.isEmpty ? defaultUsername : post.name,
		time: post.time,
		threadId: threadId,
		id: post.id,
		parentId: post.parentId,
		spanFormat: PostSpanFormat.minilauta,
		trip: post.tripCode,
		capcode: post.capcode,
		posterId: post.posterId,
		email: post.email,
		attachments_: post.attachments.map((attachment) => _makeAttachment(attachment, board: board, threadId: threadId)).toList(growable: false)
	);

	Attachment _makeAttachment(MinilautaAttachment attachment, {required String board, required int threadId}) => Attachment(
		type: attachment.type,
		board: board,
		// The path is unique per uploaded file, and unlike a filename it is what
		// the page actually links to.
		id: attachment.url,
		ext: attachment.ext,
		filename: attachment.originalFilename?.nonEmptyOrNull ?? attachment.filename,
		url: Uri.https(baseUrl, attachment.url).toString(),
		thumbnailUrl: Uri.https(baseUrl, attachment.thumbnailUrl).toString(),
		md5: '',
		spoiler: attachment.spoiler,
		width: attachment.width,
		height: attachment.height,
		threadId: threadId,
		sizeInBytes: attachment.sizeInBytes
	);

	Thread _makeThread(MinilautaThread thread) {
		final posts = thread.posts.map((post) => _makePost(post, board: thread.board, threadId: thread.id)).toList(growable: false);
		final op = posts.first;
		return Thread(
			posts_: posts,
			replyCount: thread.replyCount,
			imageCount: posts.fold<int>(0, (count, post) => count + post.attachments.length) - op.attachments.length,
			id: thread.id,
			board: thread.board,
			title: thread.title,
			isSticky: false,
			time: op.time,
			attachments: op.attachments_,
			lastUpdatedTime: posts.last.time
		);
	}

	/// Catalog cards only carry a preview: the name, subject and up to 75
	/// characters of the body. The full-size attachment URL is not on the card
	/// either, so the OP's attachment points at the thumbnail until the thread is
	/// opened and the real file is known.
	Thread _makeCatalogThread(MinilautaCatalogEntry entry, {required int currentPage}) {
		final thumbnailUrl = entry.thumbnailUrl;
		final op = Post(
			board: entry.board,
			text: entry.message ?? '',
			name: entry.name.isEmpty ? defaultUsername : entry.name,
			time: DateTime.now(),
			threadId: entry.id,
			id: entry.id,
			spanFormat: PostSpanFormat.minilauta,
			attachments_: thumbnailUrl == null ? const [] : [
				Attachment(
					type: AttachmentType.image,
					board: entry.board,
					id: thumbnailUrl,
					ext: '',
					filename: thumbnailUrl.split('/').last,
					url: Uri.https(baseUrl, thumbnailUrl).toString(),
					thumbnailUrl: Uri.https(baseUrl, thumbnailUrl).toString(),
					md5: '',
					width: null,
					height: null,
					threadId: entry.id,
					sizeInBytes: null
				)
			]
		);
		return Thread(
			posts_: [op],
			replyCount: entry.replyCount ?? 0,
			imageCount: thumbnailUrl == null ? 0 : 1,
			id: entry.id,
			board: entry.board,
			title: entry.subject?.nonEmptyOrNull ?? (entry.message?.nonEmptyOrNull),
			isSticky: false,
			time: op.time,
			attachments: op.attachments_,
			currentPage: currentPage,
			lastUpdatedTime: op.time
		);
	}

	/// `/b/catalog/` for a board; the overboard catalog does not exist here.
	String _catalogPath(String board) => board.isEmpty ? '/catalog/' : '/$board/catalog/';

	Future<MinilautaCatalogPage> _fetchCatalogPage(String board, int page, {required RequestPriority priority, CancelToken? cancelToken}) async {
		final response = await client.getUri(
			Uri.https(baseUrl, _catalogPath(board), page == 0 ? null : {'page': page.toString()}),
			options: Options(
				responseType: ResponseType.plain,
				extra: {
					kPriority: priority
				}
			),
			cancelToken: cancelToken
		);
		final parsed = parseCatalog(response.data as String, board: board);
		// Page 0 is where a catalog fetch always starts, and miniboard spells the
		// current page as a bare `[0]` rather than a link, so the count is the
		// only thing worth keeping.
		_pageCounts[board] = parsed.page?.pageCount ?? 1;
		return parsed;
	}

	@override
	@protected
	Future<Catalog> getCatalogImpl(String board, {CatalogVariant? variant, required RequestPriority priority, CancelToken? cancelToken}) async {
		final parsed = await _fetchCatalogPage(board, 0, priority: priority, cancelToken: cancelToken);
		return Catalog.fromList(
			threads: parsed.threads.map((entry) => _makeCatalogThread(entry, currentPage: 0)).toList(growable: false),
			lastModified: null,
			fetchedTime: DateTime.now()
		);
	}

	@override
	@protected
	Future<List<Thread>> getMoreCatalogImpl(String board, Thread after, {CatalogVariant? variant, required RequestPriority priority, CancelToken? cancelToken}) async {
		final pageCount = _pageCounts[board];
		if (pageCount == null) {
			// No catalog has been fetched for this board yet, so there is no page
			// to continue from.
			return const [];
		}
		final nextPage = (after.currentPage ?? 0) + 1;
		if (nextPage >= pageCount) {
			return const [];
		}
		final parsed = await _fetchCatalogPage(board, nextPage, priority: priority, cancelToken: cancelToken);
		return parsed.threads.map((entry) => _makeCatalogThread(entry, currentPage: nextPage)).toList(growable: false);
	}

	@override
	@protected
	Future<Thread> getThreadImpl(ThreadIdentifier thread, {ThreadVariant? variant, required RequestPriority priority, CancelToken? cancelToken}) async {
		final response = await client.getThreadUri(
			Uri.https(baseUrl, '/${thread.board}/${thread.id}/'),
			priority: priority,
			responseType: ResponseType.plain,
			options: Options(
				extra: {
					kPriority: priority
				}
			),
			cancelToken: cancelToken
		);
		final parsed = parseThreadPage(response.data as String, board: thread.board, threadId: thread.id);
		if (parsed.thread.posts.isEmpty) {
			// The page rendered, but without the thread: miniboard answers 200 with
			// its "board with id ... cannot be found" page for a dead thread.
			throw const ThreadNotFoundException();
		}
		return _makeThread(parsed.thread);
	}

	@override
	Future<Post> getPostFromArchive(String board, int id, {required RequestPriority priority, CancelToken? cancelToken}) async {
		throw UnimplementedError('minilauta has no archive or post lookup endpoint');
	}

	/// miniboard validates an `h-captcha-response` on every post from a client
	/// that is not signed in, and the post form it serves to the logged-out
	/// reader embeds no captcha widget at all, so there is nothing to solve.
	/// Returning an empty request keeps "posting is unavailable" honest instead
	/// of offering a form that the server will always reject.
	@override
	Future<CaptchaRequest> getCaptchaRequest(String board, int? threadId, {CancelToken? cancelToken}) async => const NoCaptchaRequest();

	/// Not implemented, and [supportsPosting] is false for the same reason.
	///
	/// The form markup is known - `#form-post` posts multipart to `/b` for a new
	/// thread and `/b/<id>` for a reply, with `name`, `email`, `subject`,
	/// `message`, `file[]`, `anonfile`, `spoiler`, `embed`, `password` and a
	/// hidden per-session `csrf_token` that has to be echoed from a page fetched
	/// with the same `PHPSESSID` cookie - but `handle_postform` in miniboard's
	/// `src/modules/board/module.php` also calls `funcs_common_validate_captcha`,
	/// which rejects any request without a valid `h-captcha-response`. That,
	/// together with the CSRF token's session binding, could only be confirmed by
	/// actually posting, which this change does not do.
	@override
	Future<PostReceipt> submitPost(DraftPost post, CaptchaSolution captchaSolution, CancelToken cancelToken) async {
		throw PostFailedException('Posting is not implemented for $name: miniboard requires an hCaptcha response that the site never offers to a logged-out reader');
	}

	/// The thread page never shows new replies; the fragment endpoint is the only
	/// way to get posts after a known post id. It is what the site's own script
	/// polls every ten seconds on a thread page.
	@override
	Future<ThreadTail?> getThreadTail(Thread thread, DateTime lastModified, {ThreadVariant? variant, required RequestPriority priority, CancelToken? cancelToken}) async {
		final lastPostId = thread.posts_.tryLast?.id;
		if (lastPostId == null || thread.isArchived) {
			return null;
		}
		final response = await client.getUri(
			Uri.https(baseUrl, '/${thread.board}/${thread.id}/replies/', {'post_id_after': lastPostId.toString()}),
			options: Options(
				responseType: ResponseType.plain,
				extra: {
					kPriority: priority
				}
			),
			cancelToken: cancelToken
		);
		final fragment = parseReplyFragment(response.data as String, board: thread.board, threadId: thread.id);
		final posts = fragment.posts.where((post) => post.id > lastPostId).toList(growable: false);
		return ThreadTail(
			board: thread.board,
			id: thread.id,
			posts: posts.map((post) => _makePost(post, board: thread.board, threadId: thread.id)).toList(growable: false),
			imageCount: thread.imageCount + posts.fold<int>(0, (count, post) => count + post.attachments.length),
			replyCount: thread.replyCount + posts.length,
			isArchived: thread.isArchived,
			isLocked: thread.isLocked,
			isSticky: thread.isSticky,
			lastUpdatedTime: posts.isEmpty ? thread.lastUpdatedTime : posts.last.time
		);
	}

	@override
	String getWebUrlImpl(String board, [int? threadId, int? postId]) {
		if (board.isEmpty) {
			return 'https://$baseUrl/';
		}
		if (threadId == null) {
			return 'https://$baseUrl/$board/';
		}
		final url = 'https://$baseUrl/$board/$threadId/';
		return postId == null ? url : '$url#$board-$postId';
	}

	BoardThreadOrPostIdentifier? _decodeUrl(Uri url) {
		if (url.host != baseUrl) {
			return null;
		}
		final segments = url.pathSegments.where((segment) => segment.isNotEmpty).toList(growable: false);
		if (segments.isEmpty) {
			return null;
		}
		if (segments.length == 1) {
			return BoardThreadOrPostIdentifier(segments.first);
		}
		final threadId = int.tryParse(segments[1]);
		if (threadId == null) {
			return null;
		}
		// `#b-82695` is the post anchor, `#q82695` the quote anchor.
		final fragment = url.fragment;
		final postId = fragment.isEmpty
			? null
			: int.tryParse(RegExp(r'(\d+)$').firstMatch(fragment)?.group(1) ?? '');
		return BoardThreadOrPostIdentifier(segments.first, threadId, postId);
	}

	@override
	bool decodeUrlPossible(Uri url) => _decodeUrl(url) != null;

	@override
	Future<BoardThreadOrPostIdentifier?> decodeUrl(Uri url, {CancelToken? cancelToken}) async => _decodeUrl(url);

	@override
	List<ImageboardSnippet> getBoardSnippets(String board) => const [
		greentextSnippet
	];

	@override
	bool operator == (Object other) =>
		identical(this, other) ||
		other is SiteMinilauta &&
		other.baseUrl == baseUrl &&
		other.name == name &&
		other.defaultUsername == defaultUsername &&
		other.defaultFilesPerPost == defaultFilesPerPost &&
		other.maxUploadSizeBytes == maxUploadSizeBytes &&
		super == other;

	@override
	int get hashCode => baseUrl.hashCode;
}
