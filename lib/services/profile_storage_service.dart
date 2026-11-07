import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/profile_instance.dart';

class ProfileStorageService {
  static const String _keyInstances = 'multi_message_hub_instances';

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
