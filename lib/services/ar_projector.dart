import 'dart:math' as math;
import 'dart:ui';

/// Hasil proyeksi 3D dari titik di denah lantai ke koordinat 2D layar kamera.
class ProjectedPoint {
  /// Koordinat piksel pada layar perangkat (u = x piksel, v = y piksel).
  final Offset screenPosition;

  /// Jarak kedalaman dari lensa kamera (Z dalam meter).
  final double depth;

  /// Faktor skala perspektif (semakin jauh titik, semakin kecil skalanya).
  final double scale;

  /// Apakah titik berada di dalam batas pandang layar (viewport).
  final bool isVisibleOnScreen;

  const ProjectedPoint({
    required this.screenPosition,
    required this.depth,
    required this.scale,
    required this.isVisibleOnScreen,
  });

  @override
  String toString() =>
      'ProjectedPoint(screen: (${screenPosition.dx.toStringAsFixed(1)}, ${screenPosition.dy.toStringAsFixed(1)}), depth: ${depth.toStringAsFixed(2)}m, visible: $isVisibleOnScreen)';
}

/// Arah belok yang direkomendasikan jika target di luar pandangan kamera.
enum TurnDirection {
  straight,
  slightLeft,
  left,
  slightRight,
  right,
  uTurn,
}

/// Informasi panduan arah belok untuk target di luar layar.
class OffScreenGuidance {
  final TurnDirection direction;
  final double angleDifferenceDeg;
  final String label;

  const OffScreenGuidance({
    required this.direction,
    required this.angleDifferenceDeg,
    required this.label,
  });
}

/// Service matematika proyeksi 3D perspektif ke layar 2D untuk AR indoor navigasi.
///
/// Mengubah koordinat denah parkir lokal (dalam meter) menjadi koordinat piksel layar
/// kamera ponsel menggunakan model kamera lubang jarum (*pinhole camera model*).
class ARProjector {
  /// Tinggi kamera dari lantai dalam meter (default 1.4 m saat HP dipegang di dada).
  final double cameraHeight;

  /// Field of View horizontal kamera dalam derajat (default 60° untuk kamera ponsel standar).
  final double fovHorizontalDeg;

  /// Jarak pandang maksimal rute ke depan yang diproyeksikan (dalam meter).
  final double maxProjectionDistance;

  /// Jarak minimal proyeksi (dalam meter). Jika jarak < minProjectionDistance,
  /// objek tidak akan diproyeksikan untuk mencegah panah membesar tanpa batas / menimpa UI.
  final double minProjectionDistance;

  const ARProjector({
    this.cameraHeight = 1.4,
    this.fovHorizontalDeg = 60.0,
    this.maxProjectionDistance = 15.0,
    this.minProjectionDistance = 0.5,
  });

  /// Normalisasi sudut dalam rentang [0, 360) derajat.
  static double normalizeAngleDeg(double deg) {
    final mod = deg % 360.0;
    return mod >= 0 ? mod : mod + 360.0;
  }

  /// Menghitung selisih sudut terkecil antara target dan orientasi saat ini dalam rentang [-180, 180] derajat.
  /// Nilai positif berarti target berada di sebelah KANAN, negatif berarti di sebelah KIRI.
  static double angleDifferenceDeg(double targetDeg, double currentDeg) {
    double diff = (targetDeg - currentDeg) % 360.0;
    if (diff > 180.0) diff -= 360.0;
    if (diff < -180.0) diff += 360.0;
    return diff;
  }

  /// Menghitung sudut relatif (dalam rentang [-180, 180] derajat) antara arah rute/target (mapBearing)
  /// dan arah hadap perangkat di denah (deviceHeading).
  /// 0° = tepat lurus ke depan, positif = belok kanan, negatif = belok kiri.
  static double calculateRelativeAngleDeg(double mapBearingDeg, double deviceHeadingDeg) {
    return angleDifferenceDeg(mapBearingDeg, deviceHeadingDeg);
  }

  /// Interpolasi sudut terpendek (Angular Lerp) dari [currentDeg] ke [targetDeg] dengan faktor [t] (0.0 - 1.0).
  /// Mencegah panah berputar instan atau berputar jauh saat sudut melintasi batas ±180°.
  static double lerpAngleDeg(double currentDeg, double targetDeg, double t) {
    final diff = angleDifferenceDeg(targetDeg, currentDeg);
    final next = currentDeg + diff * t.clamp(0.0, 1.0);
    return angleDifferenceDeg(next, 0.0);
  }

  /// Menghitung arah hadap (*bearing*) dari titik [from] ke titik [to]
  /// pada sistem koordinat denah (0° = sumbu +X / ke kanan, 90° = sumbu +Y / ke bawah).
  static double calculateBearingDeg(Offset from, Offset to) {
    final dx = to.dx - from.dx;
    final dy = to.dy - from.dy;
    final rad = math.atan2(dy, dx);
    return normalizeAngleDeg(rad * 180.0 / math.pi);
  }

  /// Mengonversi heading kompas perangkat (0° = Utara) ke orientasi denah lokal.
  ///
  /// [compassHeadingDeg]: heading dari sensor kompas (0 - 360°).
  /// [mapHeadingOffsetDeg]: offset kalibrasi sudut antara sumbu +X denah terhadap Utara sebenarnya.
  static double compassToMapHeading(
    double compassHeadingDeg,
    double mapHeadingOffsetDeg,
  ) {
    return normalizeAngleDeg(compassHeadingDeg - mapHeadingOffsetDeg);
  }

  /// Memproyeksikan satu titik di denah lantai [point] (x, y meter) ke koordinat piksel layar [screenSize].
  ///
  /// Parameter:
  /// - [point]: Posisi titik di lantai denah (dalam meter).
  /// - [userPosition]: Posisi pengguna saat ini di denah (dalam meter).
  /// - [mapHeadingDeg]: Arah hadap pengguna pada sistem denah (dalam derajat, 0 = +X, 90 = +Y).
  /// - [pitchDeg]: Sudut kemiringan HP ke bawah (dalam derajat). Positif = kamera menunduk ke lantai.
  /// - [screenSize]: Ukuran layar (lebar x tinggi dalam piksel).
  ProjectedPoint? projectPoint({
    required Offset point,
    required Offset userPosition,
    required double mapHeadingDeg,
    required double pitchDeg,
    required Size screenSize,
  }) {
    // 1. Transformasi Translasi: Vektor relatif dari posisi pengguna ke titik di denah
    final deltaX = point.dx - userPosition.dx;
    final deltaY = point.dy - userPosition.dy;
    final horizontalDist = math.sqrt(deltaX * deltaX + deltaY * deltaY);

    // Abaikan jika melebihi jarak pandang maksimal atau kurang dari batas minimal (< 0.5m)
    if (horizontalDist > maxProjectionDistance || horizontalDist < minProjectionDistance) {
      return null;
    }

    // 2. Transformasi Rotasi Yaw (Heading):
    // Putar terhadap arah hadap pengguna pada sumbu horizontal denah.
    // Sumbu denah: +X ke kanan, +Y ke bawah.
    // Jika user menghadap sudut theta:
    // Forward (ke depan) = cos(theta) * dX + sin(theta) * dY
    // Right (ke kanan)   = -sin(theta) * dX + cos(theta) * dY
    final headingRad = mapHeadingDeg * math.pi / 180.0;
    final cosH = math.cos(headingRad);
    final sinH = math.sin(headingRad);

    final zForward = deltaX * cosH + deltaY * sinH;
    final xRight = -deltaX * sinH + deltaY * cosH;
    // Lantai berada di bawah kamera setinggi cameraHeight (sumbu Y dunia ke atas = -cameraHeight)
    final yFloor = -cameraHeight;

    // 3. Transformasi Rotasi Pitch (Kemiringan vertikal HP):
    // Saat HP digenggam, pengguna memiringkan HP ke depan/bawah (pitch > 0).
    // Rotasi pada sumbu X kamera:
    // Z_cam = Z_forward * cos(pitch) - Y_floor * sin(pitch)
    // Y_cam = Y_floor * cos(pitch) + Z_forward * sin(pitch)
    // X_cam = X_right
    final pitchRad = pitchDeg * math.pi / 180.0;
    final cosP = math.cos(pitchRad);
    final sinP = math.sin(pitchRad);

    final zCam = zForward * cosP - yFloor * sinP;
    final yCam = yFloor * cosP + zForward * sinP;
    final xCam = xRight;

    // Titik berada di belakang lensa kamera atau terlalu dekat (< minProjectionDistance / 0.5 m)
    if (zCam < minProjectionDistance || zCam <= 0.2) {
      return null;
    }

    // 4. Proyeksi Perspektif (Pinhole Camera):
    // Panjang fokus horizontal dalam piksel: fx = (screen.width / 2) / tan(FOV / 2)
    final halfFovRad = (fovHorizontalDeg * math.pi / 180.0) / 2.0;
    final fx = (screenSize.width / 2.0) / math.tan(halfFovRad);
    final fy = fx; // Asumsi piksel persegi (square pixels)

    final xProj = (xCam / zCam) * fx;
    final yProj = (yCam / zCam) * fy;

    // 5. Konversi ke Koordinat Layar Piksel:
    // Titik pusat layar (width / 2, height / 2).
    // Dalam koordinat layar Flutter: (0,0) di kiri-atas, sumbu Y bertambah ke BAWAH.
    // Sumbu Y kamera bertambah ke ATAS, sehingga yScreen = height / 2 - yProj.
    final screenX = (screenSize.width / 2.0) + xProj;
    final screenY = (screenSize.height / 2.0) - yProj;

    final isVisible = screenX >= -20 &&
        screenX <= screenSize.width + 20 &&
        screenY >= -20 &&
        screenY <= screenSize.height + 20;

    // Batasi skala agar tidak membesar tanpa batas dan menutupi UI
    final scaleFactor = (fx / math.max(zCam, minProjectionDistance)).clamp(0.1, 120.0);

    return ProjectedPoint(
      screenPosition: Offset(screenX, screenY),
      depth: zCam,
      scale: scaleFactor,
      isVisibleOnScreen: isVisible,
    );
  }

  /// Menentukan panduan arah belok jika waypoint target di depan pengguna
  /// berada di luar jangkauan pandang layar atau di belakang pengguna.
  static OffScreenGuidance getOffScreenGuidance({
    required Offset userPos,
    required double userHeadingDeg,
    required Offset targetPoint,
  }) {
    final targetBearing = calculateBearingDeg(userPos, targetPoint);
    final diff = angleDifferenceDeg(targetBearing, userHeadingDeg);

    if (diff.abs() <= 20.0) {
      return OffScreenGuidance(
        direction: TurnDirection.straight,
        angleDifferenceDeg: diff,
        label: 'Lurus',
      );
    } else if (diff > 20.0 && diff <= 55.0) {
      return OffScreenGuidance(
        direction: TurnDirection.slightRight,
        angleDifferenceDeg: diff,
        label: 'Sedikit Serong Kanan',
      );
    } else if (diff > 55.0 && diff <= 120.0) {
      return OffScreenGuidance(
        direction: TurnDirection.right,
        angleDifferenceDeg: diff,
        label: 'Belok Kanan',
      );
    } else if (diff < -20.0 && diff >= -55.0) {
      return OffScreenGuidance(
        direction: TurnDirection.slightLeft,
        angleDifferenceDeg: diff,
        label: 'Sedikit Serong Kiri',
      );
    } else if (diff < -55.0 && diff >= -120.0) {
      return OffScreenGuidance(
        direction: TurnDirection.left,
        angleDifferenceDeg: diff,
        label: 'Belok Kiri',
      );
    } else {
      return OffScreenGuidance(
        direction: TurnDirection.uTurn,
        angleDifferenceDeg: diff,
        label: 'Putar Balik',
      );
    }
  }

  /// Menginterpolasi daftar node rute menjadi titik-titik berjarak rapat (setiap [spacing] meter)
  /// hingga jarak maksimal [maxDistance] meter dari posisi pengguna,
  /// agar panah AR di lantai dapat digambar berjejer secara mulus.
  ///
  /// Jika [minDistance] > 0, titik-titik dengan jarak < [minDistance] akan dilewati (misal lookahead 1.5 - 2m).
  /// [maxPoints] membatasi jumlah maksimal titik yang dihasilkan jika bernilai > 0.
  static List<Offset> interpolateRoutePoints(
    List<Offset> waypoints, {
    double spacing = 1.0,
    double maxDistance = 15.0,
    double minDistance = 0.0,
    int maxPoints = -1,
  }) {
    if (waypoints.isEmpty) return [];
    if (waypoints.length == 1) return minDistance <= 0.0 ? [waypoints.first] : [];

    final result = <Offset>[];
    if (minDistance <= 0.0) {
      result.add(waypoints.first);
    }

    double accumulatedDistance = 0.0;
    double nextSampleDist = minDistance > 0.0 ? minDistance : spacing;

    for (int i = 0; i < waypoints.length - 1; i++) {
      final p1 = waypoints[i];
      final p2 = waypoints[i + 1];
      final segDx = p2.dx - p1.dx;
      final segDy = p2.dy - p1.dy;
      final segLength = math.sqrt(segDx * segDx + segDy * segDy);

      if (segLength <= 0.001) continue;

      final segStartDist = accumulatedDistance;
      final segEndDist = accumulatedDistance + segLength;

      while (nextSampleDist <= segEndDist) {
        if (nextSampleDist > maxDistance) {
          return result;
        }
        if (maxPoints > 0 && result.length >= maxPoints) {
          return result;
        }

        final distIntoSeg = nextSampleDist - segStartDist;
        final ratio = (distIntoSeg / segLength).clamp(0.0, 1.0);
        result.add(Offset(p1.dx + segDx * ratio, p1.dy + segDy * ratio));

        nextSampleDist += spacing;
      }

      accumulatedDistance = segEndDist;
    }

    if (minDistance <= 0.0 && result.length < 2 && waypoints.length > 1) {
      result.add(waypoints[1]);
    }

    return result;
  }
}
