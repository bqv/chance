import 'dart:async';

import 'package:chan/services/outbox.dart';
import 'package:test/test.dart';

void main() {
	group('outbox retry scheduling', () {
		test('a negative duration Timer fires immediately', () async {
			// This is why outboxWakeupDelay() clamps: a negative delay is not
			// "never", it is "right now", so a wakeup time in the past used to
			// retry a failed post over and over in a tight loop.
			final stopwatch = Stopwatch()..start();
			final fired = Completer<void>();
			Timer(const Duration(minutes: -4), fired.complete);
			await fired.future;
			stopwatch.stop();
			expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
		});

		test('a wakeup time in the past yields a non-negative delay', () {
			final now = DateTime(2024);
			// The bug: a failed submission leaves allowedTime in the past, and
			// allowedTime is what gets added to nextWakeups.
			expect(
				outboxWakeupDelay([now.subtract(const Duration(minutes: 4))], now),
				Duration.zero
			);
			expect(
				outboxWakeupDelay([
					now.add(const Duration(minutes: 2)),
					now.subtract(const Duration(seconds: 1))
				], now),
				Duration.zero
			);
		});

		test('uses the earliest future wakeup', () {
			final now = DateTime(2024);
			expect(
				outboxWakeupDelay([
					now.add(const Duration(minutes: 2)),
					now.add(const Duration(seconds: 30)),
					now.add(const Duration(minutes: 1))
				], now),
				const Duration(seconds: 30)
			);
		});

		test('failed submissions back off, growing and then capped', () {
			// Nothing failed yet: no backoff
			expect(outboxRetryBackoff(0), Duration.zero);
			expect(outboxRetryBackoff(-1), Duration.zero);
			// First failure waits a few seconds, not zero (which would be an
			// immediate retry, i.e. the hot loop)
			final first = outboxRetryBackoff(1);
			expect(first, greaterThan(Duration.zero));
			expect(first, lessThanOrEqualTo(const Duration(seconds: 30)));
			var previous = Duration.zero;
			for (var failures = 1; failures <= 50; failures++) {
				final delay = outboxRetryBackoff(failures);
				expect(delay, greaterThanOrEqualTo(previous), reason: 'backoff must not shrink as failures accumulate');
				expect(delay, lessThanOrEqualTo(const Duration(minutes: 5)), reason: 'backoff must be capped');
				previous = delay;
			}
			// Reaches the cap and stays there
			expect(outboxRetryBackoff(50), greaterThan(outboxRetryBackoff(1)));
			expect(outboxRetryBackoff(50), outboxRetryBackoff(51));
		});
	});
}
