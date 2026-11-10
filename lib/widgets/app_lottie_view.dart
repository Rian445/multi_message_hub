import 'package:flutter/material.dart';
import 'package:lottie/lottie.dart';

/// Loading overlay with [loading.lottie] animation displayed during initial
/// profile launch, web fetch, and refresh operations.
class ProfileLoadingOverlay extends StatelessWidget {
  final String profileName;
  final String? message;

  const ProfileLoadingOverlay({
    super.key,
    required this.profileName,
    this.message,
  });

  @override
  Widget build(BuildContext context) {
    const darkBackground = Color(0xFF131314);
    const googleBlue = Color(0xFF8AB4F8);

    return Container(
      color: darkBackground,
      width: double.infinity,
      height: double.infinity,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 190,
                height: 190,
                child: Lottie.asset(
                  'assets/animations/loading.lottie',
                  fit: BoxFit.contain,
                  repeat: true,
                  animate: true,
                  errorBuilder: (context, error, stackTrace) {
                    return const Center(
                      child: CircularProgressIndicator(
                        valueColor: AlwaysStoppedAnimation<Color>(googleBlue),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 20),
              Text(
                message ?? 'Loading Google Messages...',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.2,
                ),
              ),
              const SizedBox(height: 10),
              if (profileName.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E1F22),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFF2B2D31)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.phone_android, size: 14, color: googleBlue),
                      const SizedBox(width: 6),
                      Text(
                        profileName,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Connection failed / device offline overlay with [connection_failed.lottie]
/// animation and a prominent retry button.
class ProfileConnectionFailedOverlay extends StatelessWidget {
  final String profileName;
  final String? errorMessage;
  final VoidCallback onRetry;

  const ProfileConnectionFailedOverlay({
    super.key,
    required this.profileName,
    this.errorMessage,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    const darkBackground = Color(0xFF131314);

    return Container(
      color: darkBackground,
      width: double.infinity,
      height: double.infinity,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 210,
                height: 210,
                child: Lottie.asset(
                  'assets/animations/connection_failed.lottie',
                  fit: BoxFit.contain,
                  repeat: true,
                  animate: true,
                  errorBuilder: (context, error, stackTrace) {
                    return const Icon(
                      Icons.wifi_off_rounded,
                      size: 80,
                      color: Colors.redAccent,
                    );
                  },
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Connection Failed',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.3,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                errorMessage ??
                    'Unable to connect to Google Messages.\nPlease check your phone connection or internet access.',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
              if (profileName.isNotEmpty) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E1F22),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFF2B2D31)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.phone_android, size: 14, color: Colors.white60),
                      const SizedBox(width: 6),
                      Text(
                        profileName,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded, size: 20, color: Colors.white),
                label: const Text(
                  'Retry Connection',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                    letterSpacing: 0.3,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1A73E8),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(24),
                  ),
                  elevation: 3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
