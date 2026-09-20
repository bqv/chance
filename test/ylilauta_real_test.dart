import 'dart:io';

import 'package:chan/services/cloudflare.dart';
import 'package:chan/sites/imageboard_site.dart';
import 'package:chan/sites/personal_sites.dart';
import 'package:chan/sites/ylilauta_parser.dart';
import 'package:flutter_test/flutter_test.dart';

/// The parser run against threads fetched from the live site.
void main() {
	String f(String n) => File('test/ylilauta_fixtures/$n').readAsStringSync();

	for (final (file, slug) in [('live_29d9ot.html', '29d9ot'), ('live_29d9zi.html', '29d9zi')]) {
		test('parses the real thread $slug', () {
			final html = f(file);
			// A real thread page carries the thread, which is what makes the
			// challenge check treat it as normal.
			expect(html.contains('card thread'), isTrue);
			final thread = YlilautaParser.parseThreadBySlug(html,
				board: 'satunnainen', slug: slug, defaultUsername: 'Anonyymi', fetchedTime: DateTime.now());
			print('$slug: id=${thread.id} slug=${thread.urlSlug} posts=${thread.posts_.length} '
				'replies=${thread.replyCount} images=${thread.imageCount}');
			final withText = thread.posts_.where((p) => p.text.trim().isNotEmpty).length;
			final withQuotes = thread.posts_.where((p) => p.repliedToIds.isNotEmpty).length;
			final withFiles = thread.posts_.where((p) => p.attachments.isNotEmpty).length;
			print('$slug: text=$withText quotes=$withQuotes files=$withFiles');
			expect(thread.urlSlug, slug);
			// The fixture is a real page trimmed to its first posts, so the counts
			// are asserted as sane rather than exact.
			expect(thread.posts_.length, greaterThan(5));
			// replyCount is the page's own figure, which counts more than the
			// posts a trimmed fixture retains.
			expect(thread.replyCount, greaterThan(0));
			expect(thread.posts_.every((p) => p.text.trim().isNotEmpty || p.attachments.isNotEmpty), isTrue);
			expect(thread.posts_.any((p) => p.attachments.isNotEmpty), isTrue);
			expect(thread.posts_, isNotEmpty);
			expect(thread.posts_.map((p) => p.id).toSet().length, thread.posts_.length, reason: 'duplicate ids');
			// The starter is badged "OP" where every other poster gets a number.
			expect(thread.posts_.first.posterId, YlilautaParser.kOpPosterId);
			expect(thread.posts_.where((p) => p.posterId == YlilautaParser.kOpPosterId), isNotEmpty);
			expect(thread.posts_.where((p) => p.posterId != null && p.posterId != YlilautaParser.kOpPosterId).length, greaterThan(5));
		});
	}

	group('gateway detection', () {
		// ylilauta truncates a long thread title to 160 characters and ends it
		// with "...". The generic gateway heuristic reads a trailing ellipsis as
		// an unfinished Cloudflare interstitial, so a thread like this one was
		// never accepted as content: the headless attempt sat waiting, gave up,
		// and the authorization prompt opened showing the thread itself.
		final truncatedTitle = f('live_29d9l9_title.txt').trim();

		test('the captured title is truncated with an ellipsis', () {
			expect(truncatedTitle.length, 160);
			expect(truncatedTitle.endsWith('...'), isTrue);
		});

		test('the generic heuristic alone would read that title as a gateway', () {
			expect(CloudflareInterceptor.titleMatches(truncatedTitle), isTrue);
		});

		test('ylilauta opts out of the ellipsis rule', () {
			final site = makeSite(personalSites['ylilauta']!);
			expect(site.ellipsisTitleMeansGateway, isFalse);
			expect(CloudflareInterceptor.titleMatches(truncatedTitle,
				ellipsisMeansGateway: site.ellipsisTitleMeansGateway), isFalse);
		});

		test('opting out still recognises a real gateway title', () {
			// The interstitial is identified from its markup, not its title, so
			// dropping the ellipsis rule costs nothing - while a genuine
			// Cloudflare-style title is still caught.
			expect(CloudflareInterceptor.titleMatches('Beep boop?', ellipsisMeansGateway: false), isFalse);
			expect(CloudflareInterceptor.titleMatches('Just a moment...', ellipsisMeansGateway: false), isTrue);
		});
	});

	test('the numeric page is not a thread', () {
		final html = f('live_numeric.html');
		print('numeric page: has card thread=${html.contains('card thread')}');
		// It is a board listing served with a 404. It does contain `card thread`,
		// which is exactly why the challenge check cannot rely on markers alone,
		// and why it must not parse as the thread that was asked for.
		expect(() => YlilautaParser.parseThreadBySlug(html,
			board: 'satunnainen', slug: '136667796', defaultUsername: 'A', fetchedTime: DateTime.now()),
			throwsA(isA<ThreadNotFoundException>()));
	});
}
