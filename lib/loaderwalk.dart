import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Mate Walks loading screen.
///
/// Shows the night-hills background, the "Mate Walks" logo in the
/// center, and a green spinning ring/arc loader around it.
///
/// Add these two images to your project and register them in pubspec.yaml:
///   assets/images/night_background.png   (the dark hills + fireflies image)
///   assets/images/mate_walks_logo.png    (the hexagon footprints logo)
///
/// pubspec.yaml:
/// flutter:
///   assets:
///     - assets/images/night_background.png
///     - assets/images/mate_walks_logo.png
class LoaderScreen extends StatefulWidget {
  const LoaderScreen({super.key});

  @override
  State<LoaderScreen> createState() => _LoaderScreenState();
}

class _LoaderScreenState extends State<LoaderScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  static const _green = Color(0xFF8DD41A);

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Background image
          Image.asset(
            'assets/night_background.png',
            fit: BoxFit.cover,
          ),
          // Logo + spinning loader, centered
          Center(
            child: SizedBox(
              width: 220,
              height: 220,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Spinning green arc loader
                  RotationTransition(
                    turns: _controller,
                    child: CustomPaint(
                      size: const Size(220, 220),
                      painter: _SpinnerPainter(color: _green),
                    ),
                  ),
                  // Static logo on top
                  Padding(
                    padding: const EdgeInsets.all(36),
                    child: Image.asset(
                      'assets/mate_walks_logo.png',
                      fit: BoxFit.contain,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Draws a rotating green arc (sweep gradient ring) used as the spinner.
class _SpinnerPainter extends CustomPainter {
  final Color color;

  _SpinnerPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - 6;

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        colors: [
          color.withOpacity(0.0),
          color.withOpacity(0.9),
        ],
        startAngle: 0,
        endAngle: math.pi * 1.6,
        center: Alignment.center,
      ).createShader(Rect.fromCircle(center: center, radius: radius));

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      0,
      math.pi * 1.6,
      false,
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _SpinnerPainter oldDelegate) =>
      oldDelegate.color != color;
}