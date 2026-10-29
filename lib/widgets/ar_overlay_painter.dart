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

    // Pin tujuan: selalu gambar di titik AKHIR rute (currentRoute.last),
    // bukan dari targetSlot — agar selalu tampil selama ada rute aktif.
    final destNode = currentRoute.last;
    final destOffset = Offset(destNode.x, destNode.y);
    _drawDestinationPin(canvas, size, userOffset, destOffset);

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

    // 1 & 2. Interpolasi rute kurva halus (Chaikin): interval rapat 0.8 meter
    final routePoints = _interpolateRoutePoints(
      userOffset,
      currentRoute,
      interval: 0.8,
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

    // Gambar rentetan double-chevron (>>) neon yang mengikuti kurva halus
    _drawChevronRibbon(canvas, size, projectedList);

    // Panah radar 3D besar dinonaktifkan — UI cukup chevron lantai
    // _drawMainGuidingArrow(canvas, size);

    // 5. Cek apakah rute berikutnya berada di luar layar, gambar indikator tepi
    _drawOffScreenIndicatorIfNeeded(canvas, size, userOffset, waypoints);
  }

  /// Menghaluskan titik-titik belokan rute (corner rounding) menggunakan Chaikin's Algorithm.
  /// Memotong sudut tajam 90° menjadi lengkungan kurva halus yang natural seperti rute game/Geodux.
  List<Offset> _smoothPathChaikin(List<Offset> points, {int iterations = 3}) {
    if (points.length < 3) return points;

    List<Offset> current = List<Offset>.from(points);
    for (int it = 0; it < iterations; it++) {
      final smoothed = <Offset>[current.first];
      for (int i = 0; i < current.length - 1; i++) {
        final p0 = current[i];
        final p1 = current[i + 1];

        // Titik Q (25% dari p0 ke p1) dan R (75% dari p0 ke p1)
        final q = Offset(0.75 * p0.dx + 0.25 * p1.dx, 0.75 * p0.dy + 0.25 * p1.dy);
        final r = Offset(0.25 * p0.dx + 0.75 * p1.dx, 0.25 * p0.dy + 0.75 * p1.dy);

        smoothed.add(q);
        smoothed.add(r);
      }
      smoothed.add(current.last);
      current = smoothed;
    }
    return current;
  }

  /// Menelusuri total panjang rute kurva yang telah dihaluskan (Chaikin)
  /// dan menghasilkan titik-titik koordinat dengan interval jarak tetap (spacing rapat 0.8 m)
  List<Offset> _interpolateRoutePoints(
    Offset startPos,
    List<Node> route, {
    double interval = 0.8,
    double maxDistance = 15.0,
  }) {
    if (route.isEmpty) return [];

    final rawWaypoints = <Offset>[
      startPos,
      ...route.map((n) => Offset(n.x, n.y)),
    ];

    // Terapkan penghalusan Chaikin pada waypoints asli
    final smoothWaypoints = _smoothPathChaikin(rawWaypoints, iterations: 3);

    final sampledPoints = <Offset>[];
    double accumulatedDist = 0.0;
    double nextTargetDist = 0.6; // Titik pertama dimulai 0.6 m di depan user

    for (int i = 0; i < smoothWaypoints.length - 1; i++) {
      final p1 = smoothWaypoints[i];
      final p2 = smoothWaypoints[i + 1];
      final segDx = p2.dx - p1.dx;
      final segDy = p2.dy - p1.dy;
      final segLen = math.sqrt(segDx * segDx + segDy * segDy);

      if (segLen <= 0.0001) continue;

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

  // ─────────────────────────────────────────────────────────────────────────
  // HELPER: Catmull-Rom Spline – menghaluskan titik-titik screen space
  // menjadi kurva berkesinambungan dengan N segmen per pasangan titik kontrol.
  // ─────────────────────────────────────────────────────────────────────────
  List<Offset> _catmullRomSpline(
    List<Offset> points, {
    int samplesPerSegment = 12,
  }) {
    if (points.length < 2) return List<Offset>.from(points);

    final result = <Offset>[];

    // Duplikasi titik pertama & terakhir sebagai phantom control points
    final pts = <Offset>[
      points.first,
      ...points,
      points.last,
    ];

    for (int i = 1; i < pts.length - 2; i++) {
      final p0 = pts[i - 1];
      final p1 = pts[i];
      final p2 = pts[i + 1];
      final p3 = pts[i + 2];

      for (int s = 0; s <= samplesPerSegment; s++) {
        final t = s / samplesPerSegment;
        final t2 = t * t;
        final t3 = t2 * t;

        // Formula Catmull-Rom standar (alpha = 0.5)
        final dx = 0.5 *
            ((2.0 * p1.dx) +
                (-p0.dx + p2.dx) * t +
                (2.0 * p0.dx - 5.0 * p1.dx + 4.0 * p2.dx - p3.dx) * t2 +
                (-p0.dx + 3.0 * p1.dx - 3.0 * p2.dx + p3.dx) * t3);
        final dy = 0.5 *
            ((2.0 * p1.dy) +
                (-p0.dy + p2.dy) * t +
                (2.0 * p0.dy - 5.0 * p1.dy + 4.0 * p2.dy - p3.dy) * t2 +
                (-p0.dy + 3.0 * p1.dy - 3.0 * p2.dy + p3.dy) * t3);

        result.add(Offset(dx, dy));
      }
    }
    return result;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // HELPER: Ambil titik-titik berjarak piksel merata (arc-length parameterization)
  // di sepanjang kurva yang sudah di-spline. Hasilnya adalah list of (position, angle).
  // ─────────────────────────────────────────────────────────────────────────
  List<({Offset position, double angle})> _sampleEvenlySpacedPoints(
    List<Offset> curvePoints, {
    double spacingPx = 38.0,
    double startOffsetPx = 20.0,
  }) {
    final samples = <({Offset position, double angle})>[];
    if (curvePoints.length < 2) return samples;

    double accumulated = 0.0;
    double nextTarget = startOffsetPx;

    for (int i = 0; i < curvePoints.length - 1; i++) {
      final a = curvePoints[i];
      final b = curvePoints[i + 1];
      final segDx = b.dx - a.dx;
      final segDy = b.dy - a.dy;
      final segLen = math.sqrt(segDx * segDx + segDy * segDy);
      if (segLen < 0.001) continue;

      final segStart = accumulated;
      final segEnd = accumulated + segLen;

      while (nextTarget <= segEnd) {
        final t = (nextTarget - segStart) / segLen;
        final pos = Offset(a.dx + segDx * t, a.dy + segDy * t);
        final angle = math.atan2(segDy, segDx);
        samples.add((position: pos, angle: angle));
        nextTarget += spacingPx;
      }

      accumulated = segEnd;
    }
    return samples;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // HELPER: Gambar SATU set double-chevron (>>) di titik [center] dengan
  // rotasi [angle]. Ukuran & opacity disesuaikan oleh [depthRatio] (0=dekat, 1=jauh).
  // ─────────────────────────────────────────────────────────────────────────
  void _drawDoubleChevron(
    Canvas canvas,
    Offset center,
    double angle, {
    required double depthRatio,
    required double animPhase, // 0..1 untuk animasi pulse gerak
  }) {
    // Depth-based scaling & opacity (dekat → besar & terang, jauh → kecil & redup)
    final double depthScale = (1.0 - depthRatio * 0.78).clamp(0.15, 1.0);
    final double opacity    = (1.0 - depthRatio * 0.82).clamp(0.12, 1.0);

    // Ukuran satu pangkat (V tunggal) dalam koordinat lokal (menghadap +X saat angle=0)
    final double hw = 9.0 * depthScale;   // setengah-tinggi (half-height) >> atas/bawah
    final double vLen = 12.0 * depthScale; // panjang horizontal tiap V
    final double gap  =  7.0 * depthScale; // jarak antar V pertama & V kedua

    // ── Definisikan path untuk SATU V (chevron tunggal, menghadap kanan)
    // Koordinat lokal: tip di (vLen, 0), sayap kiri-atas di (0, -hw), sayap kiri-bawah di (0, hw)
    Path makeVPath(double offsetX) {
      return Path()
        ..moveTo(offsetX,        -hw)  // sayap atas (mundur)
        ..lineTo(offsetX + vLen,   0)  // ujung lancip
        ..lineTo(offsetX,         hw)  // sayap bawah (mundur)
        // jangan close() – biarkan open stroke agar terlihat seperti >>
        ;
    }

    // Dua V berjajar: V pertama di x=0, V kedua di x=gap
    final v1 = makeVPath(0.0);
    final v2 = makeVPath(gap);

    // Bounding rect untuk gradient shader (mencakup kedua V)
    final rect = Rect.fromLTWH(-2.0, -hw - 2.0, vLen + gap + 4.0, hw * 2.0 + 4.0);
    // Offset seluruh gambar agar pusat chevron di origin (bukan kiri)
    final shiftX = -(vLen + gap) / 2.0;

    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(angle);
    canvas.translate(shiftX, 0.0); // tengahkan secara horizontal

    // ── Layer 1: OUTER GLOW (blur lebar, cyan terang)
    final glowPaint = Paint()
      ..color = const Color(0xFF00E5FF).withValues(alpha: opacity * 0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = (6.5 * depthScale).clamp(2.0, 6.5)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, (8.0 * depthScale).clamp(2.5, 8.0));
    canvas.drawPath(v1, glowPaint);
    canvas.drawPath(v2, glowPaint);

    // ── Layer 2: MID GLOW (medium blur, warna neon solid)
    final midGlowPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: [
          const Color(0xFF00B0FF).withValues(alpha: opacity * 0.80),
          const Color(0xFF00FFFF).withValues(alpha: opacity * 0.95),
        ],
      ).createShader(rect)
      ..style = PaintingStyle.stroke
      ..strokeWidth = (3.5 * depthScale).clamp(1.2, 3.5)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, (3.5 * depthScale).clamp(1.0, 3.5));
    canvas.drawPath(v1, midGlowPaint);
    canvas.drawPath(v2, midGlowPaint);

    // ── Layer 3: CORE (garis tipis putih cemerlang tanpa blur)
    final corePaint = Paint()
      ..color = Colors.white.withValues(alpha: opacity * 0.92)
      ..style = PaintingStyle.stroke
      ..strokeWidth = (1.6 * depthScale).clamp(0.5, 1.6)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(v1, corePaint);
    canvas.drawPath(v2, corePaint);

    canvas.restore();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // MAIN: Render jalur double-chevron (>>) neon yang mengikuti kurva halus.
  //
  // Pipeline:
  //   1. Ekstrak titik screen yang valid dari projectedList
  //   2. Haluskan dengan Catmull-Rom Spline (screen-space)
  //   3. Sample titik berjarak merata (even spacing)
  //   4. Gambar double-chevron (>>) di setiap titik sample dengan rotasi tangent
  // ─────────────────────────────────────────────────────────────────────────
  void _drawChevronRibbon(Canvas canvas, Size size, List<ProjectedPoint?> projectedList) {
    if (projectedList.isEmpty) return;

    const double maxDepth = 15.0;

    // ── STEP 1: Kumpulkan titik screen yang valid & dalam batas layar
    final validPoints = <({Offset screenPos, double depth})>[];
    for (final pp in projectedList) {
      if (pp == null || !pp.isVisibleOnScreen) continue;
      // Filter titik yang terlalu rendah (sangat dekat, di bawah horizon)
      if (pp.screenPosition.dy > size.height * 0.94) continue;
      // Filter titik yang di atas layar (di balik kamera)
      if (pp.screenPosition.dy < 0) continue;
      validPoints.add((screenPos: pp.screenPosition, depth: pp.depth));
    }
    if (validPoints.length < 2) return;

    // ── STEP 2: Catmull-Rom Spline pada koordinat screen
    final rawScreenPts = validPoints.map((v) => v.screenPos).toList();
    final smoothCurve = _catmullRomSpline(rawScreenPts, samplesPerSegment: 10);
    if (smoothCurve.length < 2) return;

    // ── STEP 3: Sample berjarak merata di sepanjang kurva halus
    //   Spacing dalam piksel: ~36px (terasa proporsional di semua ukuran layar)
    final spacingPx = (size.width * 0.09).clamp(28.0, 46.0);
    final chevronSamples = _sampleEvenlySpacedPoints(
      smoothCurve,
      spacingPx: spacingPx,
      startOffsetPx: spacingPx * 0.5,
    );
    if (chevronSamples.isEmpty) return;

    // ── STEP 4: Gambar dari TERJAUH ke TERDEKAT (painter's algorithm)
    // Perlu memetakan posisi sample ke depth dari validPoints terdekat
    for (int si = chevronSamples.length - 1; si >= 0; si--) {
      final sample = chevronSamples[si];
      final pos = sample.position;
      final angle = sample.angle;

      // Interpolasi depth: cari validPoint terdekat dari posisi sample
      double bestDepth = maxDepth;
      double bestDist2 = double.infinity;
      for (final vp in validPoints) {
        final ddx = vp.screenPos.dx - pos.dx;
        final ddy = vp.screenPos.dy - pos.dy;
        final dist2 = ddx * ddx + ddy * ddy;
        if (dist2 < bestDist2) {
          bestDist2 = dist2;
          bestDepth = vp.depth;
        }
      }
      final depthRatio = (bestDepth / maxDepth).clamp(0.0, 1.0);

      // Fase animasi bergerak: chevron terdekat bergerak maju (pulse gerak)
      // Menggunakan si (index) + animationValue untuk efek "aliran"
      final animPhase = ((animationValue + si * 0.08) % 1.0);

      _drawDoubleChevron(
        canvas,
        pos,
        angle,
        depthRatio: depthRatio,
        animPhase: animPhase,
      );
    }
  }



  /// Menggambar Map Pin Merah 3D bergaya Google Maps melayang di atas titik tujuan.
  ///
  /// [destOffset] = koordinat map-space dari titik akhir rute (currentRoute.last).
  /// Fitur visual:
  ///  • Balon merah 3D (Path: kepala bulat + ekor runcing) dengan gradient radial
  ///  • Lubang lingkaran putih di tengah balon
  ///  • Highlight spekuler putih di sudut kiri-atas (efek glossy)
  ///  • Drop shadow oval transparan di lantai (ground anchor)
  ///  • Animasi bounce halus naik-turun
  void _drawDestinationPin(
    Canvas canvas,
    Size size,
    Offset userOffset,
    Offset destOffset,
  ) {
    final dist = (destOffset - userOffset).distance;
    // Jangan gambar jika terlalu dekat (sudah sampai) atau terlalu jauh (> 25 m)
    if (dist < 0.5 || dist > 25.0) return;

    final projected = projector.projectPoint(
      point: destOffset,
      userPosition: userOffset,
      mapHeadingDeg: mapHeadingDeg,
      pitchDeg: pitchDeg,
      screenSize: size,
    );
    if (projected == null || !projected.isVisibleOnScreen) return;

    final groundPos = projected.screenPosition;

    // ─── Ukuran pin berbasis depth (semakin dekat → semakin besar)
    final depthScale = projected.scale.clamp(0.4, 2.2);
    final pinW   = 36.0 * depthScale;   // lebar total balon
    final pinH   = 48.0 * depthScale;   // tinggi total (balon + ekor)
    final holeR  =  9.0 * depthScale;   // radius lubang tengah

    // Bounce animasi: naik-turun sinusoidal
    final bounce  = math.sin(animationValue * 2 * math.pi) * (5.0 * depthScale);
    // Elevasi melayang di atas titik lantai
    final elevation = (55.0 * depthScale).clamp(40.0, 120.0);
    // Titik pusat kepala balon
    final pinCenter = Offset(groundPos.dx, groundPos.dy - elevation + bounce);

    // ────────────────────────────────────────────────────
    // LAYER 1: Drop shadow oval di lantai (ground anchor)
    // ────────────────────────────────────────────────────
    final shadowRx = pinW * 0.60;
    final shadowRy = pinW * 0.18;
    // Opacity shadow mengecil seiring bounce (makin tinggi = shadow makin samar)
    final shadowOpacity = (0.55 - (bounce / (elevation + 1)) * 0.3).clamp(0.10, 0.55);
    final shadowPaint = Paint()
      ..color = const Color(0xFF000000).withValues(alpha: shadowOpacity)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, (6.0 * depthScale).clamp(3.0, 12.0))
      ..style = PaintingStyle.fill;
    canvas.drawOval(
      Rect.fromCenter(center: groundPos, width: shadowRx * 2, height: shadowRy * 2),
      shadowPaint,
    );

    // ────────────────────────────────────────────────────
    // LAYER 2: Badan pin (balon + ekor runcing) — bentuk Google Maps pin
    // Koordinat relatif terhadap pinCenter (titik pusat kepala balon)
    // ────────────────────────────────────────────────────
    final r   = pinW / 2.0;    // radius kepala balon
    final tip = pinH - r;      // panjang ekor dari bawah kepala ke ujung runcing

    // Path: lingkaran kepala + ekor segitiga yang menyatu mulus (Bézier)
    final pinPath = Path();
    // Mulai dari titik kiri-bawah kepala (awal lengkungan)
    pinPath.moveTo(pinCenter.dx - r * 0.55, pinCenter.dy + r * 0.82);
    // Ekor runcing — ujung ke bawah
    pinPath.quadraticBezierTo(
      pinCenter.dx,           pinCenter.dy + r * 1.1,  // control point (tengah antara badan & tip)
      pinCenter.dx,           pinCenter.dy + tip,       // ujung runcing
    );
    // Sisi kanan ekor
    pinPath.quadraticBezierTo(
      pinCenter.dx,           pinCenter.dy + r * 1.1,
      pinCenter.dx + r * 0.55, pinCenter.dy + r * 0.82,
    );
    // Busur kepala (kanan-bawah → atas → kiri-bawah)
    pinPath.arcTo(
      Rect.fromCircle(center: pinCenter, radius: r),
      0.55,           // startAngle (radian, kira-kira kanan-bawah)
      2 * math.pi * (270.0 / 360.0), // sweep 270° (meninggalkan celah di bawah untuk ekor)
      false,
    );
    pinPath.close();

    // Outer glow merah di belakang pin
    final glowPaint = Paint()
      ..color = const Color(0xFFE53935).withValues(alpha: 0.38)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, (10.0 * depthScale).clamp(5.0, 18.0))
      ..style = PaintingStyle.fill;
    canvas.drawPath(pinPath, glowPaint);

    // Gradient radial merah 3D (kiri-atas lebih terang, kanan-bawah lebih gelap)
    final pinBodyPaint = Paint()
      ..shader = RadialGradient(
        center: const Alignment(-0.45, -0.45),
        radius: 0.9,
        colors: const [
          Color(0xFFFF6B6B),  // highlight terang
          Color(0xFFE53935),  // merah medium
          Color(0xFFB71C1C),  // merah gelap
        ],
        stops: const [0.0, 0.55, 1.0],
      ).createShader(Rect.fromCircle(center: pinCenter, radius: r))
      ..style = PaintingStyle.fill;
    canvas.drawPath(pinPath, pinBodyPaint);

    // Rim/outline putih tipis
    final rimPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.80)
      ..style = PaintingStyle.stroke
      ..strokeWidth = (1.5 * depthScale).clamp(0.8, 2.5)
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(pinPath, rimPaint);

    // ────────────────────────────────────────────────────
    // LAYER 3: Lubang lingkaran putih di tengah kepala balon
    // ────────────────────────────────────────────────────
    // Shadow kecil di dalam lubang untuk kedalaman
    final holeShadowPaint = Paint()
      ..color = const Color(0x55000000)
      ..maskFilter = const MaskFilter.blur(BlurStyle.inner, 3.0)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(pinCenter, holeR + 1.5, holeShadowPaint);

    // Lingkaran putih solid
    final holePaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;
    canvas.drawCircle(pinCenter, holeR, holePaint);

    // ────────────────────────────────────────────────────
    // LAYER 4: Highlight spekuler glossy (kiri-atas kepala balon)
    // ────────────────────────────────────────────────────
    final highlightCenter = pinCenter.translate(-r * 0.28, -r * 0.30);
    final highlightPaint = Paint()
      ..shader = RadialGradient(
        colors: [
          Colors.white.withValues(alpha: 0.65),
          Colors.white.withValues(alpha: 0.0),
        ],
      ).createShader(Rect.fromCircle(center: highlightCenter, radius: r * 0.42))
      ..style = PaintingStyle.fill;
    canvas.drawCircle(highlightCenter, r * 0.42, highlightPaint);

    // ────────────────────────────────────────────────────
    // LAYER 5: Label slot parkir di bawah pin (jika ada targetSlot)
    // ────────────────────────────────────────────────────
    if (targetSlot != null) {
      final labelText = targetSlot!.id;
      final labelPainter = TextPainter(
        text: TextSpan(
          text: labelText,
          style: TextStyle(
            color: Colors.white,
            fontSize: (11.0 * depthScale).clamp(9.0, 16.0),
            fontWeight: FontWeight.bold,
            shadows: const [
              Shadow(color: Color(0xAA000000), blurRadius: 4, offset: Offset(1, 1)),
            ],
          ),
        ),
        textDirection: TextDirection.ltr,
      );
      labelPainter.layout();
      // Gambar label di bawah ujung ekor pin
      final labelPos = Offset(
        pinCenter.dx - labelPainter.width / 2,
        pinCenter.dy + tip + (4.0 * depthScale),
      );
      // Background pil label
      final labelBg = RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(pinCenter.dx, labelPos.dy + labelPainter.height / 2),
          width:  labelPainter.width + 12.0 * depthScale,
          height: labelPainter.height + 6.0 * depthScale,
        ),
        Radius.circular(4.0 * depthScale),
      );
      canvas.drawRRect(
        labelBg,
        Paint()..color = const Color(0xCCB71C1C),
      );
      labelPainter.paint(canvas, labelPos);
    }
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
