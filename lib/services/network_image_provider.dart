import 'dart:async';
import 'dart:typed_data';

import 'package:chan/services/avif.dart';
import 'package:chan/services/cloudflare.dart';
import 'package:chan/services/cookies.dart';
import 'package:chan/services/settings.dart';
import 'package:chan/sites/imageboard_site.dart';
import 'package:dio/dio.dart';
import 'package:extended_image_library/extended_image_library_io.dart';
import 'package:flutter/widgets.dart';

class CNetworkImageProvider extends ExtendedNetworkImageProvider {
	final Dio? client;
	final RequestPriority priority;
	final String extraCookie;
	final VoidCallback? afterFirstLoad;

  CNetworkImageProvider(super.url, {
		required this.client,
		super.cache,
		super.headers,
		this.extraCookie = '',
		this.afterFirstLoad,
		this.priority = RequestPriority.cosmetic
	});

	@override
	void didWriteCache() {
		super.didWriteCache();
		afterFirstLoad?.call();
	}

	@override
	Future<Uint8List?> loadNetwork(
		ExtendedNetworkImageProvider key,
    StreamController<ImageChunkEvent>? chunkEvents,
	) async {
		final client = (this.client ?? Settings.instance.client);
		final resolved = Uri.base.resolve(key.url);
		final response = await client.getUri(resolved, options: Options(
			responseType: ResponseType.bytes,
			headers: headers,
			extra: {
				kExtraCookie: extraCookie,
				kPriority: priority,
				kRetryIfCloudflare: true
			}
		), onReceiveProgress: chunkEvents == null ? null : (count, total) {
			chunkEvents.add(ImageChunkEvent(
				cumulativeBytesLoaded: count,
				expectedTotalBytes: total > 0 ? total : null
			));
		});
		final bytes = response.data as List<int>;
		if (bytes.isEmpty) {
			throw StateError('NetworkImage is empty file: $resolved');
		}
		final data = Uint8List.fromList(bytes);
		// Flutter cannot decode AVIF, and some sites serve all of their media
		// that way. Converting here covers every path: these bytes
		// are what reaches instantiateImageCodec, and they are also what the
		// disk cache stores, so later loads read back the converted form.
		if (AvifDecoder.looksLikeAvif(data)) {
			return await AvifDecoder.decodeToPng(data);
		}
		if (AvifDecoder.isoBmffBrand(data) case final brand? when brand != 'avif' && brand != 'avis') {
			// An ISO-BMFF file that is not AVIF: Flutter may still fail on it,
			// so record what it actually is.
			AvifDecoder.logUnrecognised(data);
		}
		return data;
	}

	@override
	bool operator == (Object other) =>
		identical(this, other) ||
	 	other is CNetworkImageProvider &&
		other.client == client &&
		other.url == url &&
		other.cache == cache;
	
	@override
	int get hashCode => Object.hash(client, url, cache);
}