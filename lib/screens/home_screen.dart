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
import '../widgets/isolated_web_view_widget.dart';

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

    // Check if App Lock is enabled
    final isLockEnabled = await _securityService.isLockEnabled();

    setState(() {
      _instances = loaded;
      _isMultiProfileSupported = supported;
      _isLoading = false;
      _isLocked = isLockEnabled;
      if (_instances.isNotEmpty && _currentIndex >= _instances.length) {
        _currentIndex = 0;
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
    final newInstance = ProfileInstance(
      uuid: newUuid,
      customName: customName.trim().isEmpty ? 'Secondary SIM' : customName.trim(),
      createdAt: DateTime.now(),
      mobileMode: true,
    );

    setState(() {
      _instances.add(newInstance);
      _currentIndex = _instances.length - 1;
    });

    await _storageService.saveInstances(_instances);
    await _foregroundManager.startService(_instances.length);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Created profile "${newInstance.customName}". Scan QR to pair!'),
          duration: const Duration(seconds: 3),
        ),
      );
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Renamed to "$trimmed"'),
          duration: const Duration(seconds: 2),
        ),
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

      await _storageService.saveInstances(_instances);

      if (_instances.isNotEmpty) {
        await _foregroundManager.updateDeviceCount(_instances.length);
      } else {
        await _foregroundManager.stopService();
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Profile "${target.customName}" deleted.'),
          ),
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
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Multi-Message Hub',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    'Version 1.0.0 (Release)',
                    style: TextStyle(color: Colors.white60, fontSize: 11),
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
                          'MajorThug',
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

  void _showSettingsScreen() async {
    const googleBlue = Color(0xFF8AB4F8);
    bool isSyncEnabled = await _storageService.isBackgroundSyncEnabled();
    bool isLockEnabled = await _securityService.isLockEnabled();
    bool isBatteryIgnored =
        await ProfileManagerChannel.isBatteryOptimizationIgnored();

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
                      final messenger = ScaffoldMessenger.of(context);
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
                      messenger.showSnackBar(
                        SnackBar(
                          content: Text(val
                              ? 'Persistent notification & background sync enabled'
                              : 'Constant notification turned off'),
                          duration: const Duration(seconds: 2),
                        ),
                      );
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
                              ? 'Protected with 4-Digit PIN & Biometrics'
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
                  child: ListTile(
                    leading: const Icon(Icons.info_outline, color: googleBlue),
                    title: const Text(
                      'About Multi-Message Hub',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                    subtitle: const Text(
                      'Developer: MajorThug • Architecture & Specs',
                      style: TextStyle(color: Colors.white54, fontSize: 12),
                    ),
                    trailing:
                        const Icon(Icons.chevron_right, color: Colors.white38),
                    onTap: () {
                      Navigator.pop(ctx);
                      _showAboutDialog();
                    },
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
                    final messenger = ScaffoldMessenger.of(context);
                    final confirmed = await _promptCurrentPin();
                    if (confirmed) {
                      await _securityService.disableLock();
                      setDialogState(() {
                        isLockEnabled = false;
                      });
                      messenger.showSnackBar(
                        const SnackBar(content: Text('App Lock has been disabled.')),
                      );
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
                  return;
                }
                if (pin != confirm) {
                  setDialogState(() => errorText = 'PINs do not match. Try again.');
                  return;
                }
                await _securityService.enableLock(pin);
                if (context.mounted) {
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('App Lock is now active!')),
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
                  if (context.mounted) Navigator.pop(ctx, true);
                } else {
                  setDialogState(() => errorText = 'Incorrect PIN');
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
      _lastPausedTime = DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      // Resume web timers
      for (final controller in _controllers.values) {
        controller.resume();
      }

      if (_lastPausedTime != null &&
          DateTime.now().difference(_lastPausedTime!).inSeconds >= 2) {
        _securityService.isLockEnabled().then((enabled) {
          if (enabled && mounted) {
            setState(() {
              _isLocked = true;
            });
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
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Reloading "${activeInstance.customName}"...'),
                    duration: const Duration(seconds: 1),
                  ),
                );
              },
            ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: Colors.white),
            onSelected: (val) {
              switch (val) {
                case 'toggle_view':
                  if (activeInstance != null) {
                    final newMode = !activeInstance.mobileMode;
                    setState(() {
                      _instances[_currentIndex] =
                          activeInstance.copyWith(mobileMode: newMode);
                    });
                    _storageService.saveInstances(_instances);
                    activeController?.setMobileMode(newMode);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(newMode
                            ? 'Switched to Phone (Mobile) View'
                            : 'Switched to Web (Desktop) View'),
                        duration: const Duration(seconds: 1),
                      ),
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
                                  'DEV: MajorThug',
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
                const Padding(
                  padding: EdgeInsets.only(left: 10, bottom: 8),
                  child: Text(
                    'SWITCH DEVICE',
                    style: TextStyle(
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
                else
                  ..._instances.asMap().entries.map((entry) {
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
                            ? Border.all(color: googleBlue.withValues(alpha: 0.35))
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
                        title: Text(
                          instance.customName,
                          style: TextStyle(
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                            color: isSelected ? googleBlue : Colors.white,
                          ),
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
                              icon: const Icon(Icons.more_vert, size: 18, color: Colors.white54),
                              onSelected: (val) {
                                Navigator.pop(context);
                                if (val == 'rename') {
                                  _showRenameDialog(index);
                                } else if (val == 'reload') {
                                  _controllers[instance.uuid]?.reload();
                                } else if (val == 'delete') {
                                  _deleteInstance(index);
                                }
                              },
                              itemBuilder: (ctx) => [
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
                                      Icon(Icons.delete_outline, size: 18, color: Colors.red),
                                      SizedBox(width: 8),
                                      Text('Delete Profile', style: TextStyle(color: Colors.red)),
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
                            _instances[index] = _instances[index].copyWith(unreadCount: 0);
                          });
                          _storageService.saveInstances(_instances);
                          Navigator.pop(context);
                        },
                      ),
                    );
                  }),

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
                    'Multi-Profile Isolation • MajorThug',
                    style: TextStyle(fontSize: 11, color: Colors.white54),
                  ),
                ),
                Text(
                  'v1.0.0',
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
