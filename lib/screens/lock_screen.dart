import 'package:flutter/material.dart';
import '../services/security_service.dart';

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

  @override
  void initState() {
    super.initState();
    _checkAndPromptBiometrics();
  }

  Future<void> _checkAndPromptBiometrics() async {
    final isBiometricsEnabled = await widget.securityService.isBiometricsEnabled();
    final canCheck = await widget.securityService.canCheckBiometrics();

    if (mounted) {
      setState(() {
        _canUseBiometrics = isBiometricsEnabled && canCheck;
      });
    }

    if (_canUseBiometrics) {
      // Trigger biometrics automatically after screen finishes rendering
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _triggerBiometrics();
      });
    }
  }

  Future<void> _triggerBiometrics() async {
    final success = await widget.securityService.authenticateBiometrics();
    if (success && mounted) {
      widget.onUnlocked();
    }
  }

  void _onKeyPress(String digit) async {
    if (_enteredPin.length >= 4) return;

    setState(() {
      _errorMessage = null;
      _enteredPin += digit;
    });

    if (_enteredPin.length == 4) {
      final isValid = await widget.securityService.verifyPin(_enteredPin);
      if (isValid) {
        if (mounted) {
          widget.onUnlocked();
        }
      } else {
        if (mounted) {
          setState(() {
            _errorMessage = 'Incorrect PIN. Try again.';
            _enteredPin = '';
          });
        }
      }
    }
  }

  void _onDelete() {
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
              const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.lock_rounded, size: 14, color: googleBlue),
                  SizedBox(width: 6),
                  Text(
                    'App is Locked',
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.white70,
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
                      color: isFilled ? googleBlue : Colors.transparent,
                      border: Border.all(
                        color: isFilled ? googleBlue : Colors.white38,
                        width: 2,
                      ),
                    ),
                  );
                }),
              ),

              const SizedBox(height: 16),

              // Error message
              SizedBox(
                height: 24,
                child: _errorMessage != null
                    ? Text(
                        _errorMessage!,
                        style: const TextStyle(
                          color: Colors.redAccent,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      )
                    : null,
              ),

              const Spacer(flex: 3),

              // Number Keypad
              Padding(
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
                            onPressed: _onDelete,
                          ),
                        ),
                      ],
                    ),
                  ],
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
    return Material(
      color: const Color(0xFF1E1F22),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _onKeyPress(digit),
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
