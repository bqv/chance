import 'package:chan/models/board.dart';
import 'package:chan/sites/imageboard_site.dart';
import 'package:chan/sites/lainchan2.dart';
import 'package:dio/dio.dart';
import 'package:html/parser.dart';

/// loistolauta.org runs vichan 5.1.4 unmodified, so this is lainchan's adapter
/// with only the things that actually differ: the board list comes from the
/// root page rather than /boards.json, the thumbnail extension has to be read
/// from the thread page, and the posting limits are the site's.
///
/// The engine answers `/board/catalog.json` and `/board/res/{id}.json` with the
/// same schema lainchan publishes, which is what makes the thread, catalog and
/// posting code in [SiteLainchan2] usable here unchanged - including the
/// `/post.php` form submission, whose field names are the engine's, not the
/// site's.
class SiteLoistolauta extends SiteLainchan2 {
	SiteLoistolauta({
		required super.baseUrl,
		required super.name,
		required super.imageUrl,
		required super.overrideUserAgent,
		required super.addIntrospectedHeaders,
		required super.preferHttp3WithoutAltSvc,
		required super.boardsWithHtmlOnlyFlags,
		required super.boardsWithMemeFlags,
		required super.archives,
		required super.imageHeaders,
		required super.videoHeaders,
		required super.additionalCookies,
		required super.turnstileSiteKey,
		super.maxUploadSizeBytes,
		super.filesPerPost = 4
	}) : super(
		basePath: '',
		// There is no /boards.json here, so the board list is scraped from the
		// root page (see [getBoards]); [SiteLainchanOrg]'s scraper cannot be
		// reused as-is because /ukko/ carries no title attribute and would be
		// silently dropped by its `title != null` filter.
		faviconPath: '/favicon.ico',
		defaultUsername: 'Anonyymi',
		formBypass: {},
		// The JSON payload never names a thumbnail, and `null` here means
		// SiteLainchan derives one per file from its own extension - which
		// vichan does not serve (every preview is `<tim>.jpg`, video included,
		// and a sound file gets a generic icon). So `makeThread` re-reads the
		// rendered thread page, which does name them, and corrects them.
		// lainchan2's short-circuit used to treat `null` as if it were a real
		// extension, so reaching that correction needed the guard fixed too.
		imageThumbnailExtension: null
	);

	@override
	Future<List<ImageboardBoard>> getBoards({required RequestPriority priority, CancelToken? cancelToken}) async {
		final response = await client.getUri(Uri.https(baseUrl, '/'), options: Options(
			responseType: ResponseType.plain,
			extra: {
				kPriority: priority
			},
			// Needed to allow multiple interception
			validateStatus: (_) => true
		), cancelToken: cancelToken);
		if (response.statusCode != 200) {
			throw HTTPStatusException.fromResponse(response);
		}
		return parse(response.data).querySelectorAll('.boardlist a').where((e) => (e.attributes['href'] ?? '').contains('/')).map((e) {
			// The hrefs are "/a/index.html", so the board is the first path
			// segment; the link text is just the letter.
			final name = e.attributes['href']!.split('/').where((s) => s.isNotEmpty).first;
			return ImageboardBoard(
				name: name,
				// /ukko/ publishes no title, so fall back to the board name
				// rather than dropping the board.
				title: e.attributes['title'] ?? name,
				// Boards publish no limits of their own - there is no JSON
				// board list at all - so the configured figure is the only one.
				maxWebmSizeBytes: maxUploadSizeBytes ?? 25000000,
				maxImageSizeBytes: maxUploadSizeBytes ?? 25000000,
				filesPerPost: filesPerPost,
				isWorksafe: false,
				webmAudioAllowed: true
			);
		}).toList();
	}

	@override
	String get siteType => 'loistolauta';

	@override
	bool operator ==(Object other) =>
		identical(this, other) ||
		(other is SiteLoistolauta) &&
		super==(other);

	@override
	int get hashCode => baseUrl.hashCode;
}
