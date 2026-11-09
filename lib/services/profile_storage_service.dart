import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/profile_instance.dart';

class ProfileStorageService {
  static const String _keyInstances = 'multi_message_hub_instances';
  static const String _keyBatteryPromptShown = 'has_shown_battery_prompt';
  static const String _keyBackgroundSync = 'pref_background_sync_enabled';
  static const String _keyDefaultProfileUuid = 'pref_default_profile_uuid';

  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage(
    aOptions: AndroidOptions(
      resetOnError: true,
    ),
  );

  Future<String?> getDefaultProfileUuid() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyDefaultProfileUuid);
  }

  Future<void> setDefaultProfileUuid(String? uuid) async {
    final prefs = await SharedPreferences.getInstance();
    if (uuid == null) {
      await prefs.remove(_keyDefaultProfileUuid);
    } else {
      await prefs.setString(_keyDefaultProfileUuid, uuid);
    }
  }

  Future<bool> isBackgroundSyncEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyBackgroundSync) ?? true;
  }

  Future<void> setBackgroundSyncEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyBackgroundSync, enabled);
  }

  Future<bool> hasBatteryPromptBeenShown() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyBatteryPromptShown) ?? false;
  }

  Future<void> setBatteryPromptShown() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyBatteryPromptShown, true);
  }

  /// Loads profile instances from hardware-backed encrypted storage
  /// with transparent migration from legacy SharedPreferences.
  Future<List<ProfileInstance>> loadInstances() async {
    String? jsonStr;
    try {
      jsonStr = await _secureStorage.read(key: _keyInstances);
    } catch (_) {
      // Keystore fallback
    }

    // Transparent migration from legacy SharedPreferences
    if (jsonStr == null || jsonStr.isEmpty) {
      final prefs = await SharedPreferences.getInstance();
      final rawStr = prefs.getString(_keyInstances);
      if (rawStr != null && rawStr.isNotEmpty) {
        if (rawStr.startsWith('b64:')) {
          try {
            jsonStr = utf8.decode(base64.decode(rawStr.substring(4)));
          } catch (_) {
            jsonStr = rawStr;
          }
        } else {
          jsonStr = rawStr;
        }

        // Migrate to hardware-encrypted secure storage and remove from SharedPreferences
        if (jsonStr.isNotEmpty) {
          try {
            await _secureStorage.write(key: _keyInstances, value: jsonStr);
            await prefs.remove(_keyInstances);
          } catch (_) {}
        }
      }
    }

    if (jsonStr == null || jsonStr.isEmpty) {
      return [];
    }

    try {
      final List<dynamic> list = json.decode(jsonStr) as List<dynamic>;
      return list
          .map((item) => ProfileInstance.fromMap(item as Map<String, dynamic>))
          .toList();
    } catch (e) {
      return [];
    }
  }

  /// Encrypts and saves profile instances in Android Keystore
  Future<void> saveInstances(List<ProfileInstance> instances) async {
    final jsonList = instances.map((inst) => inst.toMap()).toList();
    final jsonStr = json.encode(jsonList);

    try {
      await _secureStorage.write(key: _keyInstances, value: jsonStr);
      // Remove any unencrypted legacy string from SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_keyInstances);
    } catch (_) {
      // Fallback if hardware keystore fails
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyInstances, jsonStr);
    }
  }
}
