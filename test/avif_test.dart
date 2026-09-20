import 'dart:typed_data';

import 'package:chan/services/avif.dart';
import 'package:flutter_avif_platform_interface/flutter_avif_platform_interface.dart' as avif_platform;
import 'package:flutter_test/flutter_test.dart';

/// Sniffing is the gate that decides whether an attachment goes through the
/// AVIF path at all, so it is worth pinning down, including what it must
/// refuse.
///
/// The native decoder cannot run here - it lives in the plugin's own dynamic
/// library - so [AvifDecoder.decodeToPng]'s surroundings (the frame guard, the
/// PNG encoding and the cache) are exercised against a stand-in for it. The
/// plugin's own decode is still verified on-device.
class _FakeAvifPlatform implements avif_platform.FlutterAvif {
	int initCalls = 0;
	int disposeCalls = 0;
	int frameWidth = 2;
	int frameHeight = 2;
	Object? initError;
	Uint8List frameData = Uint8List(16);

	void reset({int width = 2, int height = 2, Object? error}) {
		initCalls = 0;
		disposeCalls = 0;
		frameWidth = width;
		frameHeight = height;
		initError = error;
		frameData = Uint8List(width * height * 4);
	}

	@override
	Future<avif_platform.AvifInfo> initMemoryDecoder({required String key, required Uint8List avifBytes, dynamic hint}) async {
		initCalls++;
		if (initError case final error?) {
			throw error;
		}
		return avif_platform.AvifInfo(width: frameWidth, height: frameHeight, imageCount: 1, duration: 0);
	}

	@override
	Future<avif_platform.Frame> getNextFrame({required String key, dynamic hint}) async {
		return avif_platform.Frame(data: frameData, duration: 0, width: frameWidth, height: frameHeight);
	}

	@override
	Future<bool> disposeDecoder({required String key, dynamic hint}) async {
		disposeCalls++;
		return true;
	}

	@override
	dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('_FakeAvifPlatform.${invocation.memberName}');
}

void main() {
	Uint8List ftyp(String brand, {int pad = 4}) {
		final b = BytesBuilder();
		b.add([0, 0, 0, 24]); // box size
		b.add('ftyp'.codeUnits);
		b.add(brand.codeUnits);
		b.add(List.filled(pad, 0));
		return b.toBytes();
	}

	final platform = _FakeAvifPlatform();
	setUpAll(() {
		// Set once: `FlutterAvifPlatform.api` is a `late final` static, and the
		// plugin that normally sets it is not registered in a unit test.
		avif_platform.FlutterAvifPlatform.api = platform;
	});
	setUp(() => platform.reset());

	group('AVIF detection', () {
		test('recognises a still AVIF', () {
			expect(AvifDecoder.looksLikeAvif(ftyp('avif')), isTrue);
		});

		test('recognises an AVIF sequence', () {
			expect(AvifDecoder.looksLikeAvif(ftyp('avis')), isTrue);
		});

		test('rejects other ISO-BMFF brands', () {
			// mp4 is the same container, and a site serving AVIF serves plenty of it.
			expect(AvifDecoder.looksLikeAvif(ftyp('isom')), isFalse);
			expect(AvifDecoder.looksLikeAvif(ftyp('mp42')), isFalse);
			expect(AvifDecoder.looksLikeAvif(ftyp('heic')), isFalse);
		});

		test('rejects formats Flutter can already decode', () {
			expect(AvifDecoder.looksLikeAvif(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0, 0, 0, 0, 0])), isFalse, reason: 'jpeg');
			expect(AvifDecoder.looksLikeAvif(Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0])), isFalse, reason: 'png');
			expect(AvifDecoder.looksLikeAvif(Uint8List.fromList('RIFF....WEBP'.codeUnits)), isFalse, reason: 'webp');
		});

		test('rejects data too short to hold a brand', () {
			expect(AvifDecoder.looksLikeAvif(Uint8List(0)), isFalse);
			expect(AvifDecoder.looksLikeAvif(Uint8List.fromList([0, 0, 0, 24, 0x66, 0x74, 0x79])), isFalse);
			expect(AvifDecoder.looksLikeAvif(Uint8List(11)), isFalse);
		});

		test('rejects an AVIF header that stops before the brand is complete', () {
			// A real avif `ftyp` box cut off mid-brand: there is no fourth byte
			// to read, and guessing that a partial 'avi' is 'avif' would send
			// truncated bytes to the decoder.
			expect(AvifDecoder.looksLikeAvif(Uint8List.fromList([0, 0, 0, 24, 0x66, 0x74, 0x79, 0x70, 0x61, 0x76, 0x69])), isFalse);
		});

		test('requires the header exactly where ISO-BMFF puts it', () {
			// 'ftyp' somewhere else in the file is not a file header.
			expect(AvifDecoder.looksLikeAvif(Uint8List.fromList([0, 0, 0, 0, 0, 0, 0, 0, 0x66, 0x74, 0x79, 0x70, 0x61, 0x76, 0x69, 0x66])), isFalse);
		});
	});

	group('isoBmffBrand', () {
		test('reads the brand out of a real header', () {
			expect(AvifDecoder.isoBmffBrand(ftyp('avif')), 'avif');
			expect(AvifDecoder.isoBmffBrand(ftyp('isom')), 'isom');
		});

		test('reports no brand when there is no ISO-BMFF header', () {
			expect(AvifDecoder.isoBmffBrand(Uint8List(0)), isNull);
			expect(AvifDecoder.isoBmffBrand(Uint8List.fromList([0, 0, 0, 24, 0, 0, 0, 0, 0x61, 0x76, 0x69, 0x66])), isNull);
		});
	});

	// Each test uses bytes of a length no other test uses: the cache is static,
	// keyed by length and content, and shared for the whole run.
	group('decodeToPng', () {
		test('encodes the decoded frame as PNG', () async {
			final png = await AvifDecoder.decodeToPng(Uint8List.fromList(List.filled(24, 0x11)));
			expect(png, isNotEmpty);
			// The 8-byte PNG signature, not the frame's raw RGBA.
			expect(png.take(8).toList(), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
			expect(platform.initCalls, 1);
			expect(platform.disposeCalls, 1);
		});

		test('refuses a frame that decoded to nothing', () async {
			platform.reset(width: 0, height: 0);
			await expectLater(
				AvifDecoder.decodeToPng(Uint8List.fromList(List.filled(25, 0x22))),
				throwsA(isA<Exception>())
			);
			// The decoder is released even when the frame is unusable.
			expect(platform.disposeCalls, 1);
		});

		test('propagates a decoder refusal instead of returning an image', () async {
			platform.reset(error: Exception('not AVIF'));
			await expectLater(
				AvifDecoder.decodeToPng(Uint8List.fromList(List.filled(26, 0x33))),
				throwsA(isA<Exception>())
			);
		});

		test('decodes the same bytes once, then serves them from the cache', () async {
			final data = Uint8List.fromList(List.filled(27, 0x44));
			final first = await AvifDecoder.decodeToPng(data);
			final second = await AvifDecoder.decodeToPng(data);
			expect(platform.initCalls, 1);
			expect(second, same(first));
		});
	});
}
