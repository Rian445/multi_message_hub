import 'package:flutter/services.dart';

class ProfileManagerChannel {
  static const MethodChannel _channel =
      MethodChannel('com.multimessenger.hub/profile_manager');

  static Future<bool> isMultiProfileSupported() async {
    try {
      final bool? supported =
          await _channel.invokeMethod<bool>('isMultiProfileSupported');
      return supported ?? false;
    } catch (e) {
      return false;
    }
  }

  static Future<bool> deleteProfile(String uuid) async {
    try {
      final bool? success =
          await _channel.invokeMethod<bool>('deleteProfile', {'uuid': uuid});
      return success ?? false;
    } catch (e) {
      return false;
    }
  }

  static Future<List<String>> getAllProfiles() async {
    try {
      final List<dynamic>? profiles =
          await _channel.invokeMethod<List<dynamic>>('getAllProfiles');
      return profiles?.cast<String>() ?? [];
    } catch (e) {
      return [];
    }
  }

  static Future<bool> isBatteryOptimizationIgnored() async {
    try {
      final bool? ignored =
          await _channel.invokeMethod<bool>('isBatteryOptimizationIgnored');
      return ignored ?? false;
    } catch (e) {
      return false;
    }
  }

  static Future<bool> requestIgnoreBatteryOptimization() async {
    try {
      final bool? result =
          await _channel.invokeMethod<bool>('requestIgnoreBatteryOptimization');
      return result ?? false;
    } catch (e) {
      return false;
    }
  }

  static Future<bool> openUrl(String url) async {
    try {
      final bool? result =
          await _channel.invokeMethod<bool>('openUrl', {'url': url});
      return result ?? false;
    } catch (e) {
      return false;
    }
  }

  static Future<String?> getAppCacheDir() async {
    try {
      final String? path =
          await _channel.invokeMethod<String>('getAppCacheDir');
      return path;
    } catch (e) {
      return null;
    }
  }

  static Future<bool> installApk(String filePath) async {
    try {
      final bool? result =
          await _channel.invokeMethod<bool>('installApk', {'filePath': filePath});
      return result ?? false;
    } catch (e) {
      return false;
    }
  }
}
