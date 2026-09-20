import 'dart:io';

import 'package:chan/sites/ylilauta_parser.dart';
import 'package:flutter_test/flutter_test.dart';

/// Ad-hoc verification against real pages captured from the live site.
void main() {
	String f(String n) => File('test/ylilauta_fixtures/$n').readAsStringSync();

	test('parses the live board page', () {
		final catalog = YlilautaParser.parseCatalog(f('live_board.html'),
			board: 'rikokset', defaultUsername: 'Anonyymi', fetchedTime: DateTime.now());
		print('LIVE board: ${catalog.threads.length} threads');
		final withSlug = catalog.threads.values.where((t) => t.urlSlug != null).length;
		print('LIVE board: $withSlug have a slug, ${catalog.threads.length - withSlug} without');
		for (final t in catalog.threads.values.take(3)) {
			print('  id=${t.id} slug=${t.urlSlug} opId=${t.posts_.single.id} replies=${t.replyCount}');
		}
		expect(catalog.threads, isNotEmpty);
	});

	test('parses the live load-more fragment', () {
		// Captured from POST /api/community/board/load-threads on the live site.
		final more = YlilautaParser.parseMoreThreads(f('live_more.html'),
			board: 'rikokset', defaultUsername: 'Anonyymi', fetchedTime: DateTime.now());
		print('LIVE more: ${more.length} additional threads');
		expect(more, isNotEmpty);
		for (final t in more.take(3)) {
			print('  id=${t.id} slug=${t.urlSlug} replies=${t.replyCount} title=${t.posts_.first.text.substring(0, t.posts_.first.text.length.clamp(0, 40)).replaceAll('\n', ' ')}');
		}
		// The batch must not overlap the first page.
		final first = YlilautaParser.parseCatalog(f('live_board.html'),
			board: 'rikokset', defaultUsername: 'Anonyymi', fetchedTime: DateTime.now());
		final overlap = more.map((t) => t.id).toSet().intersection(first.threads.keys.toSet());
		print('LIVE more: overlap with page 1 = ${overlap.length}');
		expect(overlap, isEmpty);
	});

	test('parses the live thread page', () {
		final t = YlilautaParser.parseThread(f('live_thread.html'),
			board: 'rikokset', threadId: 135614236, defaultUsername: 'Anonyymi', urlSlug: '28qom4',
			fetchedTime: DateTime.now());
		final ids = t.posts_.map((p) => p.id).toList();
		print('LIVE thread: id=${t.id} slug=${t.urlSlug} posts=${t.posts_.length} uniqueIds=${ids.toSet().length}');
		print('LIVE thread: replyCount=${t.replyCount} images=${t.imageCount} attachments=${t.posts_.expand((p) => p.attachments).length}');
		final withText = t.posts_.where((p) => p.text.trim().isNotEmpty).length;
		print('LIVE thread: $withText/${t.posts_.length} posts have text');
		final withQuotes = t.posts_.where((p) => p.repliedToIds.isNotEmpty).length;
		print('LIVE thread: $withQuotes posts resolve quote links');
		final withPoster = t.posts_.where((p) => p.posterId != null).length;
		print('LIVE thread: $withPoster posts have a poster id');
		print('LIVE thread: first time ${t.posts_.first.time}');
		expect(t.posts_, isNotEmpty);
		// The fixture is a real page trimmed to its first posts.
		expect(t.posts_, hasLength(25));
		expect(t.posts_.map((p) => p.id).toSet().length, t.posts_.length, reason: 'duplicate post ids');
		for (final p in t.posts_) {
			expect(p.threadId, t.id);
		}
	});
}
