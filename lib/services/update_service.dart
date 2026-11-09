import 'dart:convert';
import 'dart:io';
import 'profile_manager_channel.dart';

class UpdateCheckResult {
  final bool hasUpdate;
  final bool isUpToDate;
  final bool hasError;
  final String? errorMessage;
  final String currentVersion;
  final String latestVersion;
  final String? releaseTitle;
  final String? releaseNotes;
  final String? releaseUrl;
  final String? apkDownloadUrl;
  final int? apkSizeBytes;
  final DateTime? publishedAt;

  const UpdateCheckResult({
    required this.hasUpdate,
    required this.isUpToDate,
    this.hasError = false,
    this.errorMessage,
    required this.currentVersion,
    required this.latestVersion,
    this.releaseTitle,
    this.releaseNotes,
    this.releaseUrl,
    this.apkDownloadUrl,
    this.apkSizeBytes,
    this.publishedAt,
  });

  String get formattedApkSize {
    if (apkSizeBytes == null || apkSizeBytes! <= 0) return '';
    final mb = apkSizeBytes! / (1024 * 1024);
    return '${mb.toStringAsFixed(1)} MB';
  }
}

class UpdateService {
  static const String currentAppVersion = '0.0.2';
  static const String githubRepo = 'Rian445/multi_message_hub';
  static const String githubReleasesApi =
      'https://api.github.com/repos/$githubRepo/releases/latest';
  static const String githubReleasesWebUrl =
      'https://github.com/$githubRepo/releases';

  /// Compare two semver strings: e.g. "v1.0.1" vs "1.0.0"
  static bool isVersionNewer(String remoteTag, String currentVersion) {
    String cleanRemote = remoteTag.trim().toLowerCase();
    if (cleanRemote.startsWith('v')) {
      cleanRemote = cleanRemote.substring(1);
    }
    String cleanCurrent = currentVersion.trim().toLowerCase();
    if (cleanCurrent.startsWith('v')) {
      cleanCurrent = cleanCurrent.substring(1);
    }

    // Strip build numbers like "+1" or prerelease tags
    cleanRemote = cleanRemote.split('+')[0].split('-')[0];
    cleanCurrent = cleanCurrent.split('+')[0].split('-')[0];

    final remoteParts =
        cleanRemote.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final currentParts =
        cleanCurrent.split('.').map((e) => int.tryParse(e) ?? 0).toList();

    while (remoteParts.length < 3) {
      remoteParts.add(0);
    }
    while (currentParts.length < 3) {
      currentParts.add(0);
    }

    for (int i = 0; i < 3; i++) {
      if (remoteParts[i] > currentParts[i]) return true;
      if (remoteParts[i] < currentParts[i]) return false;
    }
    return false;
  }

  /// Checks GitHub Releases API for the latest release
  static Future<UpdateCheckResult> checkForUpdates() async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 10);

    try {
      final uri = Uri.parse(githubReleasesApi);
      final request = await client.getUrl(uri);
      request.headers.set('User-Agent', 'Multi-Message-Hub-App');
      request.headers.set('Accept', 'application/vnd.github.v3+json');

      final response =
          await request.close().timeout(const Duration(seconds: 12));

      if (response.statusCode == 200) {
        final responseBody = await response.transform(utf8.decoder).join();
        final Map<String, dynamic> data =
            json.decode(responseBody) as Map<String, dynamic>;

        final String tagName = (data['tag_name'] as String? ?? '').trim();
        final String releaseTitle =
            (data['name'] as String? ?? tagName).trim();
        final String releaseNotes =
            (data['body'] as String? ?? 'No release notes provided.').trim();
        final String htmlUrl =
            data['html_url'] as String? ?? githubReleasesWebUrl;
        final publishedStr = data['published_at'] as String?;
        final publishedAt =
            publishedStr != null ? DateTime.tryParse(publishedStr) : null;

        // Find APK in assets
        String? apkDownloadUrl;
        int? apkSizeBytes;

        final assets = data['assets'] as List<dynamic>?;
        if (assets != null) {
          for (final asset in assets) {
            final name = (asset['name'] as String? ?? '').toLowerCase();
            if (name.endsWith('.apk')) {
              apkDownloadUrl = asset['browser_download_url'] as String?;
              apkSizeBytes = (asset['size'] as num?)?.toInt();
              break;
            }
          }
        }

        // If no direct APK asset found, default download link to the release web page
        apkDownloadUrl ??= htmlUrl;

        final bool hasNewer = isVersionNewer(tagName, currentAppVersion);

        return UpdateCheckResult(
          hasUpdate: hasNewer,
          isUpToDate: !hasNewer,
          currentVersion: currentAppVersion,
          latestVersion:
              tagName.startsWith('v') ? tagName.substring(1) : tagName,
          releaseTitle: releaseTitle,
          releaseNotes: releaseNotes,
          releaseUrl: htmlUrl,
          apkDownloadUrl: apkDownloadUrl,
          apkSizeBytes: apkSizeBytes,
          publishedAt: publishedAt,
        );
      } else if (response.statusCode == 404) {
        // No release has been published on GitHub yet
        return const UpdateCheckResult(
          hasUpdate: false,
          isUpToDate: true,
          currentVersion: currentAppVersion,
          latestVersion: currentAppVersion,
          releaseTitle: 'Current Version',
          releaseNotes:
              'No newer releases have been published on GitHub yet.',
          releaseUrl: githubReleasesWebUrl,
        );
      } else {
        return UpdateCheckResult(
          hasUpdate: false,
          isUpToDate: false,
          hasError: true,
          errorMessage:
              'GitHub returned status ${response.statusCode}. Please try again later.',
          currentVersion: currentAppVersion,
          latestVersion: currentAppVersion,
        );
      }
    } on SocketException {
      return const UpdateCheckResult(
        hasUpdate: false,
        isUpToDate: false,
        hasError: true,
        errorMessage:
            'No internet connection. Please check your network and try again.',
        currentVersion: currentAppVersion,
        latestVersion: currentAppVersion,
      );
    } catch (e) {
      return UpdateCheckResult(
        hasUpdate: false,
        isUpToDate: false,
        hasError: true,
        errorMessage: 'Failed to check for updates: $e',
        currentVersion: currentAppVersion,
        latestVersion: currentAppVersion,
      );
    } finally {
      client.close();
    }
  }

  /// Downloads the APK with progress streaming
  static Future<String?> downloadApk({
    required String downloadUrl,
    required String destinationPath,
    required void Function(int receivedBytes, int totalBytes, double percent)
        onProgress,
    bool Function()? isCancelled,
  }) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.getUrl(Uri.parse(downloadUrl));
      request.headers.set('User-Agent', 'Multi-Message-Hub-App');
      final response = await request.close();

      if (response.statusCode != 200) {
        throw Exception(
            'Server responded with HTTP ${response.statusCode}');
      }

      final totalBytes = response.contentLength;
      int receivedBytes = 0;

      final file = File(destinationPath);
      // Ensure parent directory exists
      if (!await file.parent.exists()) {
        await file.parent.create(recursive: true);
      }
      final sink = file.openWrite();

      await for (final chunk in response) {
        if (isCancelled?.call() == true) {
          await sink.close();
          if (await file.exists()) {
            await file.delete();
          }
          return null;
        }

        sink.add(chunk);
        receivedBytes += chunk.length;
        final percent = totalBytes > 0
            ? (receivedBytes / totalBytes).clamp(0.0, 1.0)
            : 0.0;
        onProgress(receivedBytes, totalBytes, percent);
      }

      await sink.flush();
      await sink.close();
      return destinationPath;
    } finally {
      client.close();
    }
  }

  /// Automatically deletes old downloaded update APKs from the cache
  /// to reclaim device storage.
  static Future<void> cleanCachedApk() async {
    try {
      String? cachePath = await ProfileManagerChannel.getAppCacheDir();
      cachePath ??= Directory.systemTemp.path;
      final apkFile = File('$cachePath/multi_message_hub_update.apk');
      if (await apkFile.exists()) {
        await apkFile.delete();
      }
    } catch (_) {
      // Ignore cleanup errors
    }
  }
}
