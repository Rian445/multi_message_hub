import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SecurityService {
  static const String _keyLockEnabled = 'sec_lock_enabled';
  static const String _keyPin = 'sec_pin_code';
  static const String _keyBiometrics = 'sec_biometrics_enabled';
  static const String _keyTimeout = 'sec_lock_timeout_seconds';

  final LocalAuthentication _localAuth = LocalAuthentication();
  bool isAuthenticating = false;

  Future<int> getLockTimeoutSeconds() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_keyTimeout) ?? 0; // Default 0 = Immediate
  }

  Future<void> setLockTimeoutSeconds(int seconds) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyTimeout, seconds);
  }

  Future<bool> isLockEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyLockEnabled) ?? false;
  }

  Future<bool> isBiometricsEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyBiometrics) ?? true;
  }

  Future<bool> hasPin() async {
    final prefs = await SharedPreferences.getInstance();
    final pin = prefs.getString(_keyPin);
    return pin != null && pin.isNotEmpty;
  }

  Future<bool> verifyPin(String enteredPin) async {
    final prefs = await SharedPreferences.getInstance();
    final savedPin = prefs.getString(_keyPin);
    return savedPin != null && savedPin == enteredPin;
  }

  Future<void> enableLock(String pin, {bool useBiometrics = true}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyPin, pin);
    await prefs.setBool(_keyLockEnabled, true);
    await prefs.setBool(_keyBiometrics, useBiometrics);
  }

  Future<void> setBiometricsEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyBiometrics, enabled);
  }

  Future<void> disableLock() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyPin);
    await prefs.setBool(_keyLockEnabled, false);
  }

  Future<bool> canCheckBiometrics() async {
    try {
      final canAuthenticateWithBiometrics = await _localAuth.canCheckBiometrics;
      final canAuthenticate = canAuthenticateWithBiometrics || await _localAuth.isDeviceSupported();
      return canAuthenticate;
    } catch (_) {
      return false;
    }
  }

  Future<bool> authenticateBiometrics() async {
    if (isAuthenticating) return false;
    isAuthenticating = true;
    try {
      final canAuth = await canCheckBiometrics();
      if (!canAuth) return false;

      final result = await _localAuth.authenticate(
        localizedReason: 'Authenticate to unlock Multi-Message Hub',
        biometricOnly: false,
      );
      return result;
    } on PlatformException catch (_) {
      return false;
    } catch (_) {
      return false;
    } finally {
      Future.delayed(const Duration(milliseconds: 1500), () {
        isAuthenticating = false;
      });
    }
  }
}
