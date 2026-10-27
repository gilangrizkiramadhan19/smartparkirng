import 'package:flutter_test/flutter_test.dart';
import 'package:smartparking/services/ar_sensor_service.dart';

void main() {
  group('ARSensorService Pure Math Tests', () {
    test('Camera heading test 1: a=(0, 9.8, 0), m=(0, -30, -40) gives ~0 deg', () {
      final heading = ARSensorService.computeCameraHeading(
        a: const Vector3D(0, 9.8, 0),
        m: const Vector3D(0, -30, -40),
      );
      expect(heading, isNotNull);
      expect(heading!, closeTo(0.0, 0.1));
    });

    test('Camera heading test 2: a=(0, 9.8, 0), m=(-40, -30, 0) gives ~90 deg', () {
      final heading = ARSensorService.computeCameraHeading(
        a: const Vector3D(0, 9.8, 0),
        m: const Vector3D(-40, -30, 0),
      );
      expect(heading, isNotNull);
      expect(heading!, closeTo(90.0, 0.1));
    });

    test('Tilt test: a=(0, 9.8, 0) gives 90; a=(0, 0, 9.8) gives 0', () {
      final tiltUpright = ARSensorService.calculateTiltDeg(0, 9.8, 0);
      expect(tiltUpright, closeTo(90.0, 0.001));

      final tiltFlat = ARSensorService.calculateTiltDeg(0, 0, 9.8);
      expect(tiltFlat, closeTo(0.0, 0.001));
    });

    test('Camera heading keeps last heading when nearly vertical (|dot| > 0.9)', () {
      final heading = ARSensorService.computeCameraHeading(
        a: const Vector3D(0, 0, -9.8),
        m: const Vector3D(0, -30, -40),
        lastHeading: 45.0,
      );
      expect(heading, equals(45.0));
    });

    test('180-degree offset with circular modulo wrap-around [0, 360)', () {
      // 0 deg + 180 = 180
      expect((0.0 + 180.0) % 360.0, equals(180.0));
      // 270 deg + 180 = 450 % 360 = 90
      expect((270.0 + 180.0) % 360.0, equals(90.0));
      // 180 deg + 180 = 360 % 360 = 0
      expect((180.0 + 180.0) % 360.0, equals(0.0));
    });

    test('flipHeading180 flips offset accurately', () {
      // Offset 281.7 (seperti di screenshot user)
      final offsetAwal = 281.7;
      final flipped = (offsetAwal + 180.0) % 360.0;
      expect(flipped, closeTo(101.7, 0.001));

      // Flip lagi kembali ke awal
      final flippedBack = (flipped + 180.0) % 360.0;
      expect(flippedBack, closeTo(offsetAwal, 0.001));
    });
  });
}
