import 'dart:async';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../models/profile_instance.dart';
import '../screens/lock_screen.dart';
import '../services/foreground_service.dart';
import '../services/notification_service.dart';
import '../services/profile_manager_channel.dart';
import '../services/profile_storage_service.dart';
import '../services/security_service.dart';
import '../services/update_service.dart';
import '../widgets/isolated_web_view_widget.dart';
import '../widgets/status_feedback_dialog.dart';
import '../widgets/update_download_dialog.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final ProfileStorageService _storageService = ProfileStorageService();
  final NotificationService _notificationService = NotificationService();
  final ForegroundServiceManager _foregroundManager =
      ForegroundServiceManager();
  final SecurityService _securityService = SecurityService();
  final Uuid _uuidGenerator = const Uuid();

  List<ProfileInstance> _instances = [];
  int _currentIndex = 0;
  bool _isLoading = true;
  bool _isMultiProfileSupported = true;
  bool _isLocked = false;
  DateTime? _lastPausedTime;
  DateTime? _lastUnlockedTime;

  final Map<String, IsolatedWebViewController> _controllers = {};
  StreamSubscription<String>? _notificationClickSub;
  bool _isGoogleSignInDialogShowing = false;

  void _handleGoogleSignInAttempted(String uuid, String url) {
    if (_isGoogleSignInDialogShowing || !mounted) return;
    _isGoogleSignInDialogShowing = true;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.qr_code_scanner, color: Colors.blue),
            SizedBox(width: 8),
            Text('Use QR Code Pairing'),
          ],
        ),
        content: const Text(
          'Google blocks password-based sign-in inside embedded Android apps ("This browser or app may not be secure").\n\n'
          'To pair your secondary phone:\n'
          '1. Tap "Show QR Code" below.\n'
          '2. On your secondary phone, open Google Messages.\n'
          '3. Tap your profile picture -> "Device pairing" -> "QR code scanner".\n'
          '4. Scan the QR code displayed on screen!',
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _isGoogleSignInDialogShowing = false;
            },
            child: const Text('Dismiss'),
          ),
          ElevatedButton.icon(
            icon: const Icon(Icons.qr_code),
            label: const Text('Show QR Code'),
            onPressed: () {
              Navigator.pop(ctx);
              _isGoogleSignInDialogShowing = false;
              _controllers[uuid]?.loadUrl('https://messages.google.com/web/authentication');
            },
          ),
        ],
      ),
    ).then((_) {
      _isGoogleSignInDialogShowing = false;
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeHub();
  }

  Future<void> _initializeHub() async {
    // Clean any old downloaded update APKs from cache to free storage
    unawaited(UpdateService.cleanCachedApk());

    // Check Multi-Profile support in AndroidX WebKit
    final supported = await ProfileManagerChannel.isMultiProfileSupported();

    // Initialize notification service
    await _notificationService.init();

    // Listen for notification clicks to switch active profile
    _notificationClickSub =
        _notificationService.onNotificationClick.listen((uuid) {
      _switchToProfile(uuid);
    });

    // Load saved instances
    final loaded = await _storageService.loadInstances();
    final defaultUuid = await _storageService.getDefaultProfileUuid();

    // Check if App Lock is enabled
    final isLockEnabled = await _securityService.isLockEnabled();

    int startIdx = 0;
    if (defaultUuid != null) {
      final defIdx = loaded.indexWhere((p) => p.uuid == defaultUuid);
      if (defIdx != -1) {
        startIdx = defIdx;
      }
    } else if (loaded.isNotEmpty) {
      final firstVisible = loaded.indexWhere((p) => !p.isHidden);
      if (firstVisible != -1) {
        startIdx = firstVisible;
      }
    }

    setState(() {
      _instances = loaded;
      _isMultiProfileSupported = supported;
      _isLoading = false;
      _isLocked = isLockEnabled;
      if (_instances.isNotEmpty) {
        _currentIndex = startIdx;
      }
    });

    // Start background foreground service if instances exist and sync is enabled
    final isSyncEnabled = await _storageService.isBackgroundSyncEnabled();
    if (_instances.isNotEmpty && isSyncEnabled) {
      await _foregroundManager.startService(_instances.length);
    }

    // Check battery optimization exemption on first launch
    _checkBatteryOptimization();
  }

  Future<void> _checkBatteryOptimization() async {
    final alreadyPrompted = await _storageService.hasBatteryPromptBeenShown();
    if (alreadyPrompted) return; // Only show once on first launch

    final isIgnored =
        await ProfileManagerChannel.isBatteryOptimizationIgnored();
    if (!isIgnored && mounted) {
      _showBatteryOptimizationDialog();
    }
  }

  void _showBatteryOptimizationDialog() {
    _storageService.setBatteryPromptShown();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1F22),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.battery_alert, color: Colors.orange),
            SizedBox(width: 8),
            Text('Background Reliability', style: TextStyle(color: Colors.white)),
          ],
        ),
        content: const Text(
          'To ensure you receive instant notifications when messages arrive on paired devices even while your phone is locked, please allow unrestricted background activity.\n\n'
          'You can also configure this anytime later from the side menu under "Battery Optimization".',
          style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Later', style: TextStyle(color: Colors.white60)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF8AB4F8)),
            onPressed: () {
              Navigator.pop(ctx);
              ProfileManagerChannel.requestIgnoreBatteryOptimization();
            },
            child: const Text('Allow', style: TextStyle(color: Color(0xFF131314))),
          ),
        ],
      ),
    );
  }

  void _switchToProfile(String uuid) {
    final idx = _instances.indexWhere((inst) => inst.uuid == uuid);
    if (idx != -1 && idx != _currentIndex) {
      setState(() {
        _currentIndex = idx;
        // Clear unread count for the newly focused instance
        _instances[idx] = _instances[idx].copyWith(unreadCount: 0);
      });
      _storageService.saveInstances(_instances);
    }
  }

  void _handleIncomingNotification(
    String uuid,
    String sender,
    String body,
    int timestamp,
  ) {
    final idx = _instances.indexWhere((inst) => inst.uuid == uuid);
    final targetInstance = idx != -1 ? _instances[idx] : null;
    final customName = targetInstance?.customName ?? 'Secondary Device';

    // Fire native Android notification
    _notificationService.showNotification(
      uuid: uuid,
      customName: customName,
      sender: sender,
      body: body,
    );

    // Update unread count if not currently active
    if (idx != -1 && idx != _currentIndex) {
      setState(() {
        _instances[idx] = _instances[idx]
            .copyWith(unreadCount: _instances[idx].unreadCount + 1);
      });
      _storageService.saveInstances(_instances);
    }
  }

  Future<void> _addNewInstance(String customName) async {
    final newUuid = 'profile_${_uuidGenerator.v4().replaceAll('-', '')}';
    final isFirst = _instances.isEmpty;
    final newInstance = ProfileInstance(
      uuid: newUuid,
      customName: customName.trim().isEmpty ? 'Secondary SIM' : customName.trim(),
      createdAt: DateTime.now(),
      mobileMode: true,
      isDefault: isFirst,
    );

    setState(() {
      _instances.add(newInstance);
      _currentIndex = _instances.length - 1;
    });

    if (isFirst) {
      await _storageService.setDefaultProfileUuid(newUuid);
    }
    await _storageService.saveInstances(_instances);
    await _foregroundManager.startService(_instances.length);

    if (mounted) {
      StatusFeedbackDialog.showSuccess(
        context,
        title: 'Device Created',
        message: 'Profile "${newInstance.customName}" created. Ready to pair!',
      );
    }
  }

  Future<void> _setDefaultProfile(int index) async {
    final targetUuid = _instances[index].uuid;
    final targetName = _instances[index].customName;
    final isCurrentlyDefault = _instances[index].isDefault;

    setState(() {
      _instances = _instances.map((p) {
        if (p.uuid == targetUuid) {
          return p.copyWith(isDefault: !isCurrentlyDefault);
        } else {
          return p.copyWith(isDefault: false);
        }
      }).toList();
    });

    if (!isCurrentlyDefault) {
      await _storageService.setDefaultProfileUuid(targetUuid);
      await _storageService.saveInstances(_instances);
      if (mounted) {
        StatusFeedbackDialog.showSuccess(
          context,
          title: 'Default Device Set',
          message: '"$targetName" is now your default device and will open automatically on app launch.',
        );
      }
    } else {
      await _storageService.setDefaultProfileUuid(null);
      await _storageService.saveInstances(_instances);
      if (mounted) {
        StatusFeedbackDialog.showInfo(
          context,
          title: 'Default Cleared',
          message: '"$targetName" is no longer the default device.',
        );
      }
    }
  }

  Future<void> _toggleHideProfile(int index) async {
    final targetUuid = _instances[index].uuid;
    final targetName = _instances[index].customName;
    final newHiddenState = !_instances[index].isHidden;

    setState(() {
      _instances = _instances.map((p) {
        if (p.uuid == targetUuid) {
          return p.copyWith(isHidden: newHiddenState);
        }
        return p;
      }).toList();

      // If we just hid the currently active device, switch to another visible one if possible
      if (newHiddenState && _currentIndex == index) {
        final nextVisible = _instances.indexWhere((p) => !p.isHidden);
        if (nextVisible != -1) {
          _currentIndex = nextVisible;
        }
      }
    });

    await _storageService.saveInstances(_instances);

    if (mounted) {
      if (newHiddenState) {
        StatusFeedbackDialog.showSuccess(
          context,
          title: 'Device Hidden',
          message: '"$targetName" is now hidden from the main list. You can unhide it anytime.',
        );
      } else {
        StatusFeedbackDialog.showSuccess(
          context,
          title: 'Device Unhidden',
          message: '"$targetName" is now visible in the main device switcher.',
        );
      }
    }
  }

  Future<void> _renameInstance(int index, String newName) async {
    final trimmed = newName.trim();
    if (trimmed.isEmpty) return;

    setState(() {
      _instances[index] = _instances[index].copyWith(customName: trimmed);
    });

    await _storageService.saveInstances(_instances);

    if (mounted) {
      StatusFeedbackDialog.showSuccess(
        context,
        title: 'Device Renamed',
        message: 'Renamed to "$trimmed"',
      );
    }
  }

  Future<void> _deleteInstance(int index) async {
    final target = _instances[index];
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete / Unpair Device?'),
        content: Text(
          'This will permanently delete the isolated profile "${target.customName}", wiping all cookies and session pairing keys.\n\nOther paired phones will remain untouched.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete Profile', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      // Delete on disk via AndroidX ProfileStore
      await ProfileManagerChannel.deleteProfile(target.uuid);

      _controllers.remove(target.uuid);

      setState(() {
        _instances.removeAt(index);
        if (_currentIndex >= _instances.length && _instances.isNotEmpty) {
          _currentIndex = _instances.length - 1;
        } else if (_instances.isEmpty) {
          _currentIndex = 0;
        }
      });

      if (target.isDefault) {
        await _storageService.setDefaultProfileUuid(null);
      }
      await _storageService.saveInstances(_instances);

      if (_instances.isNotEmpty) {
        await _foregroundManager.updateDeviceCount(_instances.length);
      } else {
        await _foregroundManager.stopService();
      }

      if (mounted) {
        StatusFeedbackDialog.showSuccess(
          context,
          title: 'Device Removed',
          message: 'Profile "${target.customName}" was deleted.',
        );
      }
    }
  }

  void _showAddDialog() {
    final textController = TextEditingController();
    final suggestions = ['GP Personal', 'Robi OTP SIM', 'Office Phone', 'Home SIM'];

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            title: const Text('Add Paired Device'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Assign an account or device name. Future message notifications will use this label:',
                  style: TextStyle(fontSize: 13, color: Colors.black87),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: textController,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Device / SIM Name',
                    hintText: 'e.g. Office SIM',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                const Text('Suggestions:', style: TextStyle(fontSize: 12, color: Colors.grey)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: suggestions.map((s) {
                    return ActionChip(
                      label: Text(s, style: const TextStyle(fontSize: 12)),
                      onPressed: () {
                        textController.text = s;
                        setDialogState(() {});
                      },
                    );
                  }).toList(),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () {
                  final name = textController.text.trim();
                  if (name.isNotEmpty) {
                    Navigator.pop(ctx);
                    _addNewInstance(name);
                  }
                },
                child: const Text('Create Profile'),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showRenameDialog(int index) {
    final instance = _instances[index];
    final textController = TextEditingController(text: instance.customName);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename Device'),
        content: TextField(
          controller: textController,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Account / Device Name',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              _renameInstance(index, textController.text);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _showPairingGuide() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.sync_alt, color: Colors.blueAccent),
            SizedBox(width: 8),
            Text('Pairing Methods'),
          ],
        ),
        content: const SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Method 1: Google Account Sign-In',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.blue),
              ),
              SizedBox(height: 6),
              Text(
                '• Tap "Sign in with Google" on the web page.\n• Sign into the same Google account active on your secondary phone.\n• Verify the matching emoji on your phone to complete setup.',
                style: TextStyle(fontSize: 13, height: 1.3),
              ),
              SizedBox(height: 14),
              Text(
                'Method 2: QR Code Pairing',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Colors.deepPurple),
              ),
              SizedBox(height: 6),
              Text(
                '• On your secondary phone, open Google Messages.\n• Tap your profile picture -> "Device pairing".\n• Tap "Switch to QR pairing" or "QR code scanner".\n• Scan the QR code displayed on this tab.',
                style: TextStyle(fontSize: 13, height: 1.3),
              ),
              SizedBox(height: 14),
              Text(
                'Tip: Each tab uses a 100% isolated profile, allowing different Google accounts and phones in each tab without conflicts.',
                style: TextStyle(fontSize: 12, color: Colors.black54, fontStyle: FontStyle.italic),
              ),
            ],
          ),
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Got It'),
          ),
        ],
      ),
    );
  }

  Future<void> _checkForUpdates({bool isManual = true}) async {
    if (isManual) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1E1F22),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          content: const Row(
            children: [
              SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF8AB4F8)),
                ),
              ),
              SizedBox(width: 18),
              Expanded(
                child: Text(
                  'Checking for updates on GitHub...',
                  style: TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final result = await UpdateService.checkForUpdates();

    if (isManual && mounted) {
      Navigator.of(context, rootNavigator: true).pop(); // Dismiss loading dialog
    }

    if (!mounted) return;

    if (result.hasError) {
      if (isManual) {
        StatusFeedbackDialog.showError(
          context,
          title: 'Update Check Failed',
          message: result.errorMessage ?? 'Unable to connect to GitHub Releases.',
        );
      }
    } else if (result.hasUpdate) {
      _showUpdateAvailableDialog(result);
    } else {
      if (isManual) {
        StatusFeedbackDialog.showSuccess(
          context,
          title: 'You\'re on the Latest Version!',
          message:
              'Multi-Message Hub is up to date (v${result.currentVersion}). No new updates available.',
        );
      }
    }
  }

  void _showUpdateAvailableDialog(UpdateCheckResult update) {
    const googleBlue = Color(0xFF8AB4F8);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1F22),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
        contentPadding: const EdgeInsets.symmetric(horizontal: 20),
        actionsPadding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.greenAccent.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.system_update_rounded,
                  color: Colors.greenAccent, size: 28),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Update Available!',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Text(
                        'v${update.currentVersion}',
                        style:
                            const TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 6),
                        child: Icon(Icons.arrow_forward_rounded,
                            size: 12, color: googleBlue),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: Colors.greenAccent.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(
                              color: Colors.greenAccent.withValues(alpha: 0.5),
                              width: 0.5),
                        ),
                        child: Text(
                          'v${update.latestVersion}',
                          style: const TextStyle(
                            color: Colors.greenAccent,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      if (update.formattedApkSize.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Text(
                          '• ${update.formattedApkSize}',
                          style: const TextStyle(
                              color: Colors.white38, fontSize: 11),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (update.releaseTitle != null &&
                update.releaseTitle!.isNotEmpty) ...[
              Text(
                update.releaseTitle!,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 8),
            ],
            const Text(
              'What\'s New:',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 11,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 6),
            Container(
              constraints: const BoxConstraints(maxHeight: 180),
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF282A2E),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFF383A40)),
              ),
              child: SingleChildScrollView(
                child: Text(
                  update.releaseNotes ??
                      'Maintenance and performance improvements.',
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12.5,
                    height: 1.4,
                  ),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Later', style: TextStyle(color: Colors.white60)),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: googleBlue,
              foregroundColor: const Color(0xFF131314),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            ),
            icon: const Icon(Icons.download_rounded, size: 18),
            label: const Text(
              'Update Now',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            onPressed: () {
              Navigator.pop(ctx);
              UpdateDownloadDialog.show(context, update);
            },
          ),
        ],
      ),
    );
  }

  void _showAboutDialog() {
    const googleBlue = Color(0xFF8AB4F8);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1F22),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.asset(
                'assets/icons/app_logo.png',
                width: 40,
                height: 40,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Multi-Message Hub',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    'Version ${UpdateService.currentAppVersion} (Release)',
                    style: const TextStyle(color: Colors.white60, fontSize: 11),
                  ),
                ],
              ),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Developer Badge
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF2B2D31),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: googleBlue.withValues(alpha: 0.3)),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.verified_user_rounded, color: googleBlue, size: 26),
                    SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'LEAD DEVELOPER',
                          style: TextStyle(
                            color: Colors.white54,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.8,
                          ),
                        ),
                        Text(
                          'RIAN ISLAM',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Miscellaneous Information',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 10),
              _buildAboutInfoItem(
                Icons.layers_outlined,
                'Architecture',
                'Multi-Profile WebKit Isolation (androidx.webkit:webkit:1.12.1)',
              ),
              _buildAboutInfoItem(
                Icons.devices,
                'Multi-Account Support',
                'Unlimited simultaneous Google Messages Web / SIM accounts',
              ),
              _buildAboutInfoItem(
                Icons.sync,
                'Background Persistence',
                'Android Foreground Service with notification interception',
              ),
              _buildAboutInfoItem(
                Icons.shield_outlined,
                'Privacy & Zero Telemetry',
                'Direct client-to-Google communication (No middleman servers)',
              ),
              _buildAboutInfoItem(
                Icons.phone_android,
                'Dual Display Engine',
                'Real-time toggle between Phone (Mobile Fit) and Web (Desktop)',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close', style: TextStyle(color: googleBlue)),
          ),
        ],
      ),
    );
  }

  void _showPrivacyPolicyDialog() {
    const googleBlue = Color(0xFF8AB4F8);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1F22),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: const [
            Icon(Icons.shield_outlined, color: googleBlue, size: 24),
            SizedBox(width: 10),
            Text(
              'Security & Privacy Policy',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 18,
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF282A2E),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: googleBlue.withValues(alpha: 0.3),
                    ),
                  ),
                  child: const Text(
                    'Multi-Message Hub is engineered with a strict local-only, zero-telemetry architecture. Your messages, pairing credentials, and sessions are 100% private to you.',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                _buildPolicyItem(
                  Icons.lock_person_outlined,
                  'Zero 3rd-Party App Access (UID Sandbox)',
                  'Android assigns a unique Linux User ID (UID) exclusively to this app. All session tokens, cookies, and chat data are stored in private storage (0700 permissions). No external app installed on your phone can inspect or extract your data.',
                ),
                _buildPolicyItem(
                  Icons.dns_outlined,
                  'Direct Google Connection (No Middleman)',
                  'Network connections travel directly and securely to official Google endpoints (messages.google.com). There are zero intermediate relay, proxy, or third-party servers.',
                ),
                _buildPolicyItem(
                  Icons.phonelink_lock_outlined,
                  'Multi-Profile WebKit Isolation',
                  'Every paired SIM/account runs in its own distinct WebKit profile. Cookies, caches, and databases for Account A cannot bleed into Account B, and all data is permanently purged on account deletion.',
                ),
                _buildPolicyItem(
                  Icons.shield_moon_outlined,
                  'Anti-Extraction & Network Hardening',
                  'USB ADB backups and cloud cloning are explicitly disabled (android:allowBackup="false"). Plaintext HTTP is blocked (android:usesCleartextTraffic="false"), and external links are safely routed outside the sandbox.',
                ),
                _buildPolicyItem(
                  Icons.fingerprint,
                  'Cryptographic PIN Hashing & Biometrics',
                  'Chats are safeguarded behind Android\'s hardware BiometricPrompt (Fingerprint / Face Unlock) and a 4-digit Master PIN protected with salted SHA-256 key stretching and progressive brute-force rate-limiting lockout.',
                ),
                const SizedBox(height: 8),
                const Center(
                  child: Text(
                    'Developer: RIAN ISLAM • Built for Android 8.0+',
                    style: TextStyle(color: Colors.white38, fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close', style: TextStyle(color: googleBlue)),
          ),
        ],
      ),
    );
  }

  Widget _buildPolicyItem(IconData icon, String title, String description) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: const Color(0xFF8AB4F8)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  description,
                  style: const TextStyle(
                    color: Colors.white60,
                    fontSize: 11.5,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAboutInfoItem(IconData icon, String title, String subtitle) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: const Color(0xFF8AB4F8)),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  subtitle,
                  style: const TextStyle(color: Colors.white60, fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showDefaultDevicePicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1F22),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (pickerCtx, setPickerState) {
          final defaultIndex = _instances.indexWhere((p) => p.isDefault);
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: const [
                      Icon(Icons.star, color: Colors.amber, size: 22),
                      SizedBox(width: 8),
                      Text(
                        'Select Default Device',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 18,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'The default device opens automatically every time you launch Multi-Message Hub.',
                    style: TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                  const SizedBox(height: 16),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        ListTile(
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                          tileColor: defaultIndex == -1
                              ? const Color(0xFF282A2E)
                              : Colors.transparent,
                          leading: Icon(
                            defaultIndex == -1
                                ? Icons.radio_button_checked
                                : Icons.radio_button_off,
                            color: defaultIndex == -1
                                ? const Color(0xFF8AB4F8)
                                : Colors.white38,
                          ),
                          title: const Text('None (Open first active device)',
                              style:
                                  TextStyle(color: Colors.white, fontSize: 14)),
                          onTap: () async {
                            Navigator.pop(ctx);
                            await _storageService.setDefaultProfileUuid(null);
                            setState(() {
                              _instances = _instances
                                  .map((p) => p.copyWith(isDefault: false))
                                  .toList();
                            });
                            await _storageService.saveInstances(_instances);
                            if (mounted) {
                              StatusFeedbackDialog.showInfo(
                                context,
                                title: 'Default Cleared',
                                message:
                                    'App will open the first active device.',
                              );
                            }
                          },
                        ),
                        const Divider(color: Color(0xFF383A40), height: 16),
                        ..._instances.asMap().entries.map((entry) {
                          final idx = entry.key;
                          final inst = entry.value;
                          final isDef = inst.isDefault;
                          return ListTile(
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10)),
                            tileColor: isDef
                                ? Colors.amber.withValues(alpha: 0.12)
                                : Colors.transparent,
                            leading: Icon(
                              isDef ? Icons.star : Icons.phone_android,
                              color: isDef ? Colors.amber : Colors.white70,
                            ),
                            title: Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    inst.customName,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color:
                                          isDef ? Colors.amber : Colors.white,
                                      fontWeight: isDef
                                          ? FontWeight.bold
                                          : FontWeight.normal,
                                      fontSize: 14,
                                    ),
                                  ),
                                ),
                                if (inst.isHidden) ...[
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 4, vertical: 1),
                                    decoration: BoxDecoration(
                                      color: Colors.white10,
                                      borderRadius: BorderRadius.circular(3),
                                    ),
                                    child: const Text('Hidden',
                                        style: TextStyle(
                                            color: Colors.white38,
                                            fontSize: 9)),
                                  ),
                                ],
                              ],
                            ),
                            trailing: isDef
                                ? const Icon(Icons.check_circle,
                                    color: Colors.amber, size: 20)
                                : null,
                            onTap: () async {
                              Navigator.pop(ctx);
                              await _setDefaultProfile(idx);
                            },
                          );
                        }),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _showManageHiddenDevicesSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1F22),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (sheetCtx, setSheetState) {
          final hiddenEntries = _instances
              .asMap()
              .entries
              .where((e) => e.value.isHidden)
              .toList();

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: const [
                          Icon(Icons.visibility_off_outlined,
                              color: Color(0xFF8AB4F8), size: 22),
                          SizedBox(width: 8),
                          Text(
                            'Hidden Devices',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 18,
                            ),
                          ),
                        ],
                      ),
                      if (hiddenEntries.length > 1)
                        TextButton(
                          onPressed: () async {
                            Navigator.pop(ctx);
                            setState(() {
                              _instances = _instances
                                  .map((p) => p.copyWith(isHidden: false))
                                  .toList();
                            });
                            await _storageService.saveInstances(_instances);
                            if (mounted) {
                              StatusFeedbackDialog.showSuccess(
                                context,
                                title: 'All Devices Unhidden',
                                message:
                                    'All devices are now visible in the main switcher.',
                              );
                            }
                          },
                          child: const Text('Unhide All',
                              style: TextStyle(color: Color(0xFF8AB4F8))),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Hidden devices stay logged in and active in the background. Tap Unhide to restore them to the main list.',
                    style: TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                  const SizedBox(height: 16),
                  if (hiddenEntries.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24.0),
                      child: Center(
                        child: Text(
                          'No hidden devices.',
                          style: TextStyle(color: Colors.white38),
                        ),
                      ),
                    )
                  else
                    Flexible(
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: hiddenEntries.length,
                        separatorBuilder: (_, unused) => const Divider(
                            color: Color(0xFF383A40), height: 1),
                        itemBuilder: (itemCtx, i) {
                          final idx = hiddenEntries[i].key;
                          final inst = hiddenEntries[i].value;

                          return ListTile(
                            leading: const Icon(Icons.phone_android,
                                color: Colors.white38),
                            title: Text(
                              inst.customName,
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 14),
                            ),
                            trailing: ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF8AB4F8),
                                foregroundColor: const Color(0xFF131314),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 6),
                              ),
                              icon: const Icon(Icons.visibility, size: 16),
                              label: const Text('Unhide',
                                  style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold)),
                              onPressed: () async {
                                Navigator.pop(ctx);
                                await _toggleHideProfile(idx);
                              },
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _showSettingsScreen() async {
    const googleBlue = Color(0xFF8AB4F8);
    bool isSyncEnabled = await _storageService.isBackgroundSyncEnabled();
    bool isLockEnabled = await _securityService.isLockEnabled();
    int lockTimeout = await _securityService.getLockTimeoutSeconds();
    bool isBatteryIgnored =
        await ProfileManagerChannel.isBatteryOptimizationIgnored();

    final defaultProfile =
        _instances.where((p) => p.isDefault).firstOrNull;
    final hiddenCount = _instances.where((p) => p.isHidden).length;

    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E1F22),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (context, setSheetState) => DraggableScrollableSheet(
          initialChildSize: 0.75,
          minChildSize: 0.5,
          maxChildSize: 0.95,
          expand: false,
          builder: (context, scrollController) => SingleChildScrollView(
            controller: scrollController,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Top drag handle
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),

                // Title
                Row(
                  children: [
                    const Icon(Icons.settings, color: googleBlue, size: 24),
                    const SizedBox(width: 10),
                    const Text(
                      'Settings',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white70),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // SECTION: DEVICE CONFIGURATION
                const Text(
                  'DEVICE PREFERENCES',
                  style: TextStyle(
                    color: Colors.white54,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF282A2E),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    children: [
                      ListTile(
                        leading:
                            const Icon(Icons.star_outline, color: Colors.amber),
                        title: const Text(
                          'Default Device on Launch',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                        subtitle: Text(
                          defaultProfile != null
                              ? '${defaultProfile.customName} (Opens automatically on launch)'
                              : 'None (Opens first active device)',
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 12),
                        ),
                        trailing: const Icon(Icons.chevron_right,
                            color: Colors.white38),
                        onTap: () {
                          Navigator.pop(ctx);
                          _showDefaultDevicePicker();
                        },
                      ),
                      if (hiddenCount > 0) ...[
                        const Divider(
                            height: 1, indent: 54, color: Color(0xFF383A40)),
                        ListTile(
                          leading: const Icon(Icons.visibility_off_outlined,
                              color: Color(0xFF8AB4F8)),
                          title: const Text(
                            'Hidden Devices',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                            ),
                          ),
                          subtitle: Text(
                            '$hiddenCount ${hiddenCount == 1 ? "device" : "devices"} hidden • Tap to view or unhide',
                            style: const TextStyle(
                                color: Colors.white54, fontSize: 12),
                          ),
                          trailing: const Icon(Icons.chevron_right,
                              color: Colors.white38),
                          onTap: () {
                            Navigator.pop(ctx);
                            _showManageHiddenDevicesSheet();
                          },
                        ),
                      ],
                    ],
                  ),
                ),

                const SizedBox(height: 24),

                // SECTION: NOTIFICATIONS & BACKGROUND
                const Text(
                  'BACKGROUND & NOTIFICATIONS',
                  style: TextStyle(
                    color: Colors.white54,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF282A2E),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: SwitchListTile(
                    activeThumbColor: googleBlue,
                    secondary: Icon(
                      isSyncEnabled ? Icons.sync : Icons.sync_disabled,
                      color: isSyncEnabled ? googleBlue : Colors.white38,
                    ),
                    title: const Text(
                      'Persistent Sync Notification',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                    subtitle: Text(
                      isSyncEnabled
                          ? 'Constant notification active. Background messages are received even when closed.'
                          : 'Disabled. Persistent status bar notification is hidden.',
                      style:
                          const TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                    value: isSyncEnabled,
                    onChanged: (val) async {
                      await _storageService.setBackgroundSyncEnabled(val);
                      if (val) {
                        if (_instances.isNotEmpty) {
                          await _foregroundManager
                              .startService(_instances.length);
                        }
                      } else {
                        await _foregroundManager.stopService();
                      }
                      setSheetState(() {
                        isSyncEnabled = val;
                      });
                      if (ctx.mounted) {
                        if (val) {
                          StatusFeedbackDialog.showSuccess(
                            ctx,
                            title: 'Sync Active',
                            message:
                                'Persistent background notification enabled.',
                          );
                        } else {
                          StatusFeedbackDialog.showInfo(
                            ctx,
                            title: 'Notification Hidden',
                            message: 'Constant notification turned off.',
                          );
                        }
                      }
                    },
                  ),
                ),

                const SizedBox(height: 24),

                // SECTION: SECURITY & SYSTEM
                const Text(
                  'SECURITY & OPTIMIZATION',
                  style: TextStyle(
                    color: Colors.white54,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF282A2E),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    children: [
                      ListTile(
                        leading:
                            const Icon(Icons.shield_outlined, color: googleBlue),
                        title: const Text(
                          'Security & App Lock',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                        subtitle: Text(
                          isLockEnabled
                              ? 'Protected • ${lockTimeout == 0 ? "Locks immediately" : "Locks after ${lockTimeout ~/ 60}m"}'
                              : 'Disabled (No PIN or Biometrics)',
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 12),
                        ),
                        trailing: const Icon(Icons.chevron_right,
                            color: Colors.white38),
                        onTap: () {
                          Navigator.pop(ctx);
                          _showSecuritySettingsDialog();
                        },
                      ),
                      const Divider(
                          height: 1, indent: 54, color: Color(0xFF383A40)),
                      ListTile(
                        leading: Icon(
                          Icons.battery_charging_full,
                          color: isBatteryIgnored
                              ? Colors.greenAccent
                              : Colors.orangeAccent,
                        ),
                        title: const Text(
                          'Battery Optimization',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                        subtitle: Text(
                          isBatteryIgnored
                              ? 'Unrestricted background activity granted'
                              : 'Tap to exempt from Android battery restrictions',
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 12),
                        ),
                        trailing: const Icon(Icons.chevron_right,
                            color: Colors.white38),
                        onTap: () async {
                          await ProfileManagerChannel
                              .requestIgnoreBatteryOptimization();
                          final updated = await ProfileManagerChannel
                              .isBatteryOptimizationIgnored();
                          setSheetState(() {
                            isBatteryIgnored = updated;
                          });
                        },
                      ),
                      const Divider(
                          height: 1, indent: 54, color: Color(0xFF383A40)),
                      ListTile(
                        leading: const Icon(Icons.privacy_tip_outlined,
                            color: Color(0xFF8AB4F8)),
                        title: const Text(
                          'Security & Privacy Policy',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                        subtitle: const Text(
                          'Zero 3rd-party access • No telemetry • UID sandboxing',
                          style: TextStyle(color: Colors.white54, fontSize: 12),
                        ),
                        trailing: const Icon(Icons.chevron_right,
                            color: Colors.white38),
                        onTap: () {
                          Navigator.pop(ctx);
                          _showPrivacyPolicyDialog();
                        },
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 24),

                // SECTION: ABOUT
                const Text(
                  'ABOUT & DEVELOPER',
                  style: TextStyle(
                    color: Colors.white54,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF282A2E),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.system_update_rounded,
                            color: googleBlue),
                        title: const Text(
                          'Check for Updates',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                        subtitle: Text(
                          'Current: v${UpdateService.currentAppVersion} • GitHub Releases',
                          style: const TextStyle(color: Colors.white54, fontSize: 12),
                        ),
                        trailing: const Icon(Icons.chevron_right,
                            color: Colors.white38),
                        onTap: () {
                          Navigator.pop(ctx);
                          _checkForUpdates(isManual: true);
                        },
                      ),
                      const Divider(
                          height: 1, indent: 54, color: Color(0xFF383A40)),
                      ListTile(
                        leading:
                            const Icon(Icons.info_outline, color: googleBlue),
                        title: const Text(
                          'About Multi-Message Hub',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                        subtitle: const Text(
                          'Developer: RIAN ISLAM • Architecture & Specs',
                          style: TextStyle(color: Colors.white54, fontSize: 12),
                        ),
                        trailing:
                            const Icon(Icons.chevron_right, color: Colors.white38),
                        onTap: () {
                          Navigator.pop(ctx);
                          _showAboutDialog();
                        },
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 30),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showSecuritySettingsDialog() async {
    const googleBlue = Color(0xFF8AB4F8);
    bool isLockEnabled = await _securityService.isLockEnabled();
    bool isBioEnabled = await _securityService.isBiometricsEnabled();
    bool canBio = await _securityService.canCheckBiometrics();
    int currentTimeout = await _securityService.getLockTimeoutSeconds();

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF1E1F22),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(
            children: [
              Icon(Icons.shield_rounded, color: googleBlue),
              SizedBox(width: 10),
              Text('Security & App Lock', style: TextStyle(color: Colors.white, fontSize: 18)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Protect your messages and paired profiles with PIN and Biometric authentication.',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 16),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                activeThumbColor: googleBlue,
                title: const Text('App Lock (PIN)', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                subtitle: Text(
                  isLockEnabled ? 'Protected with 4-digit PIN' : 'Disabled (Anyone can open app)',
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
                value: isLockEnabled,
                onChanged: (val) async {
                  if (val) {
                    Navigator.pop(ctx);
                    _showSetPinDialog();
                  } else {
                    final confirmed = await _promptCurrentPin();
                    if (confirmed) {
                      await _securityService.disableLock();
                      setDialogState(() {
                        isLockEnabled = false;
                      });
                      if (ctx.mounted) {
                        StatusFeedbackDialog.showInfo(
                          ctx,
                          title: 'App Lock Disabled',
                          message: 'Security PIN has been turned off.',
                        );
                      }
                    }
                  }
                },
              ),
              if (isLockEnabled) ...[
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.pin, color: googleBlue),
                  title: const Text('Change PIN', style: TextStyle(color: Colors.white)),
                  trailing: const Icon(Icons.chevron_right, color: Colors.white54),
                  onTap: () {
                    Navigator.pop(ctx);
                    _showSetPinDialog();
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.timer_outlined, color: googleBlue),
                  title: const Text('Auto-Lock Timeout', style: TextStyle(color: Colors.white)),
                  subtitle: Text(
                    currentTimeout == 0
                        ? 'Immediately when app is closed'
                        : currentTimeout == 60
                            ? 'After 1 minute in background'
                            : 'After 5 minutes in background',
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                  trailing: DropdownButton<int>(
                    value: currentTimeout,
                    dropdownColor: const Color(0xFF2B2D31),
                    underline: const SizedBox.shrink(),
                    icon: const Icon(Icons.arrow_drop_down, color: googleBlue),
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    items: const [
                      DropdownMenuItem(value: 0, child: Text('Immediately')),
                      DropdownMenuItem(value: 60, child: Text('After 1 min')),
                      DropdownMenuItem(value: 300, child: Text('After 5 min')),
                    ],
                    onChanged: (newVal) async {
                      if (newVal != null) {
                        await _securityService.setLockTimeoutSeconds(newVal);
                        setDialogState(() {
                          currentTimeout = newVal;
                        });
                        if (ctx.mounted) {
                          StatusFeedbackDialog.showSuccess(
                            ctx,
                            title: 'Timeout Updated',
                            message: newVal == 0
                                ? 'App will lock immediately when closed.'
                                : 'App will lock after ${newVal ~/ 60} minute(s).',
                          );
                        }
                      }
                    },
                  ),
                ),
                if (canBio)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    activeThumbColor: googleBlue,
                    title: const Text('Biometric Unlock', style: TextStyle(color: Colors.white)),
                    subtitle: const Text('Fingerprint / Face Unlock', style: TextStyle(color: Colors.white54, fontSize: 12)),
                    value: isBioEnabled,
                    onChanged: (val) async {
                      await _securityService.setBiometricsEnabled(val);
                      setDialogState(() {
                        isBioEnabled = val;
                      });
                    },
                  ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Done', style: TextStyle(color: googleBlue)),
            ),
          ],
        ),
      ),
    );
  }

  void _showSetPinDialog() {
    const googleBlue = Color(0xFF8AB4F8);
    final pinController = TextEditingController();
    final confirmController = TextEditingController();
    String? errorText;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF1E1F22),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(
            children: [
              Icon(Icons.lock_outline, color: googleBlue),
              SizedBox(width: 8),
              Text('Set 4-Digit PIN', style: TextStyle(color: Colors.white)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: pinController,
                autofocus: true,
                keyboardType: TextInputType.number,
                obscureText: true,
                maxLength: 4,
                style: const TextStyle(color: Colors.white, fontSize: 20, letterSpacing: 8),
                textAlign: TextAlign.center,
                decoration: const InputDecoration(
                  counterText: '',
                  labelText: 'Enter 4-Digit PIN',
                  labelStyle: TextStyle(color: Colors.white70, fontSize: 14, letterSpacing: 0),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: confirmController,
                keyboardType: TextInputType.number,
                obscureText: true,
                maxLength: 4,
                style: const TextStyle(color: Colors.white, fontSize: 20, letterSpacing: 8),
                textAlign: TextAlign.center,
                decoration: const InputDecoration(
                  counterText: '',
                  labelText: 'Confirm 4-Digit PIN',
                  labelStyle: TextStyle(color: Colors.white70, fontSize: 14, letterSpacing: 0),
                  border: OutlineInputBorder(),
                ),
              ),
              if (errorText != null) ...[
                const SizedBox(height: 10),
                Text(
                  errorText!,
                  style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel', style: TextStyle(color: Colors.white60)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: googleBlue),
              onPressed: () async {
                final pin = pinController.text.trim();
                final confirm = confirmController.text.trim();
                if (pin.length != 4) {
                  setDialogState(() => errorText = 'PIN must be exactly 4 digits');
                  StatusFeedbackDialog.showError(
                    ctx,
                    title: 'Invalid PIN Length',
                    message: 'PIN must be exactly 4 digits.',
                  );
                  return;
                }
                if (pin != confirm) {
                  setDialogState(() => errorText = 'PINs do not match. Try again.');
                  StatusFeedbackDialog.showError(
                    ctx,
                    title: 'PINs Do Not Match',
                    message: 'Please re-enter the same 4-digit PIN.',
                  );
                  return;
                }
                await _securityService.enableLock(pin);
                if (context.mounted) {
                  Navigator.pop(ctx);
                  StatusFeedbackDialog.showSuccess(
                    context,
                    title: 'App Lock Active',
                    message: '4-Digit PIN protection is set.',
                  );
                }
              },
              child: const Text('Save PIN', style: TextStyle(color: Color(0xFF131314))),
            ),
          ],
        ),
      ),
    );
  }

  Future<bool> _promptCurrentPin() async {
    const googleBlue = Color(0xFF8AB4F8);
    final pinController = TextEditingController();
    String? errorText;

    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF1E1F22),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('Enter Current PIN', style: TextStyle(color: Colors.white)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: pinController,
                autofocus: true,
                keyboardType: TextInputType.number,
                obscureText: true,
                maxLength: 4,
                style: const TextStyle(color: Colors.white, fontSize: 20, letterSpacing: 8),
                textAlign: TextAlign.center,
                decoration: const InputDecoration(
                  counterText: '',
                  labelText: 'Current 4-Digit PIN',
                  labelStyle: TextStyle(color: Colors.white70, fontSize: 14, letterSpacing: 0),
                  border: OutlineInputBorder(),
                ),
              ),
              if (errorText != null) ...[
                const SizedBox(height: 8),
                Text(errorText!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel', style: TextStyle(color: Colors.white60)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: googleBlue),
              onPressed: () async {
                final isValid = await _securityService.verifyPin(pinController.text.trim());
                if (isValid) {
                  if (ctx.mounted) Navigator.pop(ctx, true);
                } else {
                  setDialogState(() => errorText = 'Incorrect PIN');
                  if (ctx.mounted) {
                    StatusFeedbackDialog.showError(
                      ctx,
                      title: 'Incorrect PIN',
                      message: 'The entered PIN does not match.',
                    );
                  }
                }
              },
              child: const Text('Verify', style: TextStyle(color: Color(0xFF131314))),
            ),
          ],
        ),
      ),
    );

    return result ?? false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      // Only record pause time if not currently showing the system biometric prompt
      if (!_securityService.isAuthenticating) {
        _lastPausedTime = DateTime.now();
      }
    } else if (state == AppLifecycleState.resumed) {
      // Resume web timers
      for (final controller in _controllers.values) {
        controller.resume();
      }

      // If biometric prompt is showing or lock screen is already open, ignore
      if (_securityService.isAuthenticating || _isLocked) {
        return;
      }

      // If unlocked very recently (< 3 seconds ago), ignore
      if (_lastUnlockedTime != null &&
          DateTime.now().difference(_lastUnlockedTime!).inSeconds < 3) {
        return;
      }

      if (_lastPausedTime != null) {
        final elapsed = DateTime.now().difference(_lastPausedTime!).inSeconds;
        _lastPausedTime = null; // Consume paused timestamp immediately

        _securityService.getLockTimeoutSeconds().then((timeout) async {
          if (elapsed >= timeout) {
            final isEnabled = await _securityService.isLockEnabled();
            if (isEnabled && mounted) {
              setState(() {
                _isLocked = true;
              });
            }
          }
        });
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _notificationClickSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLocked) {
      return LockScreen(
        securityService: _securityService,
        onUnlocked: () {
          setState(() {
            _isLocked = false;
            _lastUnlockedTime = DateTime.now();
            _lastPausedTime = null;
          });
        },
      );
    }

    if (_isLoading) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    final activeInstance =
        _instances.isNotEmpty && _currentIndex < _instances.length
            ? _instances[_currentIndex]
            : null;

    final activeController =
        activeInstance != null ? _controllers[activeInstance.uuid] : null;

    return Scaffold(
      backgroundColor: const Color(0xFF131314),
      drawer: _buildLeftDrawer(),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E1F22),
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: Builder(
          builder: (context) => IconButton(
            tooltip: 'Devices Menu',
            icon: const Icon(Icons.chevron_right, size: 28, color: Colors.white),
            onPressed: () => Scaffold.of(context).openDrawer(),
          ),
        ),
        title: activeInstance != null
            ? InkWell(
                onTap: () => _showRenameDialog(_currentIndex),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          activeInstance.customName,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 18,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      if (activeInstance.isDefault) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: Colors.amber.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                                color: Colors.amber.withValues(alpha: 0.5),
                                width: 0.5),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.star, color: Colors.amber, size: 11),
                              SizedBox(width: 3),
                              Text('Default',
                                  style: TextStyle(
                                      color: Colors.amber,
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ),
                      ],
                      if (activeInstance.isHidden) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: Colors.white12,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text('Hidden',
                              style: TextStyle(
                                  color: Colors.white54, fontSize: 10)),
                        ),
                      ],
                      const SizedBox(width: 6),
                      const Icon(Icons.edit, size: 16, color: Colors.white60),
                    ],
                  ),
                ),
              )
            : const Text(
                'Multi-Message Hub',
                style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
              ),
        actions: [
          if (activeInstance != null)
            IconButton(
              tooltip: 'Reload Instance',
              icon: const Icon(Icons.refresh),
              onPressed: () {
                activeController?.reload();
                StatusFeedbackDialog.showInfo(
                  context,
                  title: 'Reloading',
                  message: 'Refreshing "${activeInstance.customName}"...',
                );
              },
            ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: Colors.white),
            onSelected: (val) {
              switch (val) {
                case 'toggle_default':
                  _setDefaultProfile(_currentIndex);
                  break;
                case 'toggle_hide':
                  _toggleHideProfile(_currentIndex);
                  break;
                case 'toggle_view':
                  if (activeInstance != null) {
                    final newMode = !activeInstance.mobileMode;
                    setState(() {
                      _instances[_currentIndex] =
                          activeInstance.copyWith(mobileMode: newMode);
                    });
                    _storageService.saveInstances(_instances);
                    activeController?.setMobileMode(newMode);
                    StatusFeedbackDialog.showSuccess(
                      context,
                      title: newMode ? 'Phone View Active' : 'Web View Active',
                      message: newMode
                          ? 'Optimized for mobile screen fit.'
                          : 'Desktop web layout enabled.',
                    );
                  }
                  break;
                case 'delete':
                  _deleteInstance(_currentIndex);
                  break;
                case 'settings':
                  _showSettingsScreen();
                  break;
                case 'pair_guide':
                  _showPairingGuide();
                  break;
              }
            },
            itemBuilder: (ctx) => [
              if (activeInstance != null) ...[
                PopupMenuItem(
                  value: 'toggle_default',
                  child: Row(
                    children: [
                      Icon(
                        activeInstance.isDefault
                            ? Icons.star
                            : Icons.star_outline,
                        color: Colors.amber,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        activeInstance.isDefault
                            ? 'Remove Default'
                            : 'Set as Default Device',
                        style: const TextStyle(color: Colors.white),
                      ),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'toggle_hide',
                  child: Row(
                    children: [
                      Icon(
                        activeInstance.isHidden
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                        color: const Color(0xFF8AB4F8),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        activeInstance.isHidden
                            ? 'Unhide Device'
                            : 'Hide Device',
                        style: const TextStyle(color: Colors.white),
                      ),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'toggle_view',
                  child: Row(
                    children: [
                      Icon(
                        activeInstance.mobileMode
                            ? Icons.desktop_windows
                            : Icons.stay_current_portrait,
                        color: const Color(0xFF8AB4F8),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        activeInstance.mobileMode
                            ? 'Switch to Web View'
                            : 'Switch to Phone View',
                        style: const TextStyle(color: Colors.white),
                      ),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'delete',
                  child: Row(
                    children: [
                      Icon(Icons.delete_outline, color: Colors.redAccent),
                      SizedBox(width: 10),
                      Text('Delete Device', style: TextStyle(color: Colors.redAccent)),
                    ],
                  ),
                ),
              ],
              const PopupMenuItem(
                value: 'settings',
                child: Row(
                  children: [
                    Icon(Icons.settings_outlined, color: Color(0xFF8AB4F8)),
                    SizedBox(width: 10),
                    Text('Settings', style: TextStyle(color: Colors.white)),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'pair_guide',
                child: Row(
                  children: [
                    Icon(Icons.help_outline, color: Color(0xFF8AB4F8)),
                    SizedBox(width: 10),
                    Text('Pairing Guide', style: TextStyle(color: Colors.white)),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // Multi-profile notice if not supported
          if (!_isMultiProfileSupported)
            Container(
              color: Colors.amber.shade900.withValues(alpha: 0.3),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: const Row(
                children: [
                  Icon(Icons.info_outline, size: 16, color: Colors.amber),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Multi-Profile WebKit is using fallback mode on this device.',
                      style: TextStyle(fontSize: 12, color: Colors.white70),
                    ),
                  ),
                ],
              ),
            ),

          // Main Viewport (full-width below appbar, white horizontal bar removed)
          Expanded(
            child: _instances.isEmpty
                ? _buildEmptyState()
                : IndexedStack(
                    index: _currentIndex,
                    children: _instances.map((instance) {
                      return IsolatedWebViewWidget(
                        key: ValueKey(instance.uuid),
                        uuid: instance.uuid,
                        customName: instance.customName,
                        mobileMode: instance.mobileMode,
                        onNotificationReceived: _handleIncomingNotification,
                        onGoogleSignInAttempted: _handleGoogleSignInAttempted,
                        onControllerCreated: (controller) {
                          _controllers[instance.uuid] = controller;
                        },
                      );
                    }).toList(),
                  ),
          ),
        ],
      ),
      floatingActionButton: _instances.isEmpty
          ? FloatingActionButton.extended(
              onPressed: _showAddDialog,
              icon: const Icon(Icons.add),
              label: const Text('Add First Phone'),
            )
          : null,
    );
  }

  Widget _buildLeftDrawer() {
    const darkSurface = Color(0xFF1E1F22);
    const darkBackground = Color(0xFF131314);
    const googleBlue = Color(0xFF8AB4F8);

    final visibleEntries = _instances
        .asMap()
        .entries
        .where((e) => !e.value.isHidden)
        .toList();
    final hiddenEntries = _instances
        .asMap()
        .entries
        .where((e) => e.value.isHidden)
        .toList();

    return Drawer(
      backgroundColor: darkSurface,
      child: Column(
        children: [
          // Header
          Container(
            padding: EdgeInsets.only(
              top: MediaQuery.of(context).padding.top + 16,
              left: 20,
              right: 20,
              bottom: 18,
            ),
            width: double.infinity,
            decoration: const BoxDecoration(
              color: darkBackground,
              border: Border(
                bottom: BorderSide(color: Color(0xFF2B2D31), width: 1),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.asset(
                        'assets/icons/app_logo.png',
                        width: 44,
                        height: 44,
                        fit: BoxFit.cover,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Multi-Message Hub',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                                decoration: BoxDecoration(
                                  color: googleBlue.withValues(alpha: 0.2),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: const Text(
                                  'DEV: RIAN ISLAM',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: googleBlue,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                '${_instances.length} ${_instances.length == 1 ? "device" : "devices"}',
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Colors.white70,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // Device Switcher List
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 10, bottom: 8),
                  child: Text(
                    'PAIRED DEVICES (${visibleEntries.length})',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.8,
                      color: Colors.white54,
                    ),
                  ),
                ),

                if (_instances.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16.0),
                    child: Text(
                      'No devices paired yet. Tap below to add your first device!',
                      style: TextStyle(color: Colors.white54, fontSize: 13),
                    ),
                  )
                else if (visibleEntries.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16.0),
                    child: Text(
                      'All devices are currently hidden. Expand "Hidden Devices" below to view or unhide.',
                      style: TextStyle(color: Colors.white54, fontSize: 13),
                    ),
                  )
                else
                  ...visibleEntries.map((entry) {
                    final index = entry.key;
                    final instance = entry.value;
                    final isSelected = index == _currentIndex;

                    return Container(
                      margin: const EdgeInsets.only(bottom: 4),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? googleBlue.withValues(alpha: 0.15)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(12),
                        border: isSelected
                            ? Border.all(
                                color: googleBlue.withValues(alpha: 0.35))
                            : null,
                      ),
                      child: ListTile(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        leading: Icon(
                          Icons.phone_android,
                          color: isSelected ? googleBlue : Colors.white70,
                        ),
                        title: Row(
                          children: [
                            Flexible(
                              child: Text(
                                instance.customName,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontWeight: isSelected
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                  color: isSelected ? googleBlue : Colors.white,
                                ),
                              ),
                            ),
                            if (instance.isDefault) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 5, vertical: 1),
                                decoration: BoxDecoration(
                                  color: Colors.amber.withValues(alpha: 0.2),
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(
                                      color:
                                          Colors.amber.withValues(alpha: 0.5),
                                      width: 0.5),
                                ),
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.star,
                                        color: Colors.amber, size: 10),
                                    SizedBox(width: 2),
                                    Text(
                                      'Default',
                                      style: TextStyle(
                                        color: Colors.amber,
                                        fontSize: 9.5,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ],
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (instance.unreadCount > 0)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                  vertical: 2,
                                ),
                                margin: const EdgeInsets.only(right: 4),
                                decoration: BoxDecoration(
                                  color: Colors.redAccent,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  '${instance.unreadCount}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            PopupMenuButton<String>(
                              icon: const Icon(Icons.more_vert,
                                  size: 18, color: Colors.white54),
                              onSelected: (val) {
                                Navigator.pop(context);
                                if (val == 'default') {
                                  _setDefaultProfile(index);
                                } else if (val == 'hide') {
                                  _toggleHideProfile(index);
                                } else if (val == 'rename') {
                                  _showRenameDialog(index);
                                } else if (val == 'reload') {
                                  _controllers[instance.uuid]?.reload();
                                  StatusFeedbackDialog.showInfo(
                                    context,
                                    title: 'Reloading',
                                    message:
                                        'Refreshing "${instance.customName}"...',
                                  );
                                } else if (val == 'delete') {
                                  _deleteInstance(index);
                                }
                              },
                              itemBuilder: (ctx) => [
                                PopupMenuItem(
                                  value: 'default',
                                  child: Row(
                                    children: [
                                      Icon(
                                        instance.isDefault
                                            ? Icons.star
                                            : Icons.star_outline,
                                        size: 18,
                                        color: Colors.amber,
                                      ),
                                      const SizedBox(width: 8),
                                      Text(instance.isDefault
                                          ? 'Remove Default'
                                          : 'Set as Default'),
                                    ],
                                  ),
                                ),
                                const PopupMenuItem(
                                  value: 'hide',
                                  child: Row(
                                    children: [
                                      Icon(Icons.visibility_off_outlined,
                                          size: 18, color: Colors.white70),
                                      SizedBox(width: 8),
                                      Text('Hide Device'),
                                    ],
                                  ),
                                ),
                                const PopupMenuItem(
                                  value: 'rename',
                                  child: Row(
                                    children: [
                                      Icon(Icons.edit, size: 18),
                                      SizedBox(width: 8),
                                      Text('Rename'),
                                    ],
                                  ),
                                ),
                                const PopupMenuItem(
                                  value: 'reload',
                                  child: Row(
                                    children: [
                                      Icon(Icons.refresh, size: 18),
                                      SizedBox(width: 8),
                                      Text('Reload'),
                                    ],
                                  ),
                                ),
                                const PopupMenuItem(
                                  value: 'delete',
                                  child: Row(
                                    children: [
                                      Icon(Icons.delete_outline,
                                          size: 18, color: Colors.red),
                                      SizedBox(width: 8),
                                      Text('Delete Profile',
                                          style: TextStyle(color: Colors.red)),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                        onTap: () {
                          setState(() {
                            _currentIndex = index;
                            _instances[index] =
                                _instances[index].copyWith(unreadCount: 0);
                          });
                          _storageService.saveInstances(_instances);
                          Navigator.pop(context);
                        },
                      ),
                    );
                  }),

                if (hiddenEntries.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.03),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white10),
                    ),
                    child: Theme(
                      data: Theme.of(context)
                          .copyWith(dividerColor: Colors.transparent),
                      child: ExpansionTile(
                        initiallyExpanded: false,
                        tilePadding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 0),
                        leading: const Icon(Icons.visibility_off_outlined,
                            color: Colors.white54, size: 20),
                        title: Text(
                          'HIDDEN DEVICES (${hiddenEntries.length})',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.8,
                            color: Colors.white54,
                          ),
                        ),
                        children: hiddenEntries.map((entry) {
                          final index = entry.key;
                          final instance = entry.value;
                          final isSelected = index == _currentIndex;

                          return Container(
                            margin: const EdgeInsets.only(
                                left: 8, right: 8, bottom: 4),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? googleBlue.withValues(alpha: 0.12)
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: ListTile(
                              dense: true,
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10)),
                              leading: Icon(
                                Icons.phone_android,
                                color:
                                    isSelected ? googleBlue : Colors.white38,
                                size: 20,
                              ),
                              title: Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      instance.customName,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: isSelected
                                            ? googleBlue
                                            : Colors.white60,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 4, vertical: 1),
                                    decoration: BoxDecoration(
                                      color: Colors.white10,
                                      borderRadius: BorderRadius.circular(3),
                                    ),
                                    child: const Text('Hidden',
                                        style: TextStyle(
                                            color: Colors.white38,
                                            fontSize: 9)),
                                  ),
                                  if (instance.isDefault) ...[
                                    const SizedBox(width: 4),
                                    const Icon(Icons.star,
                                        color: Colors.amber, size: 12),
                                  ],
                                ],
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.visibility_outlined,
                                        size: 18, color: googleBlue),
                                    tooltip: 'Unhide Device',
                                    onPressed: () {
                                      _toggleHideProfile(index);
                                    },
                                  ),
                                  PopupMenuButton<String>(
                                    icon: const Icon(Icons.more_vert,
                                        size: 16, color: Colors.white38),
                                    onSelected: (val) {
                                      Navigator.pop(context);
                                      if (val == 'unhide') {
                                        _toggleHideProfile(index);
                                      } else if (val == 'default') {
                                        _setDefaultProfile(index);
                                      } else if (val == 'rename') {
                                        _showRenameDialog(index);
                                      } else if (val == 'reload') {
                                        _controllers[instance.uuid]?.reload();
                                      } else if (val == 'delete') {
                                        _deleteInstance(index);
                                      }
                                    },
                                    itemBuilder: (ctx) => [
                                      const PopupMenuItem(
                                        value: 'unhide',
                                        child: Row(
                                          children: [
                                            Icon(Icons.visibility_outlined,
                                                size: 18, color: googleBlue),
                                            SizedBox(width: 8),
                                            Text('Unhide Device'),
                                          ],
                                        ),
                                      ),
                                      PopupMenuItem(
                                        value: 'default',
                                        child: Row(
                                          children: [
                                            Icon(
                                              instance.isDefault
                                                  ? Icons.star
                                                  : Icons.star_outline,
                                              size: 18,
                                              color: Colors.amber,
                                            ),
                                            const SizedBox(width: 8),
                                            Text(instance.isDefault
                                                ? 'Remove Default'
                                                : 'Set as Default'),
                                          ],
                                        ),
                                      ),
                                      const PopupMenuItem(
                                        value: 'rename',
                                        child: Row(
                                          children: [
                                            Icon(Icons.edit, size: 18),
                                            SizedBox(width: 8),
                                            Text('Rename'),
                                          ],
                                        ),
                                      ),
                                      const PopupMenuItem(
                                        value: 'delete',
                                        child: Row(
                                          children: [
                                            Icon(Icons.delete_outline,
                                                size: 18, color: Colors.red),
                                            SizedBox(width: 8),
                                            Text('Delete Profile',
                                                style: TextStyle(
                                                    color: Colors.red)),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                              onTap: () {
                                setState(() {
                                  _currentIndex = index;
                                  _instances[index] = _instances[index]
                                      .copyWith(unreadCount: 0);
                                });
                                _storageService.saveInstances(_instances);
                                Navigator.pop(context);
                              },
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ),
                ],

                const SizedBox(height: 10),

                // Add Device Button
                InkWell(
                  onTap: () {
                    Navigator.pop(context);
                    _showAddDialog();
                  },
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF282A2E),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: googleBlue.withValues(alpha: 0.2)),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.add_circle_outline, color: googleBlue),
                        SizedBox(width: 12),
                        Text(
                          'Add Device / SIM',
                          style: TextStyle(
                            color: googleBlue,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                const Divider(height: 28, color: Color(0xFF2B2D31)),

                ListTile(
                  leading: const Icon(Icons.help_outline, color: Colors.white70),
                  title: const Text('Pairing Guide', style: TextStyle(color: Colors.white70)),
                  onTap: () {
                    Navigator.pop(context);
                    _showPairingGuide();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.settings_outlined, color: googleBlue),
                  title: const Text(
                    'Settings',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  subtitle: const Text(
                    'App lock, sync notification, battery, about',
                    style: TextStyle(color: Colors.white54, fontSize: 11),
                  ),
                  onTap: () {
                    Navigator.pop(context);
                    _showSettingsScreen();
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.system_update_alt_rounded, color: googleBlue),
                  title: const Text(
                    'Check for Updates',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  subtitle: Text(
                    'v${UpdateService.currentAppVersion} • GitHub Releases',
                    style: const TextStyle(color: Colors.white54, fontSize: 11),
                  ),
                  onTap: () {
                    Navigator.pop(context);
                    _checkForUpdates(isManual: true);
                  },
                ),
              ],
            ),
          ),

          // Footer
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: const BoxDecoration(
              border: Border(
                top: BorderSide(color: Color(0xFF2B2D31), width: 1),
              ),
            ),
            child: Row(
              children: [
                const Icon(Icons.security, size: 16, color: Colors.white54),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Multi-Profile Isolation • RIAN ISLAM',
                    style: TextStyle(fontSize: 11, color: Colors.white54),
                  ),
                ),
                Text(
                  'v${UpdateService.currentAppVersion}',
                  style: TextStyle(fontSize: 10, color: googleBlue.withValues(alpha: 0.8), fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    const googleBlue = Color(0xFF8AB4F8);

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: googleBlue.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: Image.asset(
                  'assets/icons/app_logo.png',
                  width: 76,
                  height: 76,
                  fit: BoxFit.cover,
                ),
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'No Paired Devices Yet',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Connect multiple secondary phones via Google Messages for Web simultaneously. Each device runs in a strictly isolated Android WebView profile with dedicated cookies and pairing keys.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: Colors.white70,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 28),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: googleBlue,
                foregroundColor: const Color(0xFF131314),
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed: _showAddDialog,
              icon: const Icon(Icons.add),
              label: const Text(
                'Pair Your First Phone',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(height: 36),
            Card(
              elevation: 0,
              color: const Color(0xFF1E1F22),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: const BorderSide(color: Color(0xFF2B2D31)),
              ),
              child: const Padding(
                padding: EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.lightbulb_outline, size: 20, color: Colors.amber),
                        SizedBox(width: 8),
                        Text(
                          'Quick Pairing Steps',
                          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
                        ),
                      ],
                    ),
                    SizedBox(height: 10),
                    Text(
                      '1. Tap "Pair Your First Phone" and enter a name.',
                      style: TextStyle(color: Colors.white70),
                    ),
                    SizedBox(height: 4),
                    Text(
                      '2. Tap "Sign in with Google" or "Switch to QR pairing".',
                      style: TextStyle(color: Colors.white70),
                    ),
                    SizedBox(height: 4),
                    Text(
                      '3. Verify via matching emoji on your phone, or scan the QR code.',
                      style: TextStyle(color: Colors.white70),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
