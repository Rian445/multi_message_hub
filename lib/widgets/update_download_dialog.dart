import 'dart:io';
import 'package:flutter/material.dart';
import '../services/profile_manager_channel.dart';
import '../services/update_service.dart';
import 'status_feedback_dialog.dart';

class UpdateDownloadDialog extends StatefulWidget {
  final UpdateCheckResult update;

  const UpdateDownloadDialog({
    super.key,
    required this.update,
  });

  static Future<void> show(BuildContext context, UpdateCheckResult update) {
    return showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => UpdateDownloadDialog(update: update),
    );
  }

  @override
  State<UpdateDownloadDialog> createState() => _UpdateDownloadDialogState();
}

class _UpdateDownloadDialogState extends State<UpdateDownloadDialog>
    with SingleTickerProviderStateMixin {
  double _progress = 0.0;
  int _receivedBytes = 0;
  int _totalBytes = 0;
  bool _isCancelled = false;
  bool _isFinished = false;
  String _statusText = 'Connecting to GitHub...';
  String _speedText = '';
  DateTime? _lastSpeedCalcTime;
  int _lastSpeedCalcBytes = 0;

  late final AnimationController _pulseController;
  late final Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 0.95, end: 1.08).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _startDownload();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  Future<void> _startDownload() async {
    final downloadUrl = widget.update.apkDownloadUrl;
    if (downloadUrl == null || downloadUrl.isEmpty) {
      if (mounted) {
        Navigator.pop(context);
        StatusFeedbackDialog.showError(
          context,
          title: 'Download Failed',
          message: 'No APK download link found in the release.',
        );
      }
      return;
    }

    // Determine target save location
    String? cachePath = await ProfileManagerChannel.getAppCacheDir();
    cachePath ??= Directory.systemTemp.path;
    final apkPath = '$cachePath/multi_message_hub_update.apk';

    _lastSpeedCalcTime = DateTime.now();
    _lastSpeedCalcBytes = 0;

    try {
      final downloadedPath = await UpdateService.downloadApk(
        downloadUrl: downloadUrl,
        destinationPath: apkPath,
        isCancelled: () => _isCancelled,
        onProgress: (received, total, percent) {
          if (!mounted || _isCancelled) return;

          // Calculate speed every 500ms
          final now = DateTime.now();
          if (_lastSpeedCalcTime != null &&
              now.difference(_lastSpeedCalcTime!).inMilliseconds > 500) {
            final elapsedSec =
                now.difference(_lastSpeedCalcTime!).inMilliseconds / 1000.0;
            final bytesDelta = received - _lastSpeedCalcBytes;
            if (elapsedSec > 0 && bytesDelta > 0) {
              final speedBytesPerSec = bytesDelta / elapsedSec;
              final speedMb = speedBytesPerSec / (1024 * 1024);
              _speedText = '${speedMb.toStringAsFixed(1)} MB/s';
            }
            _lastSpeedCalcTime = now;
            _lastSpeedCalcBytes = received;
          }

          setState(() {
            _receivedBytes = received;
            _totalBytes = total;
            _progress = percent;
            _statusText = percent >= 1.0
                ? 'Verifying package...'
                : 'Downloading update...';
          });
        },
      );

      if (_isCancelled || !mounted) return;

      if (downloadedPath != null) {
        setState(() {
          _isFinished = true;
          _progress = 1.0;
          _statusText = 'Download complete! Launching installer...';
        });

        await Future.delayed(const Duration(milliseconds: 600));

        if (!mounted) return;
        Navigator.pop(context); // Close download dialog

        // Trigger native Android package installer
        final success = await ProfileManagerChannel.installApk(downloadedPath);
        if (!success && mounted) {
          StatusFeedbackDialog.showInfo(
            context,
            title: 'Install Update',
            message:
                'APK downloaded to cache. If prompt didn\'t open, check your notifications.',
          );
        }
      }
    } catch (e) {
      if (!mounted || _isCancelled) return;
      Navigator.pop(context);
      StatusFeedbackDialog.showError(
        context,
        title: 'Download Failed',
        message: 'Could not complete update download: $e',
      );
    }
  }

  void _onCancel() {
    _isCancelled = true;
    UpdateService.cleanCachedApk();
    Navigator.pop(context);
    StatusFeedbackDialog.showInfo(
      context,
      title: 'Update Cancelled',
      message: 'Download was cancelled.',
    );
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 MB';
    final mb = bytes / (1024 * 1024);
    return '${mb.toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    const googleBlue = Color(0xFF8AB4F8);
    final percentInt = (_progress * 100).toInt();

    return PopScope(
      canPop: false,
      child: AlertDialog(
        backgroundColor: const Color(0xFF1E1F22),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        contentPadding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
        actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Animated Icon
            ScaleTransition(
              scale: _pulseAnimation,
              child: Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _isFinished
                      ? Colors.greenAccent.withValues(alpha: 0.15)
                      : googleBlue.withValues(alpha: 0.15),
                ),
                child: Icon(
                  _isFinished
                      ? Icons.check_circle_rounded
                      : Icons.cloud_download_rounded,
                  size: 36,
                  color: _isFinished ? Colors.greenAccent : googleBlue,
                ),
              ),
            ),
            const SizedBox(height: 18),

            // Title
            const Text(
              'Downloading Update',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),

            // Version Badge
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: googleBlue.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                    color: googleBlue.withValues(alpha: 0.3), width: 0.8),
              ),
              child: Text(
                'v${widget.update.latestVersion}',
                style: const TextStyle(
                  color: googleBlue,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(height: 20),

            // Custom Animated Progress Bar
            Stack(
              children: [
                // Background Track
                Container(
                  height: 12,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: const Color(0xFF2B2D31),
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                // Filled Progress Bar
                LayoutBuilder(
                  builder: (context, constraints) {
                    final fillWidth =
                        constraints.maxWidth * _progress.clamp(0.0, 1.0);
                    return AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      curve: Curves.easeOut,
                      height: 12,
                      width: fillWidth,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(6),
                        gradient: const LinearGradient(
                          colors: [
                            Color(0xFF669DF6),
                            Color(0xFF8AB4F8),
                            Color(0xFFAECBFA),
                          ],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: googleBlue.withValues(alpha: 0.4),
                            blurRadius: 6,
                            offset: const Offset(0, 1),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Readouts: Progress % and MBs
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _totalBytes > 0
                      ? '${_formatBytes(_receivedBytes)} / ${_formatBytes(_totalBytes)}'
                      : _formatBytes(_receivedBytes),
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
                Row(
                  children: [
                    if (_speedText.isNotEmpty && !_isFinished) ...[
                      Text(
                        _speedText,
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 11),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Text(
                      '$percentInt%',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 10),

            // Status Text
            Text(
              _statusText,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _isFinished ? Colors.greenAccent : Colors.white54,
                fontSize: 12,
                fontWeight:
                    _isFinished ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
        actions: [
          if (!_isFinished)
            TextButton(
              onPressed: _onCancel,
              child:
                  const Text('Cancel', style: TextStyle(color: Colors.white60)),
            ),
        ],
      ),
    );
  }
}
