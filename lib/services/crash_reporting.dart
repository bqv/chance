import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';

/// Thin wrapper over crash reporting that tolerates Firebase being unavailable.
///
/// Chance reports crashes through Firebase Crashlytics, but Crashlytics is
/// optional: it is developer-facing telemetry, and nothing else in the app
/// depends on Firebase (push notifications are handled by UnifiedPush). A build
/// that omits the Firebase Gradle plugins — which also removes the requirement
/// for a `google-services.json` matching the application id — must still run,
/// so every call site goes through here instead of touching Crashlytics
/// directly.
///
/// [initialize] catches failures, leaving [_handler] null, and every reporting
/// method becomes a no-op. This also keeps the original behaviour intact: when
/// Firebase is present the handler is installed exactly as before.
class CrashReporting {
	CrashReporting._();

	static void Function(Object error, StackTrace stackTrace, {List<String> information, bool fatal})? _handler;
	static void Function(FlutterErrorDetails details)? _flutterErrorHandler;

	/// Whether crash data is currently being collected.
	///
	/// Firebase owns this state when it is present; it is remembered locally
	/// otherwise so the setting still reads back what the user chose.
	static bool _collectionEnabled = true;

	static bool get collectionEnabled => _handler == null
		? _collectionEnabled
		: FirebaseCrashlytics.instance.isCrashlyticsCollectionEnabled;

	static set collectionEnabled(bool value) {
		_collectionEnabled = value;
		_handler == null
			? null
			: FirebaseCrashlytics.instance.setCrashlyticsCollectionEnabled(value);
	}

	/// Starts crash reporting if Firebase is available. Never throws.
	static Future<void> initialize({required FirebaseOptions options}) async {
		try {
			await Firebase.initializeApp(options: options);
			final crashlytics = FirebaseCrashlytics.instance;
			_flutterErrorHandler = crashlytics.recordFlutterFatalError;
			_handler = (error, stackTrace, {information = const [], fatal = false}) => crashlytics.recordError(
				error,
				stackTrace,
				information: information,
				fatal: fatal
			);
		}
		catch (e, st) {
			// Firebase is not configured in this build; run without it.
			debugPrint('Crash reporting unavailable, continuing without it: $e');
			debugPrint('$st');
		}
	}

	/// Installs the Flutter error handler, if crash reporting is available.
	static void installFlutterErrorHandler() {
		if (_flutterErrorHandler case final handler?) {
			FlutterError.onError = handler;
		}
	}

	static void recordError(Object error, StackTrace stackTrace, {List<String> information = const [], bool fatal = false}) {
		_handler?.call(error, stackTrace, information: information, fatal: fatal);
	}
}
