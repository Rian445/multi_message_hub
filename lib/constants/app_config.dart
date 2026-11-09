import 'package:package_info_plus/package_info_plus.dart';

/// Central single source of truth for app metadata.
/// All UI screens, dialogs, and services reference this class.
class AppConfig {
  static const String appName = 'Multi-Message Hub';
  static const String developerName = 'RIAN ISLAM';
  static const String githubRepo = 'Rian445/multi_message_hub';

  /// Current app version.
  /// Automatically read from pubspec.yaml via PackageInfo at startup,
  /// with fallback to the default below.
  static String version = '0.0.2';
  static String buildNumber = '1';

  /// Initializes version dynamically from the Android platform metadata.
  static Future<void> init() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (info.version.isNotEmpty) {
        version = info.version;
      }
      if (info.buildNumber.isNotEmpty) {
        buildNumber = info.buildNumber;
      }
    } catch (_) {
      // Fallback to static version
    }
  }
}
