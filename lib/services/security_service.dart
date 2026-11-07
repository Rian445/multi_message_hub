import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PinVerifyResult {
  final bool isValid;
  final bool isLockedOut;
  final int remainingLockoutSeconds;
  final int failedAttempts;
  final String? message;

  const PinVerifyResult({
    required this.isValid,
    this.isLockedOut = false,
    this.remainingLockoutSeconds = 0,
    this.failedAttempts = 0,
    this.message,
  });
}

class SecurityService {
  static const String _keyLockEnabled = 'sec_lock_enabled';
  static const String _keyPinHash = 'sec_pin_hash';
  static const String _keyPinSalt = 'sec_pin_salt';
  static const String _keyLegacyPin = 'sec_pin_code'; // For transparent migration
  static const String _keyBiometrics = 'sec_biometrics_enabled';
  static const String _keyTimeout = 'sec_lock_timeout_seconds';
  static const String _keyFailedAttempts = 'sec_failed_pin_attempts';
  static const String _keyLockoutUntil = 'sec_lockout_until_timestamp';

  final LocalAuthentication _localAuth = LocalAuthentication();
  bool isAuthenticating = false;

  /// Cryptographic salt generation via Random.secure()
  String _generateSalt() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (i) => random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Salted SHA-256 with 10,000 rounds of key stretching
  String _computeHash(String pin, String salt) {
    final saltBytes = utf8.encode(salt);
    final pinBytes = utf8.encode(pin);
    var digest = sha256.convert([...saltBytes, ...pinBytes]);
    for (int i = 0; i < 9999; i++) {
      digest = sha256.convert([...digest.bytes, ...saltBytes, ...pinBytes]);
    }
    return digest.toString();
  }

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
    final hash = prefs.getString(_keyPinHash);
    if (hash != null && hash.isNotEmpty) return true;
    final legacy = prefs.getString(_keyLegacyPin);
    return legacy != null && legacy.isNotEmpty;
  }

  /// Check remaining lockout seconds if currently locked out
  Future<int> getRemainingLockoutSeconds() async {
    final prefs = await SharedPreferences.getInstance();
    final lockoutUntil = prefs.getInt(_keyLockoutUntil) ?? 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (lockoutUntil > now) {
      return ((lockoutUntil - now) / 1000).ceil();
    }
    // Expired lockout
    if (lockoutUntil > 0) {
      await prefs.remove(_keyLockoutUntil);
    }
    return 0;
  }

  /// Detailed PIN verification with progressive rate-limiting & lockout
  Future<PinVerifyResult> verifyPinDetailed(String enteredPin) async {
    final prefs = await SharedPreferences.getInstance();

    // 1. Check if user is currently locked out
    final remainingLockout = await getRemainingLockoutSeconds();
    if (remainingLockout > 0) {
      final attempts = prefs.getInt(_keyFailedAttempts) ?? 0;
      return PinVerifyResult(
        isValid: false,
        isLockedOut: true,
        remainingLockoutSeconds: remainingLockout,
        failedAttempts: attempts,
        message: 'Too many failed attempts. Locked for ${remainingLockout}s.',
      );
    }

    // 2. Retrieve hash and salt (with transparent legacy migration)
    String? hash = prefs.getString(_keyPinHash);
    String? salt = prefs.getString(_keyPinSalt);

    if (hash == null || salt == null) {
      final legacyPin = prefs.getString(_keyLegacyPin);
      if (legacyPin != null && legacyPin.isNotEmpty) {
        // Transparent migration: hash legacy plaintext PIN
        salt = _generateSalt();
        hash = _computeHash(legacyPin, salt);
        await prefs.setString(_keyPinSalt, salt);
        await prefs.setString(_keyPinHash, hash);
        await prefs.remove(_keyLegacyPin);
      }
    }

    if (hash == null || salt == null) {
      return const PinVerifyResult(
        isValid: false,
        message: 'No PIN is set.',
      );
    }

    // 3. Compute hash of entered PIN
    final computedHash = _computeHash(enteredPin, salt);
    final isMatch = computedHash == hash;

    if (isMatch) {
      // Success: reset failed attempt counter and lockout
      await prefs.remove(_keyFailedAttempts);
      await prefs.remove(_keyLockoutUntil);
      return const PinVerifyResult(isValid: true);
    } else {
      // Failure: increment attempt counter and apply exponential backoff
      final failedAttempts = (prefs.getInt(_keyFailedAttempts) ?? 0) + 1;
      await prefs.setInt(_keyFailedAttempts, failedAttempts);

      int lockoutDuration = 0;
      if (failedAttempts >= 15) {
        lockoutDuration = 900; // 15 minutes lockout
      } else if (failedAttempts >= 10) {
        lockoutDuration = 300; // 5 minutes lockout
      } else if (failedAttempts >= 5) {
        lockoutDuration = 30; // 30 seconds lockout
      }

      if (lockoutDuration > 0) {
        final lockoutUntil = DateTime.now().millisecondsSinceEpoch + (lockoutDuration * 1000);
        await prefs.setInt(_keyLockoutUntil, lockoutUntil);
        return PinVerifyResult(
          isValid: false,
          isLockedOut: true,
          remainingLockoutSeconds: lockoutDuration,
          failedAttempts: failedAttempts,
          message: 'Too many incorrect attempts. Locked for ${lockoutDuration}s.',
        );
      }

      final attemptsLeft = 5 - failedAttempts;
      final warningMsg = attemptsLeft > 0
          ? 'Incorrect PIN. $attemptsLeft attempt(s) before temporary lock.'
          : 'Incorrect PIN. Try again.';

      return PinVerifyResult(
        isValid: false,
        isLockedOut: false,
        failedAttempts: failedAttempts,
        message: warningMsg,
      );
    }
  }

  /// Backward-compatible verifyPin call
  Future<bool> verifyPin(String enteredPin) async {
    final result = await verifyPinDetailed(enteredPin);
    return result.isValid;
  }

  /// Enable lock using salted SHA-256 key stretching
  Future<void> enableLock(String pin, {bool useBiometrics = true}) async {
    final prefs = await SharedPreferences.getInstance();
    final salt = _generateSalt();
    final hash = _computeHash(pin, salt);

    await prefs.setString(_keyPinSalt, salt);
    await prefs.setString(_keyPinHash, hash);
    await prefs.remove(_keyLegacyPin); // Purge any plaintext PIN
    await prefs.remove(_keyFailedAttempts);
    await prefs.remove(_keyLockoutUntil);

    await prefs.setBool(_keyLockEnabled, true);
    await prefs.setBool(_keyBiometrics, useBiometrics);
  }

  Future<void> setBiometricsEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyBiometrics, enabled);
  }

  Future<void> disableLock() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyPinHash);
    await prefs.remove(_keyPinSalt);
    await prefs.remove(_keyLegacyPin);
    await prefs.remove(_keyFailedAttempts);
    await prefs.remove(_keyLockoutUntil);
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
