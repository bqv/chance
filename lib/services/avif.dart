import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_avif_platform_interface/flutter_avif_platform_interface.dart' as avif_platform;
import 'package:image/image.dart' as img;

/// AVIF decoding for sites that serve it.
///
/// Flutter's own image codecs cannot decode AVIF at all, so an AVIF attachment
/// fails to render with "could not decompress image" no matter how it is
/// fetched. Some sites serve every image - including the poster frames of their
/// videos - as AVIF, so without this their media is unusable even though the
/// files themselves download fine.
///
/// Decoding is done by the flutter_avif plugin, which ships prebuilt native
/// libraries for every Android ABI. The decoded frame is re-encoded as PNG and
/// handed back to Flutter's normal image pipeline, so callers need no special
/// handling.
///
/// Results are cached by content length and a cheap 64-bit hash of the bytes:
/// the same thumbnail is requested repeatedly while scrolling, and decoding is
/// comparatively expensive.
class AvifDecoder {
	AvifDecoder._();

	/// AVIF files are ISO-BMFF: a 4-byte box size, `ftyp`, then a brand. The
	/// brand is `avif` for still images and `avis` for sequences.
	static bool looksLikeAvif(Uint8List data) {
		final brand = isoBmffBrand(data);
		return brand == 'avif' || brand == 'avis';
	}

	/// The ISO-BMFF brand of [data], or null when it is not an ISO-BMFF file.
	///
	/// AVIF, HEIC and MP4 share this container, so the brand is what
	/// distinguishes them.
	static String? isoBmffBrand(Uint8List data) {
		if (data.length < 12) {
			return null;
		}
		if (data[4] != 0x66 || data[5] != 0x74 || data[6] != 0x79 || data[7] != 0x70) {
			// not "ftyp"
			return null;
		}
		return String.fromCharCodes(data.sublist(8, 12));
	}

	/// Logs what an undecodable image actually is, so the reason is visible in
	/// logcat rather than only as a failed decode in the framework.
	static void logUnrecognised(Uint8List data) {
		final head = data.take(32).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
		debugPrint('AVIF/undecodable image: len=${data.length} brand=${isoBmffBrand(data)} head=$head');
	}

	static final _cache = <int, Uint8List>{};
	static const _maxCacheEntries = 48;

	/// Decodes AVIF bytes to PNG bytes.
	///
	/// Throws if the data is not decodable AVIF; callers should let that
	/// propagate, since the alternative is the same failure one step later with
	/// a less useful message.
	static Future<Uint8List> decodeToPng(Uint8List data) async {
		final key = Object.hash(data.length, _hash64(data));
		if (_cache[key] case final cached?) {
			return cached;
		}
		final png = await _decode(data);
		_cache[key] = png;
		while (_cache.length > _maxCacheEntries) {
			_cache.remove(_cache.keys.first);
		}
		return png;
	}

	static Future<Uint8List> _decode(Uint8List data) async {
		final api = avif_platform.FlutterAvifPlatform.api;
		final key = 'chan-avif-${identityHashCode(data)}';
		try {
			await api.initMemoryDecoder(key: key, avifBytes: data);
			final frame = await api.getNextFrame(key: key);
			if (frame.width <= 0 || frame.height <= 0) {
				throw Exception('AVIF decoded to ${frame.width}x${frame.height}');
			}
			// The plugin hands back raw RGBA, which is what the image package's
			// fromBytes expects for a four-channel image.
			final image = img.Image.fromBytes(
				width: frame.width,
				height: frame.height,
				bytes: frame.data.buffer,
				numChannels: 4
			);
			final encoded = img.encodePng(image);
			return Uint8List.fromList(encoded);
		}
		finally {
			// Frames are copied above, so the native decoder can be released.
			await Future.sync(() => api.disposeDecoder(key: key)).catchError((_) => false);
		}
	}

	static int _hash64(Uint8List data) {
		// Cheap FNV-1a over a sample of the data: this only has to distinguish
		// cache entries, not be collision-proof.
		var hash = 0xcbf29ce484222325;
		final step = data.length > 4096 ? data.length ~/ 4096 : 1;
		for (var i = 0; i < data.length; i += step) {
			hash = (hash ^ data[i]) * 0x100000001b3;
			hash &= 0xFFFFFFFFFFFFFFFF;
		}
		return hash;
	}

	/// Decodes AVIF to a [ui.Image], for callers that want one directly.
	static Future<ui.Image> decodeToImage(Uint8List data) async {
		final png = await decodeToPng(data);
		final codec = await ui.instantiateImageCodec(png);
		final frame = await codec.getNextFrame();
		return frame.image;
	}
}
