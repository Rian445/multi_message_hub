import 'dart:async';
import 'package:flutter/material.dart';
import '../services/security_service.dart';
import '../widgets/status_feedback_dialog.dart';

class LockScreen extends StatefulWidget {
  final VoidCallback onUnlocked;
  final SecurityService securityService;

  const LockScreen({
    super.key,
    required this.onUnlocked,
    required this.securityService,
  });

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  String _enteredPin = '';
  String? _errorMessage;
  bool _canUseBiometrics = false;
  bool _hasPromptedBiometrics = false;
  bool _isAuthenticatingNow = false;
  int _lockoutRemainingSeconds = 0;
  Timer? _lockoutTimer;

  @override
  void initState() {
    super.initState();
    _checkLockoutStatus();
    _checkAndPromptBiometrics();
  }

  @override
  void dispose() {
    _lockoutTimer?.cancel();
    super.dispose();
  }

  Future<void> _checkLockoutStatus() async {
    final remaining = await widget.securityService.getRemainingLockoutSeconds();
    if (remaining > 0 && mounted) {
      _startLockoutCountdown(remaining);
    }
  }

  void _startLockoutCountdown(int seconds) {
    _lockoutTimer?.cancel();
    setState(() {
      _lockoutRemainingSeconds = seconds;
      _errorMessage = 'Too many attempts. Locked for ${_lockoutRemainingSeconds}s';
      _enteredPin = '';
    });

    _lockoutTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_lockoutRemainingSeconds <= 1) {
        timer.cancel();
        setState(() {
          _lockoutRemainingSeconds = 0;
          _errorMessage = null;
        });
      } else {
        setState(() {
          _lockoutRemainingSeconds--;
          _errorMessage = 'Too many attempts. Locked for ${_lockoutRemainingSeconds}s';
        });
      }
    });
  }

  Future<void> _checkAndPromptBiometrics() async {
    final isBiometricsEnabled = await widget.securityService.isBiometricsEnabled();
    final canCheck = await widget.securityService.canCheckBiometrics();

    if (mounted) {
      setState(() {
        _canUseBiometrics = isBiometricsEnabled && canCheck;
      });
    }

    if (_canUseBiometrics && !_hasPromptedBiometrics) {
      _hasPromptedBiometrics = true;
      // Slight delay so the view and activity are fully settled before invoking native prompt
      Future.delayed(const Duration(milliseconds: 350), () {
        if (mounted) {
          _triggerBiometrics();
        }
      });
    }
  }

  Future<void> _triggerBiometrics() async {
    if (_isAuthenticatingNow) return;
    _isAuthenticatingNow = true;

    try {
      final success = await widget.securityService.authenticateBiometrics();
      if (success && mounted) {
        widget.onUnlocked();
      }
    } finally {
      if (mounted) {
        setState(() {
          _isAuthenticatingNow = false;
        });
      }
    }
  }

  void _onKeyPress(String digit) async {
    if (_lockoutRemainingSeconds > 0) return; // Prevent input while locked out
    if (_enteredPin.length >= 4) return;

    setState(() {
      _errorMessage = null;
      _enteredPin += digit;
    });

    if (_enteredPin.length == 4) {
      final result = await widget.securityService.verifyPinDetailed(_enteredPin);
      if (result.isValid) {
        if (mounted) {
          widget.onUnlocked();
        }
      } else if (result.isLockedOut) {
        if (mounted) {
          _startLockoutCountdown(result.remainingLockoutSeconds);
          StatusFeedbackDialog.showError(
            context,
            title: 'Account Locked',
            message: result.message ?? 'Too many incorrect attempts.',
          );
        }
      } else {
        if (mounted) {
          setState(() {
            _errorMessage = result.message ?? 'Incorrect PIN. Try again.';
            _enteredPin = '';
          });
          StatusFeedbackDialog.showError(
            context,
            title: 'Incorrect PIN',
            message: result.message ?? 'The entered PIN is incorrect.',
          );
        }
      }
    }
  }

  void _onDelete() {
    if (_lockoutRemainingSeconds > 0) return;
    if (_enteredPin.isNotEmpty) {
      setState(() {
        _errorMessage = null;
        _enteredPin = _enteredPin.substring(0, _enteredPin.length - 1);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    const bgDark = Color(0xFF131314);
    const googleBlue = Color(0xFF8AB4F8);
    final isLockedOut = _lockoutRemainingSeconds > 0;

    return PopScope(
      canPop: false, // Prevent dismissing by back button
      child: Scaffold(
        backgroundColor: bgDark,
        body: SafeArea(
          child: Column(
            children: [
              const Spacer(flex: 2),

              // Logo & App Name
              ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: Image.asset(
                  'assets/icons/app_logo.png',
                  width: 80,
                  height: 80,
                  fit: BoxFit.cover,
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Multi-Message Hub',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    isLockedOut ? Icons.lock_clock : Icons.lock_rounded,
                    size: 14,
                    color: isLockedOut ? Colors.orangeAccent : googleBlue,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    isLockedOut ? 'Temporarily Locked' : 'App is Locked',
                    style: TextStyle(
                      fontSize: 14,
                      color: isLockedOut ? Colors.orangeAccent : Colors.white70,
                      fontWeight: isLockedOut ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 32),

              // PIN dots
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(4, (index) {
                  final isFilled = index < _enteredPin.length;
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    margin: const EdgeInsets.symmetric(horizontal: 10),
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isLockedOut
                          ? Colors.white10
                          : (isFilled ? googleBlue : Colors.transparent),
                      border: Border.all(
                        color: isLockedOut
                            ? Colors.white24
                            : (isFilled ? googleBlue : Colors.white38),
                        width: 2,
                      ),
                    ),
                  );
                }),
              ),

              const SizedBox(height: 16),

              // Error / Lockout message
              SizedBox(
                height: 28,
                child: _errorMessage != null
                    ? Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Text(
                          _errorMessage!,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: isLockedOut ? Colors.orangeAccent : Colors.redAccent,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      )
                    : null,
              ),

              const Spacer(flex: 3),

              // Number Keypad
              Opacity(
                opacity: isLockedOut ? 0.4 : 1.0,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 40),
                  child: Column(
                    children: [
                      _buildRow(['1', '2', '3']),
                      const SizedBox(height: 16),
                      _buildRow(['4', '5', '6']),
                      const SizedBox(height: 16),
                      _buildRow(['7', '8', '9']),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          // Biometric button
                          SizedBox(
                            width: 72,
                            height: 72,
                            child: _canUseBiometrics
                                ? IconButton(
                                    icon: const Icon(
                                      Icons.fingerprint_rounded,
                                      size: 38,
                                      color: googleBlue,
                                    ),
                                    onPressed: _triggerBiometrics,
                                  )
                                : const SizedBox.shrink(),
                          ),
                          // 0
                          _buildKey('0'),
                          // Delete
                          SizedBox(
                            width: 72,
                            height: 72,
                            child: IconButton(
                              icon: const Icon(
                                Icons.backspace_outlined,
                                size: 26,
                                color: Colors.white70,
                              ),
                              onPressed: isLockedOut ? null : _onDelete,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),

              const Spacer(flex: 2),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRow(List<String> digits) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: digits.map((d) => _buildKey(d)).toList(),
    );
  }

  Widget _buildKey(String digit) {
    final isLockedOut = _lockoutRemainingSeconds > 0;
    return Material(
      color: const Color(0xFF1E1F22),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: isLockedOut ? null : () => _onKeyPress(digit),
        splashColor: const Color(0xFF8AB4F8).withValues(alpha: 0.2),
        child: Container(
          width: 72,
          height: 72,
          alignment: Alignment.center,
          child: Text(
            digit,
            style: const TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}
