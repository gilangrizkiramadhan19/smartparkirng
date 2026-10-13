import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../models/parking_models.dart';
import '../services/ar_projector.dart';

/// CustomPainter untuk merender elemen AR di atas preview kamera:
/// 1. Jalur panah (chevron) neon 3D menempel di lantai dengan efek perspektif & pulse gerak.
/// 2. Pin 3D melayang di atas slot parkir tujuan.
/// 3. Indikator belok di tepi layar jika rute berada di luar pandangan kamera.
class AROverlayPainter extends CustomPainter {
  final List<Node> currentRoute;
  final Node? userPosition;
  final double mapHeadingDeg;
  final double pitchDeg;
  final ParkingSlot? targetSlot;
  final double animationValue; // 0.0 - 1.0 untuk animasi pulse berjalan
  final ARProjector projector;

  AROverlayPainter({
    required this.currentRoute,
    required this.userPosition,
    required this.mapHeadingDeg,
    required this.pitchDeg,
    this.targetSlot,
    required this.animationValue,
    this.projector = const ARProjector(),
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (userPosition == null || currentRoute.isEmpty) {
      return;
    }

    final userOffset = Offset(userPosition!.x, userPosition!.y);

    // Kumpulkan titik-titik rute ke depan
    final waypoints = <Offset>[
      userOffset,
      ...currentRoute.map((n) => Offset(n.x, n.y)),
    ];

    // 1. Interpolasi titik-titik rute agar rapat (~1.2 meter antar panah)
    final densePoints = ARProjector.interpolateRoutePoints(
      waypoints,
      spacing: 1.2,
      maxDistance: 16.0,
    );

    // Proyeksikan setiap titik ke koordinat piksel layar
    final projectedList = <ProjectedPoint?>[];
    for (final pt in densePoints) {
      projectedList.add(
        projector.projectPoint(
          point: pt,
          userPosition: userOffset,
          mapHeadingDeg: mapHeadingDeg,
          pitchDeg: pitchDeg,
          screenSize: size,
        ),
      );
    }

    // 2. Gambar Jalur Lintasan di Lantai
    _drawFloorPathRibbon(canvas, projectedList);

    // 3. Gambar Rangkaian Chevron (Panah) 3D Menempel di Lantai
    _drawChevrons(canvas, projectedList);

    // 4. Gambar Pin Melayang di Atas Slot Tujuan (jika ada dan terjangkau)
    if (targetSlot != null) {
      _drawDestinationPin(canvas, size, userOffset);
    }

    // 5. Cek apakah rute berikutnya berada di luar layar, gambar indikator tepi
    _drawOffScreenIndicatorIfNeeded(canvas, size, userOffset, waypoints);
  }

  /// Menggambar pita lintasan lantai bercahaya tipis di bawah panah
  void _drawFloorPathRibbon(Canvas canvas, List<ProjectedPoint?> projectedList) {
    final validPoints = projectedList.whereType<ProjectedPoint>().toList();
    if (validPoints.length < 2) return;

    final path = Path();
    bool started = false;

    for (final p in validPoints) {
      if (!started) {
        path.moveTo(p.screenPosition.dx, p.screenPosition.dy);
        started = true;
      } else {
        path.lineTo(p.screenPosition.dx, p.screenPosition.dy);
      }
    }

    // Garis glow lembut
    final glowPaint = Paint()
      ..color = const Color(0x3300FF88)
      ..strokeWidth = 14.0
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8.0);

    canvas.drawPath(path, glowPaint);

    final linePaint = Paint()
      ..color = const Color(0x6600E5FF)
      ..strokeWidth = 4.0
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    canvas.drawPath(path, linePaint);
  }

  /// Menggambar rangkaian chevron (panah 3D) di sepanjang lintasan
  void _drawChevrons(Canvas canvas, List<ProjectedPoint?> projectedList) {
    if (projectedList.length < 2) return;

    for (int i = 0; i < projectedList.length - 1; i++) {
      final pCurrent = projectedList[i];
      final pNext = projectedList[i + 1];

      if (pCurrent == null || pNext == null) continue;
      if (!pCurrent.isVisibleOnScreen && !pNext.isVisibleOnScreen) continue;

      // Hitung sudut rotasi panah pada layar (mengarah ke titik berikutnya)
      final dx = pNext.screenPosition.dx - pCurrent.screenPosition.dx;
      final dy = pNext.screenPosition.dy - pCurrent.screenPosition.dy;
      final angle = math.atan2(dy, dx);

      // Skala perspektif: panah dekat lebih besar, jauh lebih kecil
      // Lebar dasar 0.8 meter dikalikan faktor skala proyeksi
      final baseWidth = (pCurrent.scale * 0.45).clamp(10.0, 90.0);
      final baseLength = baseWidth * 0.75;

      // Efek animasi pulse gelombang berjalan ke depan
      final pulsePhase = ((i / projectedList.length) - animationValue) % 1.0;
      final pulseFactor = math.sin((pulsePhase < 0 ? pulsePhase + 1.0 : pulsePhase) * math.pi);
      final alpha = (0.55 + 0.45 * pulseFactor).clamp(0.2, 1.0);

      canvas.save();
      canvas.translate(pCurrent.screenPosition.dx, pCurrent.screenPosition.dy);
      canvas.rotate(angle);

      // Gambar bayangan / glow panah
      final shadowPath = _createChevronPath(baseWidth * 1.15, baseLength * 1.15);
      final shadowPaint = Paint()
        ..color = Color.fromRGBO(0, 255, 136, alpha * 0.4)
        ..style = PaintingStyle.fill
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6.0);
      canvas.drawPath(shadowPath, shadowPaint);

      // Gambar panah hijau neon utama
      final chevronPath = _createChevronPath(baseWidth, baseLength);
      final chevronPaint = Paint()
        ..shader = LinearGradient(
          colors: [
            Color.fromRGBO(0, 229, 255, alpha),
            Color.fromRGBO(0, 255, 136, alpha),
          ],
        ).createShader(Rect.fromLTWH(-baseLength, -baseWidth / 2, baseLength * 1.5, baseWidth))
        ..style = PaintingStyle.fill;
      canvas.drawPath(chevronPath, chevronPaint);

      // Border tajam warna putih-hijau
      final borderPaint = Paint()
        ..color = Color.fromRGBO(255, 255, 255, alpha * 0.9)
        ..style = PaintingStyle.stroke
        ..strokeWidth = (baseWidth * 0.08).clamp(1.5, 3.5);
      canvas.drawPath(chevronPath, borderPaint);

      canvas.restore();
    }
  }

  /// Membuat bentuk geometri chevron/panah
  Path _createChevronPath(double width, double length) {
    final path = Path();
    final halfW = width / 2.0;
    final indent = length * 0.45;

    // Panah menghadap sumbu +X (ke kanan) saat rotasi 0
    path.moveTo(length, 0); // Ujung runcing depan
    path.lineTo(0, -halfW); // Sayap kiri
    path.lineTo(indent, 0); // Lekukan tengah belakang
    path.lineTo(0, halfW); // Sayap kanan
    path.close();

    return path;
  }

  /// Menggambar pin 3D melayang di atas slot tujuan
  void _drawDestinationPin(Canvas canvas, Size size, Offset userOffset) {
    final slotOffset = Offset(targetSlot!.x, targetSlot!.y);
    final dist = (slotOffset - userOffset).distance;
    if (dist > 18.0) return; // Hanya gambar jika dalam radius 18 m

    final projected = projector.projectPoint(
      point: slotOffset,
      userPosition: userOffset,
      mapHeadingDeg: mapHeadingDeg,
      pitchDeg: pitchDeg,
      screenSize: size,
    );

    if (projected == null || !projected.isVisibleOnScreen) return;

    final pos = projected.screenPosition;
    // Pin melayang ~50 - 120 piksel di atas titik lantai tergantung kedalaman
    final elevation = (projected.scale * 0.8).clamp(35.0, 100.0);
    // Sedikit efek melayang turun-naik (hovering bounce)
    final bounce = math.sin(animationValue * 2 * math.pi) * 6.0;
    final pinTop = Offset(pos.dx, pos.dy - elevation + bounce);

    // 1. Lingkaran target di lantai
    final groundRadius = (projected.scale * 0.35).clamp(8.0, 32.0);
    final ringPaint = Paint()
      ..color = const Color(0x9900E5FF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;
    canvas.drawCircle(pos, groundRadius, ringPaint);

    final glowRingPaint = Paint()
      ..color = const Color(0x4400FF88)
      ..style = PaintingStyle.fill
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8.0);
    canvas.drawCircle(pos, groundRadius, glowRingPaint);

    // 2. Garis laser penunjuk vertikal dari lantai ke pin melayang
    final beamPaint = Paint()
      ..color = const Color(0x8800E5FF)
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke;
    canvas.drawLine(pos, pinTop, beamPaint);

    // 3. Pin Marker melayang dengan label slot
    final pinRadius = (projected.scale * 0.28).clamp(16.0, 32.0);

    // Shadow pin
    final pinShadowPaint = Paint()
      ..color = const Color(0x66000000)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6.0);
    canvas.drawCircle(pinTop.translate(0, 3), pinRadius, pinShadowPaint);

    // Lingkaran badan pin (Kuning keemasan / Cyan cerah)
    final pinPaint = Paint()
      ..shader = const RadialGradient(
        colors: [Color(0xFFFFD600), Color(0xFFFF9100)],
      ).createShader(Rect.fromCircle(center: pinTop, radius: pinRadius));
    canvas.drawCircle(pinTop, pinRadius, pinPaint);

    final pinBorder = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;
    canvas.drawCircle(pinTop, pinRadius, pinBorder);

    // Label slot di dalam pin
    final textPainter = TextPainter(
      text: TextSpan(
        text: targetSlot!.id,
        style: TextStyle(
          color: Colors.black,
          fontSize: pinRadius * 0.85,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();
    textPainter.paint(
      canvas,
      Offset(
        pinTop.dx - textPainter.width / 2,
        pinTop.dy - textPainter.height / 2,
      ),
    );
  }

  /// Menggambar indikator panah tepi layar jika rute berada di luar pandangan kamera
  void _drawOffScreenIndicatorIfNeeded(
    Canvas canvas,
    Size size,
    Offset userOffset,
    List<Offset> waypoints,
  ) {
    if (waypoints.length < 2) return;

    // Ambil waypoint rute berikutnya (~3 meter ke depan)
    final nextTarget = waypoints.length > 2 ? waypoints[2] : waypoints[1];

    final projected = projector.projectPoint(
      point: nextTarget,
      userPosition: userOffset,
      mapHeadingDeg: mapHeadingDeg,
      pitchDeg: pitchDeg,
      screenSize: size,
    );

    // Jika waypoint di depan terlihat jelas di dalam layar, tidak perlu peringatan tepi
    if (projected != null && projected.isVisibleOnScreen) {
      return;
    }

    // Dapatkan panduan arah belok
    final guidance = ARProjector.getOffScreenGuidance(
      userPos: userOffset,
      userHeadingDeg: mapHeadingDeg,
      targetPoint: nextTarget,
    );

    if (guidance.direction == TurnDirection.straight) {
      return;
    }

    // Tentukan posisi indikator tepi layar
    final isLeft = guidance.direction == TurnDirection.left ||
        guidance.direction == TurnDirection.slightLeft;
    final isRight = guidance.direction == TurnDirection.right ||
        guidance.direction == TurnDirection.slightRight;
    final isUTurn = guidance.direction == TurnDirection.uTurn;

    final indicatorY = size.height * 0.45;
    final indicatorX = isLeft
        ? 36.0
        : isRight
            ? size.width - 36.0
            : size.width / 2.0;

    final targetOffset = isUTurn
        ? Offset(indicatorX, size.height * 0.75)
        : Offset(indicatorX, indicatorY);

    _drawEdgeArrow(canvas, targetOffset, guidance, isLeft, isRight, isUTurn);
  }

  /// Menggambar widget panah besar berdenyut di tepi layar
  void _drawEdgeArrow(
    Canvas canvas,
    Offset position,
    OffScreenGuidance guidance,
    bool isLeft,
    bool isRight,
    bool isUTurn,
  ) {
    final pulseScale = 1.0 + 0.15 * math.sin(animationValue * 2 * math.pi);

    canvas.save();
    canvas.translate(position.dx, position.dy);
    canvas.scale(pulseScale);

    // Background pill gelap modern
    final pillRect = Rect.fromCenter(
      center: Offset.zero,
      width: isUTurn ? 140 : 120,
      height: 48,
    );
    final pillPaint = Paint()
      ..color = const Color(0xE61E222D)
      ..style = PaintingStyle.fill;
    final borderPaint = Paint()
      ..color = const Color(0xFF00E5FF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    canvas.drawRRect(
      RRect.fromRectAndRadius(pillRect, const Radius.circular(24)),
      pillPaint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(pillRect, const Radius.circular(24)),
      borderPaint,
    );

    // Teks instruksi & panah
    final arrowText = isLeft
        ? '◀ ${guidance.label}'
        : isRight
            ? '${guidance.label} ▶'
            : '🔄 ${guidance.label}';

    final textPainter = TextPainter(
      text: TextSpan(
        text: arrowText,
        style: const TextStyle(
          color: Color(0xFF00FF88),
          fontSize: 13,
          fontWeight: FontWeight.bold,
          shadows: [
            Shadow(color: Color(0xFF00FF88), blurRadius: 8),
          ],
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();
    textPainter.paint(
      canvas,
      Offset(-textPainter.width / 2, -textPainter.height / 2),
    );

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant AROverlayPainter oldDelegate) {
    return true; // Direpaint sesuai tick animasi / sensor
  }
}
