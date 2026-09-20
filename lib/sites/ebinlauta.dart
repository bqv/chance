import 'package:chan/models/board.dart';
import 'package:chan/models/thread.dart';
import 'package:chan/services/persistence.dart';
import 'package:chan/sites/ebinlauta_parser.dart';
import 'package:chan/sites/helpers/http_304.dart';
import 'package:chan/sites/imageboard_site.dart';
import 'package:chan/sites/lainchan.dart';
import 'package:chan/sites/util.dart';
import 'package:chan/util.dart';
import 'package:chan/widgets/post_spans.dart';
import 'package:dio/dio.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart';

/// ebinlauta.net, running the site's own ebinboard engine over plain HTTP.
///
/// Unlike the app's ylilauta support this needs no browser: the pages answer
/// ordinary requests, so every read here is an HTML parse (see
/// [EbinlautaParser] for the markup rules).
///
/// Reading is all this site does. The site's rules state that automated posting
/// is prohibited ("Automatisoitujen bottiviestien lähettäminen on kielletty"),
/// and while the form and the engine's own code show no captcha or token, the
/// session requirement and the reply contract have not been verified by
/// posting. [supportsPosting] is therefore false rather than guessing.
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

	/// No captcha is rendered anywhere on the site, and posting is not
	/// implemented, so nothing ever asks for one.
	@override
	Future<CaptchaRequest> getCaptchaRequest(String board, int? threadId, {CancelToken? cancelToken}) async => const NoCaptchaRequest();

	@override
	Future<PostReceipt> submitPost(DraftPost post, CaptchaSolution captchaSolution, CancelToken cancelToken) async {
		throw UnimplementedError('ebinlauta posting is not implemented');
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
	bool get supportsPosting => false;

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
