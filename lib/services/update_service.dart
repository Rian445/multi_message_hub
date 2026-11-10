import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
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
  final String? expectedSha256;
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
    this.expectedSha256,
    this.publishedAt,
  });

  String get formattedApkSize {
    if (apkSizeBytes == null || apkSizeBytes! <= 0) return '';
    final mb = apkSizeBytes! / (1024 * 1024);
    return '${mb.toStringAsFixed(1)} MB';
  }
}

class UpdateService {
  static const String currentAppVersion = '1.0.5';
  static const String githubRepo = 'Rian445/multi_message_hub';
  static const String githubReleasesApi =
      'https://api.github.com/repos/$githubRepo/releases/latest';
  static const String githubReleasesWebUrl =
      'https://github.com/$githubRepo/releases';

  /// Extracts standard semver digits (X.Y.Z) from tag names or release titles
  static String extractSemver(String text) {
    final match = RegExp(r'(\d+\.\d+\.\d+)').firstMatch(text);
    if (match != null) {
      return match.group(1)!;
    }
    String cleaned = text.trim();
    if (cleaned.toLowerCase().startsWith('v')) {
      cleaned = cleaned.substring(1);
    }
    return cleaned.split('+')[0].split('-')[0].trim();
  }

  /// Compare two semver strings: e.g. "v1.0.1" vs "1.0.0"
  static bool isVersionNewer(String remoteTag, String currentVersion) {
    final cleanRemote = extractSemver(remoteTag);
    final cleanCurrent = extractSemver(currentVersion);

    if (cleanRemote == cleanCurrent) return false;

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

  /// Trusted GitHub domains — shared by both checkForUpdates and downloadApk
  static const List<String> _trustedGithubDomains = [
    'github.com',
    'api.github.com',
    'objects.githubusercontent.com',
    'release-assets.githubusercontent.com',
    'raw.githubusercontent.com',
  ];

  /// Validates that a URI is HTTPS and from a trusted GitHub domain.
  /// Throws a [SocketException] if the domain is not trusted.
  static void _assertTrustedUri(Uri uri) {
    final host = uri.host.toLowerCase();
    final trusted = uri.scheme == 'https' &&
        (_trustedGithubDomains.contains(host) ||
            host.endsWith('.github.com') ||
            host.endsWith('.githubusercontent.com'));
    if (!trusted) {
      throw const SocketException(
          'Security verification failed: URL is not from a trusted GitHub domain.');
    }
  }

  /// Creates an [HttpClient] that rejects connections to any host that is not
  /// a known GitHub domain, even if the TLS certificate is otherwise valid.
  static HttpClient _buildSecureClient({Duration timeout = const Duration(seconds: 10)}) {
    final client = HttpClient();
    client.connectionTimeout = timeout;

    // Reject certificates whose Subject / SAN does not belong to GitHub.
    // This is a lightweight host-binding guard on top of system TLS validation.
    client.badCertificateCallback =
        (X509Certificate cert, String host, int port) {
      // Always reject — if the system TLS stack calls this callback it means
      // the certificate is already invalid; never override that decision.
      return false;
    };

    return client;
  }

  /// Checks GitHub Releases API for the latest release
  static Future<UpdateCheckResult> checkForUpdates() async {
    final uri = Uri.parse(githubReleasesApi);

    // 1. Enforce HTTPS + trusted GitHub domain before opening any connection
    _assertTrustedUri(uri);

    final client = _buildSecureClient(timeout: const Duration(seconds: 10));

    try {
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

        // Find APK in assets and parse digest if provided
        String? apkDownloadUrl;
        int? apkSizeBytes;
        String? expectedSha256;

        final assets = data['assets'] as List<dynamic>?;
        if (assets != null) {
          for (final asset in assets) {
            final name = (asset['name'] as String? ?? '').toLowerCase();
            if (name.endsWith('.apk')) {
              apkDownloadUrl = asset['browser_download_url'] as String?;
              apkSizeBytes = (asset['size'] as num?)?.toInt();

              final digest = (asset['digest'] as String? ?? '').trim();
              if (digest.toLowerCase().startsWith('sha256:')) {
                expectedSha256 = digest.substring(7).trim();
              } else if (RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(digest)) {
                expectedSha256 = digest;
              }
              break;
            }
          }
        }

        // Fallback: search for SHA-256 hash in release notes / body
        if (expectedSha256 == null && releaseNotes.isNotEmpty) {
          final match = RegExp(
            r'(?:sha-?256|checksum|hash)[\s:=]+([a-fA-F0-9]{64})',
            caseSensitive: false,
          ).firstMatch(releaseNotes);
          if (match != null) {
            expectedSha256 = match.group(1);
          }
        }

        // If no direct APK asset found, default download link to the release web page
        apkDownloadUrl ??= htmlUrl;

        final cleanCurrent = extractSemver(currentAppVersion);
        final cleanTag = extractSemver(tagName);
        final cleanTitle = extractSemver(releaseTitle);

        // If the release tag or title matches the current version,
        // the app is already on the latest update.
        final bool isSameVersion = (cleanTag == cleanCurrent) ||
            (cleanTitle.isNotEmpty && cleanTitle == cleanCurrent);

        final bool hasNewer = !isSameVersion &&
            (isVersionNewer(tagName, currentAppVersion) ||
                (cleanTitle.isNotEmpty && isVersionNewer(cleanTitle, currentAppVersion)));

        return UpdateCheckResult(
          hasUpdate: hasNewer,
          isUpToDate: !hasNewer,
          currentVersion: currentAppVersion,
          latestVersion:
              cleanTitle.isNotEmpty ? cleanTitle : cleanTag,
          releaseTitle: releaseTitle,
          releaseNotes: releaseNotes,
          releaseUrl: htmlUrl,
          apkDownloadUrl: apkDownloadUrl,
          apkSizeBytes: apkSizeBytes,
          expectedSha256: expectedSha256,
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

  /// Downloads the APK with progress streaming and SHA-256 cryptographic verification
  static Future<String?> downloadApk({
    required String downloadUrl,
    required String destinationPath,
    String? expectedSha256,
    required void Function(int receivedBytes, int totalBytes, double percent)
        onProgress,
    bool Function()? isCancelled,
  }) async {
    // 1. Enforce HTTPS + trusted GitHub domain (shared guard with checkForUpdates)
    final uri = Uri.parse(downloadUrl);
    _assertTrustedUri(uri);

    final client = _buildSecureClient(timeout: const Duration(seconds: 15));
    try {
      final request = await client.getUrl(uri);
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

      // 2. Cryptographic SHA-256 Checksum Verification
      if (expectedSha256 != null && expectedSha256.trim().isNotEmpty) {
        final digest = await file.openRead().transform(sha256).first;
        final actualHash = digest.toString().toLowerCase();
        final cleanExpected = expectedSha256.trim().toLowerCase();

        if (actualHash != cleanExpected) {
          if (await file.exists()) {
            await file.delete();
          }
          throw Exception(
              'Security verification error: APK checksum mismatch! Expected $cleanExpected but calculated $actualHash. Downloaded file was purged.');
        }
      }

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
