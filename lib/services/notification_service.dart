import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();

  final StreamController<String> _onNotificationClick =
      StreamController<String>.broadcast();

  Stream<String> get onNotificationClick => _onNotificationClick.stream;

  static const String channelId = 'multi_message_channel';
  static const String channelName = 'Google Messages Alerts';
  static const String channelDescription =
      'Notifications from secondary paired Google Messages accounts';

  int _notificationIdCounter = 1000;

  Future<void> init() async {
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@drawable/ic_notification');

    const InitializationSettings initializationSettings =
        InitializationSettings(
      android: initializationSettingsAndroid,
    );

    await _notificationsPlugin.initialize(
      settings: initializationSettings,
      onDidReceiveNotificationResponse: (NotificationResponse response) {
        final payload = response.payload;
        if (payload != null && payload.isNotEmpty) {
          _onNotificationClick.add(payload);
        }
      },
    );

    // Create Notification Channel for Android 8.0+
    final AndroidNotificationChannel channel = AndroidNotificationChannel(
      channelId,
      channelName,
      description: channelDescription,
      importance: Importance.max,
      enableVibration: true,
      playSound: true,
    );

    final androidImplementation = _notificationsPlugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();

    if (androidImplementation != null) {
      await androidImplementation.createNotificationChannel(channel);
      await androidImplementation.requestNotificationsPermission();
    }
  }

  Future<void> showNotification({
    required String uuid,
    required String customName,
    required String sender,
    required String body,
  }) async {
    final AndroidNotificationDetails androidPlatformChannelSpecifics =
        AndroidNotificationDetails(
      channelId,
      channelName,
      channelDescription: channelDescription,
      importance: Importance.max,
      priority: Priority.high,
      icon: 'ic_notification',
      color: const Color(0xFF8AB4F8),
      ticker: 'New Google Message',
      styleInformation: BigTextStyleInformation(
        body,
        contentTitle: '[$customName] • $sender',
        summaryText: customName,
      ),
    );

    final NotificationDetails platformChannelSpecifics =
        NotificationDetails(android: androidPlatformChannelSpecifics);

    final int id = _notificationIdCounter++;
    await _notificationsPlugin.show(
      id: id,
      title: '[$customName] • $sender',
      body: body,
      notificationDetails: platformChannelSpecifics,
      payload: uuid,
    );
  }

  void dispose() {
    _onNotificationClick.close();
  }
}
