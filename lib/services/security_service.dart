import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
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
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage(
    aOptions: AndroidOptions(
      resetOnError: true,
    ),
  );

  bool _isAuthenticating = false;
  bool get isAuthenticating => _isAuthenticating;

  /// Hardware-backed Keystore reader with transparent migration from SharedPreferences
  Future<String?> _readSecure(String key) async {
    try {
      final val = await _secureStorage.read(key: key);
      if (val != null) return val;

      // Transparent legacy migration from SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      if (prefs.containsKey(key)) {
        final legacyVal = prefs.get(key)?.toString();
        if (legacyVal != null) {
          await _secureStorage.write(key: key, value: legacyVal);
          await prefs.remove(key);
          return legacyVal;
        }
      }
    } catch (_) {
      final prefs = await SharedPreferences.getInstance();
      return prefs.get(key)?.toString();
    }
    return null;
  }

  /// Hardware-backed Keystore writer (removes unencrypted SharedPreferences artifact)
  Future<void> _writeSecure(String key, String value) async {
    try {
      await _secureStorage.write(key: key, value: value);
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(key);
    } catch (_) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, value);
    }
  }

  /// Deletes a key from both Keystore and SharedPreferences
  Future<void> _deleteSecure(String key) async {
    try {
      await _secureStorage.delete(key: key);
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(key);
    } catch (_) {}
  }

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
    final val = await _readSecure(_keyTimeout);
    if (val != null) {
      return int.tryParse(val) ?? 0;
    }
    return 0; // Default 0 = Immediate
  }

  Future<void> setLockTimeoutSeconds(int seconds) async {
    await _writeSecure(_keyTimeout, seconds.toString());
  }

  Future<bool> isLockEnabled() async {
    final val = await _readSecure(_keyLockEnabled);
    if (val != null) {
      return val == 'true';
    }
    return false;
  }

  Future<bool> isBiometricsEnabled() async {
    final val = await _readSecure(_keyBiometrics);
    if (val != null) {
      return val == 'true';
    }
    return true; // Default true if not explicitly disabled
  }

  Future<bool> hasPin() async {
    final hash = await _readSecure(_keyPinHash);
    if (hash != null && hash.isNotEmpty) return true;
    final legacy = await _readSecure(_keyLegacyPin);
    return legacy != null && legacy.isNotEmpty;
  }

  /// Check remaining lockout seconds if currently locked out
  Future<int> getRemainingLockoutSeconds() async {
    final val = await _readSecure(_keyLockoutUntil);
    final lockoutUntil = val != null ? int.tryParse(val) ?? 0 : 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (lockoutUntil > now) {
      return ((lockoutUntil - now) / 1000).ceil();
    }
    // Expired lockout
    if (lockoutUntil > 0) {
      await _deleteSecure(_keyLockoutUntil);
    }
    return 0;
  }

  /// Detailed PIN verification with progressive rate-limiting & lockout
  Future<PinVerifyResult> verifyPinDetailed(String enteredPin) async {
    // 1. Check if user is currently locked out
    final remainingLockout = await getRemainingLockoutSeconds();
    if (remainingLockout > 0) {
      final attemptsVal = await _readSecure(_keyFailedAttempts);
      final attempts = attemptsVal != null ? int.tryParse(attemptsVal) ?? 0 : 0;
      return PinVerifyResult(
        isValid: false,
        isLockedOut: true,
        remainingLockoutSeconds: remainingLockout,
        failedAttempts: attempts,
        message: 'Too many failed attempts. Locked for ${remainingLockout}s.',
      );
    }

    // 2. Retrieve hash and salt (with transparent legacy migration)
    String? hash = await _readSecure(_keyPinHash);
    String? salt = await _readSecure(_keyPinSalt);

    if (hash == null || salt == null) {
      final legacyPin = await _readSecure(_keyLegacyPin);
      if (legacyPin != null && legacyPin.isNotEmpty) {
        // Transparent migration: hash legacy plaintext PIN
        salt = _generateSalt();
        hash = _computeHash(legacyPin, salt);
        await _writeSecure(_keyPinSalt, salt);
        await _writeSecure(_keyPinHash, hash);
        await _deleteSecure(_keyLegacyPin);
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
      // Success: reset failed attempt counter and lockout in Keystore
      await _deleteSecure(_keyFailedAttempts);
      await _deleteSecure(_keyLockoutUntil);
      return const PinVerifyResult(isValid: true);
    } else {
      // Failure: increment attempt counter and apply exponential backoff in Keystore
      final currentAttemptsVal = await _readSecure(_keyFailedAttempts);
      final failedAttempts =
          (currentAttemptsVal != null ? int.tryParse(currentAttemptsVal) ?? 0 : 0) + 1;
      await _writeSecure(_keyFailedAttempts, failedAttempts.toString());

      int lockoutDuration = 0;
      if (failedAttempts >= 15) {
        lockoutDuration = 900; // 15 minutes lockout
      } else if (failedAttempts >= 10) {
        lockoutDuration = 300; // 5 minutes lockout
      } else if (failedAttempts >= 5) {
        lockoutDuration = 30; // 30 seconds lockout
      }

      if (lockoutDuration > 0) {
        final lockoutUntil =
            DateTime.now().millisecondsSinceEpoch + (lockoutDuration * 1000);
        await _writeSecure(_keyLockoutUntil, lockoutUntil.toString());
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

  /// Enable lock using salted SHA-256 key stretching in hardware-backed Keystore
  Future<void> enableLock(String pin, {bool useBiometrics = true}) async {
    final salt = _generateSalt();
    final hash = _computeHash(pin, salt);

    await _writeSecure(_keyPinSalt, salt);
    await _writeSecure(_keyPinHash, hash);
    await _deleteSecure(_keyLegacyPin); // Purge any plaintext PIN
    await _deleteSecure(_keyFailedAttempts);
    await _deleteSecure(_keyLockoutUntil);

    await _writeSecure(_keyLockEnabled, 'true');
    await _writeSecure(_keyBiometrics, useBiometrics.toString());
  }

  Future<void> setBiometricsEnabled(bool enabled) async {
    await _writeSecure(_keyBiometrics, enabled.toString());
  }

  Future<void> disableLock() async {
    await _deleteSecure(_keyPinHash);
    await _deleteSecure(_keyPinSalt);
    await _deleteSecure(_keyLegacyPin);
    await _deleteSecure(_keyFailedAttempts);
    await _deleteSecure(_keyLockoutUntil);
    await _writeSecure(_keyLockEnabled, 'false');
  }

  Future<bool> canCheckBiometrics() async {
    try {
      final canAuthenticateWithBiometrics = await _localAuth.canCheckBiometrics;
      final canAuthenticate =
          canAuthenticateWithBiometrics || await _localAuth.isDeviceSupported();
      return canAuthenticate;
    } catch (_) {
      return false;
    }
  }

  /// Biometric authentication strictly requiring biometric credentials
  /// (biometricOnly: true prevents device lock pattern/PIN bypass)
  Future<bool> authenticateBiometrics() async {
    if (_isAuthenticating) return false;
    _isAuthenticating = true;
    try {
      final canAuth = await canCheckBiometrics();
      if (!canAuth) return false;

      final result = await _localAuth.authenticate(
        localizedReason: 'Authenticate to unlock Multi-Message Hub',
        biometricOnly: true,
        persistAcrossBackgrounding: true,
      );
      return result;
    } on PlatformException catch (_) {
      return false;
    } catch (_) {
      return false;
    } finally {
      _isAuthenticating = false;
    }
  }
}
