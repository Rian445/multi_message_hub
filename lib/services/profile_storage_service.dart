import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/profile_instance.dart';

class ProfileStorageService {
  static const String _keyInstances = 'multi_message_hub_instances';
  static const String _keyBatteryPromptShown = 'has_shown_battery_prompt';
  static const String _keyBackgroundSync = 'pref_background_sync_enabled';

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
    final jsonStr = prefs.getString(_keyInstances);
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

  Future<void> saveInstances(List<ProfileInstance> instances) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonList = instances.map((inst) => inst.toMap()).toList();
    await prefs.setString(_keyInstances, json.encode(jsonList));
  }
}
