import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartparking/services/ar_projector.dart';

void main() {
  group('ARProjector Math & Bearing Tests', () {
    test('normalizeAngleDeg normalizes angles to [0, 360)', () {
      expect(ARProjector.normalizeAngleDeg(0), equals(0.0));
      expect(ARProjector.normalizeAngleDeg(360), equals(0.0));
      expect(ARProjector.normalizeAngleDeg(450), equals(90.0));
      expect(ARProjector.normalizeAngleDeg(-90), equals(270.0));
      expect(ARProjector.normalizeAngleDeg(-360), equals(0.0));
    });

    test('angleDifferenceDeg returns signed difference in [-180, 180]', () {
      // Menghadap utara (0), target timur (90) -> belok kanan +90
      expect(ARProjector.angleDifferenceDeg(90, 0), equals(90.0));
      // Menghadap timur (90), target utara (0) -> belok kiri -90
      expect(ARProjector.angleDifferenceDeg(0, 90), equals(-90.0));
      // Menghadap 350, target 10 -> belok kanan +20
      expect(ARProjector.angleDifferenceDeg(10, 350), equals(20.0));
      // Menghadap 10, target 350 -> belok kiri -20
      expect(ARProjector.angleDifferenceDeg(350, 10), equals(-20.0));
      // Menghadap utara (0), target selatan (180) -> 180
      expect(ARProjector.angleDifferenceDeg(180, 0).abs(), equals(180.0));
    });

    test('calculateBearingDeg computes correct bearing on 2D map (+X right, +Y down)', () {
      const origin = Offset(10, 10);
      // Gerak ke kanan (+X): 0 deg
      expect(ARProjector.calculateBearingDeg(origin, const Offset(20, 10)), equals(0.0));
      // Gerak ke bawah (+Y): 90 deg
      expect(ARProjector.calculateBearingDeg(origin, const Offset(10, 20)), equals(90.0));
      // Gerak ke kiri (-X): 180 deg
      expect(ARProjector.calculateBearingDeg(origin, const Offset(0, 10)), equals(180.0));
      // Gerak ke atas (-Y): 270 deg
      expect(ARProjector.calculateBearingDeg(origin, const Offset(10, 0)), equals(270.0));
    });

    test('compassToMapHeading applies offset correctly', () {
      // Jika denah sumbu +X menghadap arah Timur (90 derajat kompas), offset = 90
      // Saat HP menghadap Timur (90 kompas), heading denah = 0 (menghadap +X)
      expect(ARProjector.compassToMapHeading(90, 90), equals(0.0));
      // Saat HP menghadap Selatan (180 kompas), heading denah = 90 (menghadap +Y)
      expect(ARProjector.compassToMapHeading(180, 90), equals(90.0));
    });

    test('calculateRelativeAngleDeg normalizes relative angle to [-180, 180]', () {
      expect(ARProjector.calculateRelativeAngleDeg(90, 0), equals(90.0));
      expect(ARProjector.calculateRelativeAngleDeg(0, 90), equals(-90.0));
      expect(ARProjector.calculateRelativeAngleDeg(350, 10), equals(-20.0));
      expect(ARProjector.calculateRelativeAngleDeg(10, 350), equals(20.0));
      expect(ARProjector.calculateRelativeAngleDeg(180, 0).abs(), equals(180.0));
    });

    test('lerpAngleDeg smoothly interpolates along the shortest angular distance', () {
      // 0 to 90 at 50% -> 45
      expect(ARProjector.lerpAngleDeg(0, 90, 0.5), closeTo(45.0, 0.001));
      // Cross 180 boundary: 170 to -170 (-170 is 190 deg, diff is +20 deg)
      // at 50% -> 170 + 10 = 180 (or -180)
      expect(ARProjector.lerpAngleDeg(170, -170, 0.5).abs(), closeTo(180.0, 0.001));
      // -170 to 170 -> shortest diff is -20 deg, at 50% -> -180
      expect(ARProjector.lerpAngleDeg(-170, 170, 0.5).abs(), closeTo(180.0, 0.001));
    });
  });

  group('ARProjector 3D Perspective Projection Tests', () {
    const projector = ARProjector(
      cameraHeight: 1.4,
      fovHorizontalDeg: 60.0,
      maxProjectionDistance: 20.0,
    );
    const screenSize = Size(400, 800);

    test('projectPoint directly ahead is centered horizontally on screen', () {
      const userPos = Offset(0, 0);
      // Titik di depan pengguna (5m ke arah +X saat user menghadap 0 deg)
      const targetPoint = Offset(5.0, 0.0);

      final proj = projector.projectPoint(
        point: targetPoint,
        userPosition: userPos,
        mapHeadingDeg: 0.0,
        pitchDeg: 20.0, // Kemiringan HP 20 derajat ke bawah
        screenSize: screenSize,
      );

      expect(proj, isNotNull);
      // Secara horizontal tepat di tengah layar (x = 200)
      expect(proj!.screenPosition.dx, closeTo(200.0, 0.5));
      // Kedalaman Z positif
      expect(proj.depth, greaterThan(0.0));
      // Tampak di layar
      expect(proj.isVisibleOnScreen, isTrue);
    });

    test('point to the right appears on right side of screen', () {
      const userPos = Offset(0, 0);
      // Titik 5m ke depan, 2m ke kanan (+Y saat user menghadap 0 deg)
      const targetPoint = Offset(5.0, 2.0);

      final proj = projector.projectPoint(
        point: targetPoint,
        userPosition: userPos,
        mapHeadingDeg: 0.0,
        pitchDeg: 20.0,
        screenSize: screenSize,
      );

      expect(proj, isNotNull);
      // Berada di sebelah kanan tengah layar (> 200)
      expect(proj!.screenPosition.dx, greaterThan(200.0));
    });

    test('point to the left appears on left side of screen', () {
      const userPos = Offset(0, 0);
      // Titik 5m ke depan, 2m ke kiri (-Y saat user menghadap 0 deg)
      const targetPoint = Offset(5.0, -2.0);

      final proj = projector.projectPoint(
        point: targetPoint,
        userPosition: userPos,
        mapHeadingDeg: 0.0,
        pitchDeg: 20.0,
        screenSize: screenSize,
      );

      expect(proj, isNotNull);
      // Berada di sebelah kiri tengah layar (< 200)
      expect(proj!.screenPosition.dx, lessThan(200.0));
    });

    test('point behind camera returns null', () {
      const userPos = Offset(0, 0);
      // Titik di belakang pengguna (-5m ke arah sumbu)
      const targetPoint = Offset(-5.0, 0.0);

      final proj = projector.projectPoint(
        point: targetPoint,
        userPosition: userPos,
        mapHeadingDeg: 0.0,
        pitchDeg: 20.0,
        screenSize: screenSize,
      );

      // Titik di belakang kamera di-skip
      expect(proj, isNull);
    });

    test('point beyond maxProjectionDistance returns null', () {
      const userPos = Offset(0, 0);
      const targetPoint = Offset(50.0, 0.0); // 50m > 20m

      final proj = projector.projectPoint(
        point: targetPoint,
        userPosition: userPos,
        mapHeadingDeg: 0.0,
        pitchDeg: 20.0,
        screenSize: screenSize,
      );

      expect(proj, isNull);
    });

    test('perspective scale decreases with distance', () {
      const userPos = Offset(0, 0);
      final nearProj = projector.projectPoint(
        point: const Offset(3.0, 0.0),
        userPosition: userPos,
        mapHeadingDeg: 0.0,
        pitchDeg: 20.0,
        screenSize: screenSize,
      );

      final farProj = projector.projectPoint(
        point: const Offset(10.0, 0.0),
        userPosition: userPos,
        mapHeadingDeg: 0.0,
        pitchDeg: 20.0,
        screenSize: screenSize,
      );

      expect(nearProj, isNotNull);
      expect(farProj, isNotNull);
      expect(nearProj!.scale, greaterThan(farProj!.scale));
    });
  });

  group('OffScreenGuidance Tests', () {
    const userPos = Offset(10, 10);

    test('recommends straight when heading matches target', () {
      final guidance = ARProjector.getOffScreenGuidance(
        userPos: userPos,
        userHeadingDeg: 0.0,
        targetPoint: const Offset(20, 10), // Arah 0 deg
      );
      expect(guidance.direction, equals(TurnDirection.straight));
    });

    test('recommends right turn when target is 90 deg clockwise', () {
      final guidance = ARProjector.getOffScreenGuidance(
        userPos: userPos,
        userHeadingDeg: 0.0,
        targetPoint: const Offset(10, 20), // Arah 90 deg
      );
      expect(guidance.direction, equals(TurnDirection.right));
      expect(guidance.label, equals('Belok Kanan'));
    });

    test('recommends left turn when target is 90 deg counter-clockwise', () {
      final guidance = ARProjector.getOffScreenGuidance(
        userPos: userPos,
        userHeadingDeg: 90.0,
        targetPoint: const Offset(20, 10), // Arah 0 deg (kiri dari 90)
      );
      expect(guidance.direction, equals(TurnDirection.left));
      expect(guidance.label, equals('Belok Kiri'));
    });

    test('recommends U-turn when target is opposite direction', () {
      final guidance = ARProjector.getOffScreenGuidance(
        userPos: userPos,
        userHeadingDeg: 0.0,
        targetPoint: const Offset(0, 10), // Arah 180 deg
      );
      expect(guidance.direction, equals(TurnDirection.uTurn));
      expect(guidance.label, equals('Putar Balik'));
    });
  });

  group('Route Interpolation Tests', () {
    test('interpolates points smoothly along straight segment', () {
      final waypoints = [
        const Offset(0, 0),
        const Offset(5, 0),
      ];

      final points = ARProjector.interpolateRoutePoints(
        waypoints,
        spacing: 1.0,
        maxDistance: 10.0,
      );

      // Harusnya ada titik di 0, 1, 2, 3, 4, 5
      expect(points.length, greaterThanOrEqualTo(5));
      expect(points.first, equals(const Offset(0, 0)));
      expect(points.last.dx, closeTo(5.0, 1.0));
    });

    test('interpolateRoutePoints with minDistance skips close points and respects maxPoints', () {
      final waypoints = [
        const Offset(0, 0),
        const Offset(10, 0),
      ];

      final points = ARProjector.interpolateRoutePoints(
        waypoints,
        spacing: 1.0,
        minDistance: 1.8,
        maxPoints: 6,
        maxDistance: 15.0,
      );

      // Titik pertama harus berjarak >= 1.5 m (di 1.8 m)
      expect(points.first.dx, closeTo(1.8, 0.01));
      // Semua titik harus >= 1.5 m dari awal
      for (final pt in points) {
        expect(pt.dx, greaterThanOrEqualTo(1.5));
      }
      // Dibatasi maksimal 6 titik
      expect(points.length, equals(6));
      expect(points.last.dx, closeTo(6.8, 0.01));
    });
  });

  group('Heading Offset Calibration Tests', () {
    const projector = ARProjector(
      cameraHeight: 1.4,
      fovHorizontalDeg: 60.0,
      maxProjectionDistance: 20.0,
    );
    const screenSize = Size(400, 800);

    test('facing reference node aligns projection directly forward and straight', () {
      // Skenario 1: Titik awal di (10, 10), titik acuan di (20, 10) (sepanjang sumbu +X, bearing = 0°)
      const startPoint = Offset(10.0, 10.0);
      const refPoint = Offset(20.0, 10.0);

      final bearingMap = ARProjector.calculateBearingDeg(startPoint, refPoint);
      expect(bearingMap, equals(0.0));

      // Pengguna mengarahkan HP lurus ke titik acuan fisik di depannya,
      // dan kompas ponsel membaca 65° (Utara magnetik serong)
      const compassReading = 65.0;

      // Hitung heading offset kalibrasi:
      // headingOffset = normalizeAngleDeg(compass - bearingMap)
      final headingOffset = ARProjector.normalizeAngleDeg(compassReading - bearingMap);
      expect(headingOffset, equals(65.0));

      // Hitung arah hadap denah efektif:
      // effectiveMapHeading = normalizeAngleDeg(compass - headingOffset)
      final effectiveMapHeading = ARProjector.compassToMapHeading(compassReading, headingOffset);
      expect(effectiveMapHeading, equals(0.0));

      // Proyeksikan titik acuan ke layar kamera ponsel
      final projected = projector.projectPoint(
        point: refPoint,
        userPosition: startPoint,
        mapHeadingDeg: effectiveMapHeading,
        pitchDeg: 20.0,
        screenSize: screenSize,
      );

      // Verifikasi: titik acuan harus berada tepat di tengah horizontal layar (x = 200)
      expect(projected, isNotNull);
      expect(projected!.screenPosition.dx, closeTo(screenSize.width / 2.0, 0.5));
      expect(projected.isVisibleOnScreen, isTrue);

      // Verifikasi panduan arah belok: harus lurus ke depan (straight), bukan belok kanan/kiri
      final guidance = ARProjector.getOffScreenGuidance(
        userPos: startPoint,
        userHeadingDeg: effectiveMapHeading,
        targetPoint: refPoint,
      );
      expect(guidance.direction, equals(TurnDirection.straight));
    });

    test('calibration with angled reference node (+Y down) aligns correctly', () {
      // Skenario 2: Titik awal (10, 10), titik acuan (10, 20) (sepanjang sumbu +Y ke bawah, bearing = 90°)
      const startPoint = Offset(10.0, 10.0);
      const refPoint = Offset(10.0, 20.0);

      final bearingMap = ARProjector.calculateBearingDeg(startPoint, refPoint);
      expect(bearingMap, equals(90.0));

      // HP diarahkan lurus ke refPoint, kompas membaca 120°
      const compassReading = 120.0;

      final headingOffset = ARProjector.normalizeAngleDeg(compassReading - bearingMap);
      expect(headingOffset, equals(30.0));

      final effectiveMapHeading = ARProjector.compassToMapHeading(compassReading, headingOffset);
      expect(effectiveMapHeading, equals(90.0));

      final projected = projector.projectPoint(
        point: refPoint,
        userPosition: startPoint,
        mapHeadingDeg: effectiveMapHeading,
        pitchDeg: 20.0,
        screenSize: screenSize,
      );

      expect(projected, isNotNull);
      expect(projected!.screenPosition.dx, closeTo(screenSize.width / 2.0, 0.5));

      final guidance = ARProjector.getOffScreenGuidance(
        userPos: startPoint,
        userHeadingDeg: effectiveMapHeading,
        targetPoint: refPoint,
      );
      expect(guidance.direction, equals(TurnDirection.straight));
    });
  });
}
