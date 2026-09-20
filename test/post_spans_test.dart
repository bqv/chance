import 'package:chan/models/post.dart';
import 'package:chan/models/thread.dart';
import 'package:chan/services/imageboard.dart';
import 'package:chan/services/persistence.dart';
import 'package:chan/services/settings.dart';
import 'package:chan/sites/imageboard_site.dart';
import 'package:chan/widgets/post_spans.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Casting an upvote replaces the post object rather than mutating it, so the
/// row that was built with the old object has to look the new one up in the
/// zone. `didReplacePosts` is what publishes the replacement there; without it
/// the row keeps showing the count it was built with until the whole thread is
/// refetched. These tests pin both halves: the zone lookup, and the row that
/// reads through it.

class _FakeSite extends ImageboardSite {
	@override
	String get baseUrl => 'test.example';

	@override
	String get imageUrl => 'i.test.example';

	@override
	String get defaultUsername => 'Anonymous';

	@override
	bool get supportsPostUpvotes => true;

	_FakeSite() : super(
		archives: const [],
		imageHeaders: const {},
		videoHeaders: const {},
		overrideUserAgent: null,
		addIntrospectedHeaders: false,
		preferHttp3WithoutAltSvc: null
	);

	@override
	dynamic noSuchMethod(Invocation invocation) {
		throw UnimplementedError('_FakeSite.${invocation.memberName}');
	}
}

class _FakeImageboard extends Imageboard {
	@override
	final ImageboardSite site;

	final Persistence _persistence = Persistence('post_spans_test');

	@override
	Persistence get persistence => _persistence;

	_FakeImageboard({required this.site}) : super(key: 'post_spans_test', siteData: const {});
}

class _FakeContext implements BuildContext {
	@override
	bool get mounted => true;

	@override
	dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('_FakeContext.${invocation.memberName}');
}

Post _post({
	required int id,
	required int threadId,
	int? upvotes,
	bool? upvoted,
	int? parentId
}) => Post(
	board: 'test',
	text: 'body of $id',
	name: 'Anonymous',
	time: DateTime(2026, 1, 1),
	threadId: threadId,
	id: id,
	spanFormat: PostSpanFormat.chan4,
	attachments_: const [],
	upvotes: upvotes,
	upvoted: upvoted,
	parentId: parentId
);

Thread _thread() => Thread(
	posts_: [
		_post(id: 1, threadId: 1),
		_post(id: 2, threadId: 1, upvotes: 5, upvoted: false)
	],
	replyCount: 1,
	imageCount: 0,
	id: 1,
	board: 'test',
	title: null,
	isSticky: false,
	time: DateTime(2026, 1, 1),
	attachments: const []
);

({Thread thread, PostSpanRootZoneData zone, Post original}) _zoneWithVotableThread() {
	final thread = _thread();
	final zone = PostSpanRootZoneData(
		thread: thread,
		imageboard: _FakeImageboard(site: _FakeSite()),
		style: PostSpanZoneStyle.linear
	);
	return (thread: thread, zone: zone, original: thread.posts_[1]);
}

/// Every text run the row renders, however deeply nested.
Iterable<String> _texts(InlineSpan span) sync* {
	if (span is! TextSpan) {
		return;
	}
	if (span.text case final text?) {
		yield text;
	}
	for (final child in span.children ?? const <InlineSpan>[]) {
		yield* _texts(child);
	}
}

void main() {
	setUpAll(() async {
		await Persistence.initializeForTesting();
	});

	final theme = SavedTheme(
		backgroundColor: const Color(0xFF000000),
		barColor: const Color(0xFF111111),
		primaryColor: const Color(0xFFFFFFFF),
		secondaryColor: const Color(0xFF00FF00)
	);

	group('didReplacePosts', () {
		test('refreshes the zone lookup to the replacement object', () {
			final (:thread, :zone, :original) = _zoneWithVotableThread();
			expect(zone.findPost(2), same(original));

			// What a vote leaves behind: a new post object in the thread, and
			// the old one still what the zone knows.
			final replacement = original.copyWith(upvotes: 6, upvoted: true);
			expect(identical(replacement, original), isFalse);
			thread.posts_[1] = replacement;
			expect(zone.findPost(2), same(original),
				reason: 'the zone must not guess before it is told');

			zone.didReplacePosts(thread);

			expect(zone.findPost(2), same(replacement));
			expect(zone.findPost(2)!.upvotes, 6);
			expect(zone.findPost(2)!.upvoted, isTrue);
			// Posts the thread did not replace keep the objects they had.
			expect(zone.findPost(1), same(thread.posts_[0]));
		});

		test('leaves a post the thread no longer holds alone', () {
			final (:thread, :zone, :original) = _zoneWithVotableThread();
			// A refresh that drops a post must not erase what the zone still
			// holds for it: the replacement is an overwrite, not a rebuild.
			thread.posts_.removeAt(1);
			zone.didReplacePosts(thread);
			expect(zone.findPost(2), same(original));
		});
	});

	group('upvote row', () {
		test('reads the count from the zone, not from the object it was built with', () {
			final (:thread, :zone, :original) = _zoneWithVotableThread();

			TextSpan rowFor(Post post) => buildPostInfoRow(
				post: post,
				isYourPost: false,
				settings: Settings.instance,
				theme: theme,
				context: _FakeContext(),
				zone: zone,
				interactive: false
			);

			// The row is handed the stale object, exactly as a widget built
			// before the vote would have been.
			expect(_texts(rowFor(original)), contains('5 '));

			final replacement = original.copyWith(upvotes: 6, upvoted: true);
			thread.posts_[1] = replacement;
			zone.didReplacePosts(thread);

			// The object the row holds is unchanged, so the only way the count
			// can change is through the zone.
			expect(_texts(rowFor(original)), contains('6 '));
			expect(_texts(rowFor(original)), isNot(contains('5 ')));
			// And it still renders the old count for a post the zone does not
			// know, so the lookup is a fallback rather than a requirement.
			expect(_texts(rowFor(_post(id: 99, threadId: 1, upvotes: 5))), contains('5 '));
		});
	});
}
