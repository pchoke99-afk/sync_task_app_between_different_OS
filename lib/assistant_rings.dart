import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Shared vector artwork with optional ambient motion for the corner launcher.
class AssistantRings extends StatefulWidget {
  const AssistantRings({
    super.key,
    this.size = 64,
    this.active = false,
    this.animateOnHover = false,
    this.animateWhenIdle = false,
  });

  final double size;
  final bool active;
  final bool animateOnHover;
  final bool animateWhenIdle;

  @override
  State<AssistantRings> createState() => _AssistantRingsState();
}

class _AssistantRingsState extends State<AssistantRings>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 4),
  );

  bool _hovered = false;

  void _updateMotion() {
    if ((widget.active ||
            widget.animateWhenIdle ||
            (widget.animateOnHover && _hovered)) &&
        !MediaQuery.disableAnimationsOf(context)) {
      final duration = widget.animateOnHover && _hovered
          ? const Duration(milliseconds: 1800)
          : const Duration(seconds: 4);
      if (!_controller.isAnimating || _controller.duration != duration) {
        _controller.duration = duration;
        _controller.repeat();
      }
    } else {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateMotion();
  }

  @override
  void didUpdateWidget(AssistantRings oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateMotion();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: MouseRegion(
      onEnter: (_) {
        _hovered = true;
        _updateMotion();
      },
      onExit: (_) {
        _hovered = false;
        _updateMotion();
      },
      child: RepaintBoundary(
        child: SizedBox.square(
          dimension: widget.size,
          child: CustomPaint(painter: _RingsPainter(_controller)),
        ),
      ),
    ),
  );
}

class _RingsPainter extends CustomPainter {
  _RingsPainter(this.animation) : super(repaint: animation);
  final Animation<double> animation;

  static const _colors = [
    Color(0xFF54DFFF),
    Color(0xFF4991FF),
    Color(0xFF9AB9FF),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final unit = size.shortestSide;
    canvas.translate(size.width / 2, size.height / 2);
    canvas.rotate(-.35 + math.sin(animation.value * math.pi * 2) * .28);
    for (var i = 0; i < 3; i++) {
      final radius = unit * (.37 - i * .09);
      final oval = Rect.fromCenter(
        center: Offset.zero,
        width: radius * 2,
        height: radius * 1.4,
      );
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = unit * .065
        ..color = _colors[i].withValues(alpha: .45)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, unit * .055);
      canvas.drawOval(oval, paint);
      paint
        ..maskFilter = null
        ..strokeWidth = unit * .022
        ..color = _colors[i];
      canvas.drawOval(oval, paint);
    }
  }

  @override
  bool shouldRepaint(_RingsPainter oldDelegate) =>
      oldDelegate.animation != animation;
}
