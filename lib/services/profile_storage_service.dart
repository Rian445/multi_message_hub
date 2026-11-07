import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/profile_instance.dart';

class ProfileStorageService {
  static const String _keyInstances = 'multi_message_hub_instances';
  static const String _keyBatteryPromptShown = 'has_shown_battery_prompt';
  static const String _keyBackgroundSync = 'pref_background_sync_enabled';
  static const String _keyDefaultProfileUuid = 'pref_default_profile_uuid';

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

  Future<List<ProfileInstance>> loadInstances() async {
    final prefs = await SharedPreferences.getInstance();
    final rawStr = prefs.getString(_keyInstances);
    if (rawStr == null || rawStr.isEmpty) {
      return [];
    }
    try {
      String jsonStr = rawStr;
      if (rawStr.startsWith('b64:')) {
        jsonStr = utf8.decode(base64.decode(rawStr.substring(4)));
      }
      final List<dynamic> list = json.decode(jsonStr) as List<dynamic>;
      return list
          .map((item) => ProfileInstance.fromMap(item as Map<String, dynamic>))
          .toList();
    } catch (e) {
      return [];
    }
  }

  Future<void> saveInstances(List<ProfileInstance> instances) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonList = instances.map((inst) => inst.toMap()).toList();
    final jsonStr = json.encode(jsonList);
    final encoded = 'b64:${base64.encode(utf8.encode(jsonStr))}';
    await prefs.setString(_keyInstances, encoded);
  }
}
