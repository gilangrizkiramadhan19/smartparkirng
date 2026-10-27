import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../models/parking_models.dart';
import '../services/ar_projector.dart';

/// CustomPainter untuk merender elemen AR di atas preview kamera:
/// 1. Jalur panah (chevron) neon 3D menempel di lantai dengan efek perspektif & pulse gerak.
/// 2. Panah penuntun utama 3D besar di tengah-bawah layar (berputar sesuai sudut relatif).
/// 3. Pin 3D melayang di atas slot parkir tujuan.
/// 4. Indikator belok di tepi layar jika rute berada di luar pandangan kamera.
class AROverlayPainter extends CustomPainter {
  final List<Node> currentRoute;
  final Node? userPosition;
  final Offset? rawUserPosition;
  final double mapHeadingDeg;
  final double pitchDeg;
  final ParkingSlot? targetSlot;
  final double animationValue;
  final ARProjector projector;
  final bool isNavigating;
  final bool isCalibrated;
  final double smoothedRelativeAngleDeg;


  AROverlayPainter({
    required this.currentRoute,
    this.userPosition,
    this.rawUserPosition,
    required this.mapHeadingDeg,
    required this.pitchDeg,
    this.targetSlot,
    required this.animationValue,
    this.projector = const ARProjector(),
    this.isNavigating = false,
    this.isCalibrated = false,
    this.smoothedRelativeAngleDeg = 0.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Pisahkan logika posisi: Gunakan Pos Raw untuk proyeksi & sudut kamera AR,
    // BUKAN Pos Snap (yang terdistorsi ke koridor/graf).
    final userOffset = rawUserPosition ??
        (userPosition != null ? Offset(userPosition!.x, userPosition!.y) : null);

    if (userOffset == null || currentRoute.isEmpty) {
      return;
    }

    // Pin tujuan tetap digambar jika slot tujuan diset dan user mendekatinya
    if (targetSlot != null) {
      _drawDestinationPin(canvas, size, userOffset);
    }

    // Panah dan chevron HANYA tampil setelah tombol "Mulai Navigasi" ditekan
    // DAN kalibrasi sensor telah selesai.
    if (!isNavigating || !isCalibrated) {
      return;
    }

    // Kumpulkan titik-titik rute ke depan
    final waypoints = <Offset>[
      userOffset,
      ...currentRoute.map((n) => Offset(n.x, n.y)),
    ];

    // 1 & 2. Interpolasi rute: dapatkan titik-titik koordinat baru setiap interval 1.5 meter
    final routePoints = _interpolateRoutePoints(
      userOffset,
      currentRoute,
      interval: 1.5,
      maxDistance: 15.0,
    );

    // 3. Proyeksikan setiap titik interval ke layar menggunakan ARProjector
    final projectedList = <ProjectedPoint?>[];
    for (final pt in routePoints) {
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

    // Gambar rentetan chevron (V terbalik) terpisah dengan efek Neon 2-Layer di lantai
    _drawChevrons(canvas, size, projectedList);

    // 4. Gambar Panah Penuntun Utama 3D Besar di Tengah Bawah Layar
    _drawMainGuidingArrow(canvas, size);

    // 5. Cek apakah rute berikutnya berada di luar layar, gambar indikator tepi
    _drawOffScreenIndicatorIfNeeded(canvas, size, userOffset, waypoints);
  }

  /// Menelusuri total panjang rute dan menghasilkan titik-titik koordinat dengan interval jarak tetap (1.5 m)
  List<Offset> _interpolateRoutePoints(
    Offset startPos,
    List<Node> route, {
    double interval = 1.5,
    double maxDistance = 15.0,
  }) {
    if (route.isEmpty) return [];

    final waypoints = <Offset>[
      startPos,
      ...route.map((n) => Offset(n.x, n.y)),
    ];

    final sampledPoints = <Offset>[];
    double accumulatedDist = 0.0;
    double nextTargetDist = interval; // Titik pertama dimulai 1.5 meter di depan user

    for (int i = 0; i < waypoints.length - 1; i++) {
      final p1 = waypoints[i];
      final p2 = waypoints[i + 1];
      final segDx = p2.dx - p1.dx;
      final segDy = p2.dy - p1.dy;
      final segLen = math.sqrt(segDx * segDx + segDy * segDy);

      if (segLen <= 0.001) continue;

      final segStartDist = accumulatedDist;
      final segEndDist = accumulatedDist + segLen;

      while (nextTargetDist <= segEndDist) {
        if (nextTargetDist > maxDistance) return sampledPoints;

        final t = (nextTargetDist - segStartDist) / segLen;
        sampledPoints.add(Offset(p1.dx + segDx * t, p1.dy + segDy * t));
        nextTargetDist += interval;
      }

      accumulatedDist = segEndDist;
      if (nextTargetDist > maxDistance) break;
    }

    return sampledPoints;
  }

  /// Menggambar rentetan chevron (V terbalik) terpisah bercahaya neon (Glow + Core) di lantai
  void _drawChevrons(Canvas canvas, Size size, List<ProjectedPoint?> projectedList) {
    if (projectedList.isEmpty) return;

    const double maxLookahead = 15.0;

    for (int i = 0; i < projectedList.length; i++) {
      final pCurrent = projectedList[i];
      if (pCurrent == null || !pCurrent.isVisibleOnScreen) continue;

      // Skalakan ukuran, ketebalan, dan opasitas berdasarkan properti depth
      final double depth = pCurrent.depth;
      final double depthScale = (1.0 / math.max(depth, 1.0)).clamp(0.1, 1.0);
      final double opacity = (1.0 - (depth / maxLookahead)).clamp(0.15, 1.0);

      final double armWidth = 52.0 * depthScale;
      final double armLength = 28.0 * depthScale;

      // Layer 1 (Glow): Garis tebal dengan MaskFilter blur untuk pancaran cahaya neon
      final glowPaint = Paint()
        ..color = Colors.cyanAccent.withValues(alpha: opacity * 0.75)
        ..strokeWidth = (10.0 * depthScale).clamp(3.0, 10.0)
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6.0);

      // Layer 2 (Core): Garis tipis tanpa blur di tengah untuk inti neon putih-cyan yang tajam
      final corePaint = Paint()
        ..color = Colors.white.withValues(alpha: opacity)
        ..strokeWidth = (3.2 * depthScale).clamp(1.2, 3.2)
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;

      // Hitung orientasi rotasi chevron menghadap searah jalur rute berikutnya
      double angle;
      if (i < projectedList.length - 1 && projectedList[i + 1] != null) {
        final nextPos = projectedList[i + 1]!.screenPosition;
        final dx = nextPos.dx - pCurrent.screenPosition.dx;
        final dy = nextPos.dy - pCurrent.screenPosition.dy;
        angle = math.atan2(dy, dx);
      } else if (i > 0 && projectedList[i - 1] != null) {
        final prevPos = projectedList[i - 1]!.screenPosition;
        final dx = pCurrent.screenPosition.dx - prevPos.dx;
        final dy = pCurrent.screenPosition.dy - prevPos.dy;
        angle = math.atan2(dy, dx);
      } else {
        angle = -math.pi / 2.0; // Default menghadap ke depan layar
      }

      canvas.save();
      canvas.translate(pCurrent.screenPosition.dx, pCurrent.screenPosition.dy);
      canvas.rotate(angle);

      // Bentuk 1 buah Chevron (V terbalik menghadap arah jalur)
      final chevronPath = Path()
        ..moveTo(-armLength, -armWidth / 2.0)
        ..lineTo(0, 0) // Ujung depan (tip)
        ..lineTo(-armLength, armWidth / 2.0);

      // Render Layer 1: Glow neon tebal
      canvas.drawPath(chevronPath, glowPaint);

      // Render Layer 2: Core neon tipis & tajam
      canvas.drawPath(chevronPath, corePaint);

      canvas.restore();
    }
  }



  /// Menggambar satu panah penuntun utama 3D besar di tengah-bawah layar (~70% tinggi layar)
  /// yang berputar sebesar sudut relatif target terhadap arah hadap HP.
  void _drawMainGuidingArrow(Canvas canvas, Size size) {
    final center = Offset(size.width / 2.0, size.height * 0.70);
    final isUTurn = smoothedRelativeAngleDeg.abs() > 120.0;

    canvas.save();
    canvas.translate(center.dx, center.dy);

    // 1. Cincin radar kompas futuristik berdenyut halus
    final pulse = 1.0 + 0.05 * math.sin(animationValue * 2 * math.pi);
    final ringRadius = 46.0 * pulse;

    final discPaint = Paint()
      ..color = const Color(0x880F1420)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset.zero, ringRadius, discPaint);

    final glowRingPaint = Paint()
      ..color = isUTurn ? const Color(0x44FF3D00) : const Color(0x3300FF88)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6.0
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8.0);
    canvas.drawCircle(Offset.zero, ringRadius, glowRingPaint);

    final ringBorderPaint = Paint()
      ..color = isUTurn ? const Color(0xAAFF5252) : const Color(0x8800E5FF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8;
    canvas.drawCircle(Offset.zero, ringRadius, ringBorderPaint);

    // Crosshair lembut di radar
    final crossPaint = Paint()
      ..color = Colors.white24
      ..strokeWidth = 1.0;
    canvas.drawLine(const Offset(-8, 0), const Offset(8, 0), crossPaint);
    canvas.drawLine(const Offset(0, -8), const Offset(0, 8), crossPaint);

    // 2. Rotasi panah sesuai sudut relatif (0° = menunjuk lurus ke atas / depan layar)
    final rotRad = smoothedRelativeAngleDeg * math.pi / 180.0;
    canvas.rotate(rotRad);

    const arrowLength = 52.0;
    const arrowWidth = 42.0;

    // Bayangan glow di bawah panah
    final shadowPath = _createMainArrowPath(arrowWidth * 1.15, arrowLength * 1.15);
    final shadowPaint = Paint()
      ..color = isUTurn ? const Color(0x66FF1744) : const Color(0x6600E5FF)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10.0)
      ..style = PaintingStyle.fill;
    canvas.drawPath(shadowPath, shadowPaint);

    // Belahan kiri panah 3D (highlight lebih terang)
    final leftPath = _createMainArrowHalfPath(arrowWidth, arrowLength, isLeft: true);
    final leftPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomLeft,
        colors: isUTurn
            ? [const Color(0xFFFF8A80), const Color(0xFFFF1744)]
            : [const Color(0xFF00FFFF), const Color(0xFF00E676)],
      ).createShader(Rect.fromLTWH(-arrowWidth / 2, -arrowLength * 0.6, arrowWidth / 2, arrowLength))
      ..style = PaintingStyle.fill;
    canvas.drawPath(leftPath, leftPaint);

    // Belahan kanan panah 3D (shading lebih gelap untuk efek beveled 3D)
    final rightPath = _createMainArrowHalfPath(arrowWidth, arrowLength, isLeft: false);
    final rightPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomRight,
        colors: isUTurn
            ? [const Color(0xFFFF5252), const Color(0xFFD50000)]
            : [const Color(0xFF00B0FF), const Color(0xFF00BFA5)],
      ).createShader(Rect.fromLTWH(0, -arrowLength * 0.6, arrowWidth / 2, arrowLength))
      ..style = PaintingStyle.fill;
    canvas.drawPath(rightPath, rightPaint);

    // Garis rim luar putih tajam
    final fullPath = _createMainArrowPath(arrowWidth, arrowLength);
    final outlinePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.95)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(fullPath, outlinePaint);

    // Garis ridge tengah 3D
    final ridgePaint = Paint()
      ..color = Colors.white
      ..strokeWidth = 1.5;
    canvas.drawLine(
      Offset(0, -arrowLength * 0.6),
      Offset(0, arrowLength * 0.25),
      ridgePaint,
    );

    canvas.restore();

    // 3. Jika sudut relatif > 120°, tampilkan teks "Putar Balik"
    if (isUTurn) {
      _drawUTurnBadge(canvas, center.translate(0, 48));
    }
  }

  /// Membuat jalur penuh panah penuntun 3D (menghadap ke ATAS pada orientasi 0)
  Path _createMainArrowPath(double width, double length) {
    final path = Path();
    final halfW = width / 2.0;

    path.moveTo(0, -length * 0.6); // Ujung panah atas
    path.lineTo(-halfW, length * 0.4); // Sayap kiri
    path.lineTo(0, length * 0.25); // Lekukan tengah belakang
    path.lineTo(halfW, length * 0.4); // Sayap kanan
    path.close();

    return path;
  }

  /// Membuat separuh belahan panah penuntun 3D untuk efek pencahayaan berbeda
  Path _createMainArrowHalfPath(double width, double length, {required bool isLeft}) {
    final path = Path();
    final xSign = isLeft ? -1.0 : 1.0;
    final halfW = (width / 2.0) * xSign;

    path.moveTo(0, -length * 0.6);
    path.lineTo(halfW, length * 0.4);
    path.lineTo(0, length * 0.25);
    path.close();

    return path;
  }

  /// Menggambar badge peringatan "Putar Balik"
  void _drawUTurnBadge(Canvas canvas, Offset position) {
    const pillW = 120.0;
    const pillH = 30.0;
    final rrect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: position, width: pillW, height: pillH),
      const Radius.circular(15),
    );
    final bgPaint = Paint()
      ..color = const Color(0xE6D50000)
      ..style = PaintingStyle.fill;
    final borderPaint = Paint()
      ..color = const Color(0xFFFF5252)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawRRect(rrect, bgPaint);
    canvas.drawRRect(rrect, borderPaint);

    final tp = TextPainter(
      text: const TextSpan(
        text: '🔄 Putar Balik',
        style: TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    tp.layout();
    tp.paint(canvas, Offset(position.dx - tp.width / 2, position.dy - tp.height / 2));
  }

  /// Menggambar pin 3D melayang di atas slot tujuan
  void _drawDestinationPin(Canvas canvas, Size size, Offset userOffset) {
    final slotOffset = Offset(targetSlot!.x, targetSlot!.y);
    final dist = (slotOffset - userOffset).distance;
    if (dist < 0.5 || dist > 18.0) return; // Jangan gambar jika < 0.5m (terlalu dekat) atau > 18m

    final projected = projector.projectPoint(
      point: slotOffset,
      userPosition: userOffset,
      mapHeadingDeg: mapHeadingDeg,
      pitchDeg: pitchDeg,
      screenSize: size,
    );

    if (projected == null || !projected.isVisibleOnScreen) return;

    final pos = projected.screenPosition;
    final elevation = (projected.scale * 0.8).clamp(35.0, 100.0);
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

    final pinShadowPaint = Paint()
      ..color = const Color(0x66000000)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6.0);
    canvas.drawCircle(pinTop.translate(0, 3), pinRadius, pinShadowPaint);

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

    // Ambil waypoint rute berikutnya di depan pengguna
    Offset nextTarget = waypoints[1];
    for (int i = 1; i < waypoints.length; i++) {
      if ((waypoints[i] - userOffset).distance >= 0.8) {
        nextTarget = waypoints[i];
        break;
      }
    }

    final projected = projector.projectPoint(
      point: nextTarget,
      userPosition: userOffset,
      mapHeadingDeg: mapHeadingDeg,
      pitchDeg: pitchDeg,
      screenSize: size,
    );

    // Dapatkan panduan arah belok dari satu sumber kebenaran yang sama (ambang lurus +-20 derajat)
    final guidance = ARProjector.getOffScreenGuidance(
      userPos: userOffset,
      userHeadingDeg: mapHeadingDeg,
      targetPoint: nextTarget,
    );

    // Jika arah lurus, penunjuk tepi tidak perlu ditampilkan
    if (guidance.direction == TurnDirection.straight) {
      return;
    }

    // Jika waypoint di depan terlihat jelas di dalam layar (dan bukan putar balik), tidak perlu peringatan tepi
    if (projected != null && projected.isVisibleOnScreen && guidance.direction != TurnDirection.uTurn) {
      return;
    }

    final isLeft = guidance.direction == TurnDirection.left ||
        guidance.direction == TurnDirection.slightLeft;
    final isRight = guidance.direction == TurnDirection.right ||
        guidance.direction == TurnDirection.slightRight;
    final isUTurn = guidance.direction == TurnDirection.uTurn;

    final indicatorY = size.height * 0.45;
    final pillWidth = isUTurn ? 140.0 : 130.0;
    final halfW = pillWidth / 2.0;

    final indicatorX = isLeft
        ? (halfW + 16.0)
        : isRight
            ? (size.width - halfW - 16.0)
            : (size.width / 2.0);

    final targetOffset = isUTurn
        ? Offset(indicatorX, size.height * 0.55)
        : Offset(indicatorX, indicatorY);

    _drawEdgeArrow(canvas, targetOffset, guidance, isLeft, isRight, isUTurn);
  }

  /// Menggambar widget panah berdenyut di tepi layar
  void _drawEdgeArrow(
    Canvas canvas,
    Offset position,
    OffScreenGuidance guidance,
    bool isLeft,
    bool isRight,
    bool isUTurn,
  ) {
    final pulseScale = 1.0 + 0.12 * math.sin(animationValue * 2 * math.pi);

    canvas.save();
    canvas.translate(position.dx, position.dy);
    canvas.scale(pulseScale);

    final pillRect = Rect.fromCenter(
      center: Offset.zero,
      width: isUTurn ? 140 : 124,
      height: 44,
    );
    final pillPaint = Paint()
      ..color = const Color(0xE61E222D)
      ..style = PaintingStyle.fill;
    final borderPaint = Paint()
      ..color = const Color(0xFF00E5FF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    canvas.drawRRect(
      RRect.fromRectAndRadius(pillRect, const Radius.circular(22)),
      pillPaint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(pillRect, const Radius.circular(22)),
      borderPaint,
    );

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
    return true;
  }
}
