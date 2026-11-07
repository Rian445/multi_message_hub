import 'package:flutter/material.dart';

enum StatusType { success, error, info }

class StatusFeedbackDialog extends StatefulWidget {
  final StatusType type;
  final String title;
  final String? message;
  final Duration autoDismissDuration;

  const StatusFeedbackDialog({
    super.key,
    required this.type,
    required this.title,
    this.message,
    this.autoDismissDuration = const Duration(milliseconds: 1800),
  });

  static Future<void> show(
    BuildContext context, {
    required StatusType type,
    required String title,
    String? message,
    Duration duration = const Duration(milliseconds: 1800),
  }) {
    return showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'StatusFeedback',
      barrierColor: Colors.black.withValues(alpha: 0.45),
      transitionDuration: const Duration(milliseconds: 250),
      transitionBuilder: (context, anim1, anim2, child) {
        final curved = CurvedAnimation(parent: anim1, curve: Curves.easeOutBack);
        return ScaleTransition(
          scale: curved,
          child: FadeTransition(opacity: anim1, child: child),
        );
      },
      pageBuilder: (context, anim1, anim2) {
        return StatusFeedbackDialog(
          type: type,
          title: title,
          message: message,
          autoDismissDuration: duration,
        );
      },
    );
  }

  static Future<void> showSuccess(
    BuildContext context, {
    required String title,
    String? message,
    Duration duration = const Duration(milliseconds: 1800),
  }) =>
      show(
        context,
        type: StatusType.success,
        title: title,
        message: message,
        duration: duration,
      );

  static Future<void> showError(
    BuildContext context, {
    required String title,
    String? message,
    Duration duration = const Duration(milliseconds: 2000),
  }) =>
      show(
        context,
        type: StatusType.error,
        title: title,
        message: message,
        duration: duration,
      );

  static Future<void> showInfo(
    BuildContext context, {
    required String title,
    String? message,
    Duration duration = const Duration(milliseconds: 1800),
  }) =>
      show(
        context,
        type: StatusType.info,
        title: title,
        message: message,
        duration: duration,
      );

  @override
  State<StatusFeedbackDialog> createState() => _StatusFeedbackDialogState();
}

class _StatusFeedbackDialogState extends State<StatusFeedbackDialog>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _iconProgress;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );

    _iconProgress = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeInOutCubic,
    );

    _controller.forward();

    // Auto dismiss after specified duration
    Future.delayed(widget.autoDismissDuration, () {
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Color primaryColor;
    Color glowColor;

    switch (widget.type) {
      case StatusType.success:
        primaryColor = const Color(0xFF34A853); // Google Green
        glowColor = const Color(0xFF34A853).withValues(alpha: 0.25);
        break;
      case StatusType.error:
        primaryColor = const Color(0xFFEA4335); // Google Red
        glowColor = const Color(0xFFEA4335).withValues(alpha: 0.25);
        break;
      case StatusType.info:
        primaryColor = const Color(0xFF8AB4F8); // Google Blue
        glowColor = const Color(0xFF8AB4F8).withValues(alpha: 0.25);
        break;
    }

    return Center(
      child: GestureDetector(
        onTap: () => Navigator.of(context, rootNavigator: true).pop(),
        child: Material(
          color: Colors.transparent,
          child: Container(
            width: 250,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 26),
            decoration: BoxDecoration(
              color: const Color(0xFF1E1F22),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: primaryColor.withValues(alpha: 0.35),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.5),
                  blurRadius: 28,
                  offset: const Offset(0, 10),
                ),
                BoxShadow(
                  color: glowColor,
                  blurRadius: 20,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Animated Circle Badge with Icon
                Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: primaryColor.withValues(alpha: 0.12),
                    border: Border.all(
                      color: primaryColor.withValues(alpha: 0.6),
                      width: 2.5,
                    ),
                  ),
                  child: AnimatedBuilder(
                    animation: _iconProgress,
                    builder: (context, child) {
                      return CustomPaint(
                        painter: _StatusIconPainter(
                          type: widget.type,
                          progress: _iconProgress.value,
                          color: primaryColor,
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 18),

                // Title
                Text(
                  widget.title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.3,
                  ),
                ),

                // Optional Message
                if (widget.message != null && widget.message!.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    widget.message!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                      height: 1.3,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusIconPainter extends CustomPainter {
  final StatusType type;
  final double progress;
  final Color color;

  _StatusIconPainter({
    required this.type,
    required this.progress,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final strokePaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final w = size.width;
    final h = size.height;

    if (type == StatusType.success) {
      // Animated Checkmark (Tick)
      final checkPath = Path();
      checkPath.moveTo(w * 0.28, h * 0.52);
      checkPath.lineTo(w * 0.44, h * 0.68);
      checkPath.lineTo(w * 0.72, h * 0.36);

      _drawAnimatedPath(canvas, checkPath, strokePaint, progress);
    } else if (type == StatusType.error) {
      // Animated Cross (X)
      // Line 1: top-left to bottom-right
      final cross1 = Path();
      cross1.moveTo(w * 0.32, h * 0.32);
      cross1.lineTo(w * 0.68, h * 0.68);

      // Line 2: top-right to bottom-left
      final cross2 = Path();
      cross2.moveTo(w * 0.68, h * 0.32);
      cross2.lineTo(w * 0.32, h * 0.68);

      if (progress <= 0.5) {
        _drawAnimatedPath(canvas, cross1, strokePaint, progress * 2.0);
      } else {
        _drawAnimatedPath(canvas, cross1, strokePaint, 1.0);
        _drawAnimatedPath(canvas, cross2, strokePaint, (progress - 0.5) * 2.0);
      }
    } else {
      // Animated Info icon (i)
      final infoDot = Path();
      infoDot.addOval(Rect.fromCircle(center: Offset(w * 0.5, h * 0.33), radius: 2.5));
      final infoLine = Path();
      infoLine.moveTo(w * 0.5, h * 0.46);
      infoLine.lineTo(w * 0.5, h * 0.70);

      _drawAnimatedPath(canvas, infoLine, strokePaint, progress);
      if (progress > 0.4) {
        canvas.drawCircle(Offset(w * 0.5, h * 0.33), 2.5, strokePaint..style = PaintingStyle.fill);
      }
    }
  }

  void _drawAnimatedPath(Canvas canvas, Path path, Paint paint, double progress) {
    if (progress <= 0.0) return;
    final metrics = path.computeMetrics().toList();
    for (final metric in metrics) {
      final length = metric.length * progress.clamp(0.0, 1.0);
      final subPath = metric.extractPath(0.0, length);
      canvas.drawPath(subPath, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _StatusIconPainter oldDelegate) {
    return oldDelegate.progress != progress || oldDelegate.color != color;
  }
}
