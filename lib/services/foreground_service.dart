import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'profile_manager_channel.dart';

@pragma('vm:entry-point')
void startHubForegroundCallback() {
  FlutterForegroundTask.setTaskHandler(HubForegroundTaskHandler());
}

class HubForegroundTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}

  @override
  void onReceiveData(Object data) {}

  @override
  void onNotificationButtonPressed(String id) {}

  @override
  void onNotificationPressed() {
    FlutterForegroundTask.launchApp();
  }

  @override
  void onNotificationDismissed() {}
}

class ForegroundServiceManager {
  static final ForegroundServiceManager _instance =
      ForegroundServiceManager._internal();
  factory ForegroundServiceManager() => _instance;
  ForegroundServiceManager._internal();

  bool _isInitialized = false;

  Future<void> init() async {
    if (_isInitialized) return;

    FlutterForegroundTask.initCommunicationPort();

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'multi_message_hub_fg',
        channelName: 'Multi-Message Hub Background Service',
        channelDescription:
            'Maintains live connections to secondary Google Messages accounts',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        enableVibration: false,
        playSound: false,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );

    _isInitialized = true;
  }

  Future<void> startService(int deviceCount) async {
    await init();

    if (await FlutterForegroundTask.isRunningService) {
      await updateDeviceCount(deviceCount);
      return;
    }

    final statusText = deviceCount == 1
        ? '1 device active'
        : '$deviceCount devices active';

    await FlutterForegroundTask.startService(
      serviceId: 256,
      notificationTitle: 'Multi-Message Hub',
      notificationText: statusText,
      callback: startHubForegroundCallback,
    );
  }

  Future<void> updateDeviceCount(int deviceCount) async {
    if (await FlutterForegroundTask.isRunningService) {
      final statusText = deviceCount == 1
          ? '1 device active'
          : '$deviceCount devices active';

      await FlutterForegroundTask.updateService(
        notificationTitle: 'Multi-Message Hub',
        notificationText: statusText,
      );
    }
  }

  Future<void> stopService() async {
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
  }

  Future<void> requestBatteryExemption() async {
    await ProfileManagerChannel.requestIgnoreBatteryOptimization();
  }
}
