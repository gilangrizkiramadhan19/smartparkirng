 import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:pedometer/pedometer.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'ar_projector.dart';
import 'navigation_controller.dart';

/// Struktur 3D Vector sederhana untuk kalkulasi sensor & orientasi kamera.
class Vector3D {
  final double x;
  final double y;
  final double z;

  const Vector3D(this.x, this.y, this.z);

  double get length => math.sqrt(x * x + y * y + z * z);

  Vector3D normalize() {
    final len = length;
    if (len < 1e-9) return const Vector3D(0, 0, 0);
    return Vector3D(x / len, y / len, z / len);
  }

  static Vector3D cross(Vector3D v1, Vector3D v2) {
    return Vector3D(
      v1.y * v2.z - v1.z * v2.y,
      v1.z * v2.x - v1.x * v2.z,
      v1.x * v2.y - v1.y * v2.x,
    );
  }

  double dot(Vector3D other) {
    return x * other.x + y * other.y + z * other.z;
  }
}

/// Service untuk memproses input sensor perangkat (kompas, accelerometer, magnetometer, pedometer),
/// estimasi langkah kaki (*dead reckoning*), dan kalibrasi heading denah.
class ARSensorService extends ChangeNotifier {
  final NavigationController controller;

  // Sensor Subscriptions
  StreamSubscription<CompassEvent>? _compassSubscription;
  StreamSubscription<AccelerometerEvent>? _accelSubscription;
  StreamSubscription<MagnetometerEvent>? _magSubscription;
  StreamSubscription<GyroscopeEvent>? _gyroSubscription;
  StreamSubscription<StepCount>? _pedometerSubscription;

  // Accelerometer low-pass filtered components
  double _accelX = 0.0;
  double _accelY = 9.8;
  double _accelZ = 0.0;
  bool _hasAccel = false;

  // Magnetometer low-pass filtered components
  double _magX = 0.0;
  double _magY = 0.0;
  double _magZ = 0.0;
  double _magMagnitude = 0.0;
  bool _hasMag = false;
  DateTime? _lastMagEventTime;

  // Frekuensi event magnetometer (debug overlay)
  int _magEventCountInWindow = 0;
  double _magEventsPerSec = 0.0;
  DateTime _lastMagRateCalcTime = DateTime.now();

  // Heading & Kompas via FlutterCompass (Sensor TYPE_ROTATION_VECTOR, tilt-compensated)
  double _rawCompassHeading = 0.0;
  double _filteredCompassHeading = 0.0;
  double? _cameraHeadingDeg;
  double _filteredCameraHeading = 0.0;
  bool _hasCompass = false;
  bool _hasCameraHeading = false;
  DateTime? _lastCompassEventTime;


  // Kemiringan HP (Tilt: 0° datar, 90° tegak)
  double _devicePitchDeg = 90.0;
  double _lastRawPitch = 90.0;
  DateTime _lastPitchTime = DateTime.fromMillisecondsSinceEpoch(0);
  double _pitchVelocity = 0.0; // deg/sec (deteksi saat HP diangkat cepat)
  double _gyroMagnitude = 0.0; // rad/sec
  DateTime _lastFastRotationTime = DateTime.fromMillisecondsSinceEpoch(0);

  // Pedometer (Sumber Langkah Utama) & Step Source Tracking
  bool _isPedometerActive = false;
  int? _lastPedometerRawSteps;
  int _pedometerStepCount = 0;
  int _accelStepCount = 0;
  DateTime? _lastStepEventTime;

  // Kalibrasi Denah
  double _mapHeadingOffsetDeg = 0.0; // Offset kompas vs sumbu +X denah
  bool _isCalibrated = false;

  // Pedometer / Dead Reckoning (Ketat & Anti-False-Step)
  bool _isSimulationMode = false;
  double _stepLengthMeters = 0.55; // Default 0.55 meter untuk langkah indoor perumahan
  int _stepCount = 0;
  DateTime _lastStepTime = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _peakArmTime = DateTime.fromMillisecondsSinceEpoch(0);
  double _peakMagnitude = 0.0;
  double _prevAccelMagnitude = 9.8;
  double _filteredAccelMag = 9.8;
  bool _accelPeakArmed = false;

  // Metrik Debug Step Detection (kDebugMode)
  final List<_AccelSample> _recentAccelSamples = [];
  int _rejectedStepCount = 0;
  int _rejectedGyroCount = 0;
  int _rejectedPitchCount = 0;
  int _rejectedIntervalCount = 0;
  int _rejectedAmplitudeCount = 0;
  String _lastRejectReason = '';

  // Throttle Repaint (~30 FPS / 33 ms)
  Timer? _throttleTimer;
  bool _hasPendingRepaint = false;

  ARSensorService({
    required this.controller,
    bool isSimulationMode = false,
  }) : _isSimulationMode = isSimulationMode {
    _initSensors();
  }

  // --- Fungsi Murni Hitung Tilt & Heading Kamera ---

  /// Hitung sudut kemiringan HP (tilt dalam derajat).
  /// Android accelerometer mengukur vektor gravitasi menunjuk ke ATAS saat diam:
  /// - HP datar layar menghadap atas: z = +9.8, x=0, y=0 -> tilt = 0°
  /// - HP tegak mode portrait: y = +9.8, z=0 -> tilt = 90°
  /// Rumus: tilt = degrees(acos(|az| / |a|))
  static double calculateTiltDeg(double ax, double ay, double az) {
    final a = math.sqrt(ax * ax + ay * ay + az * az);
    if (a < 1e-6) return 0.0;
    final cosVal = (az.abs() / a).clamp(0.0, 1.0);
    return math.acos(cosVal) * 180.0 / math.pi;
  }

  /// Hitung heading arah kamera (3D) dari vektor accelerometer [a] dan magnetometer [m].
  ///
  /// Rumus:
  ///   up   = normalize(a)                              — sumbu gravitasi (ke atas)
  ///   east = normalize(cross(m, a))                   — sumbu Timur (horizontal)
  ///   north = cross(up, east)                         — sumbu Utara (horizontal)
  ///   heading = atan2(-east.z, -north.z)              — sudut kamera dari Utara
  ///
  /// Test cases yang harus dipenuhi:
  ///   a=(0,9.8,0) m=(0,-30,-40)  → 0°   (kamera menghadap Utara)
  ///   a=(0,9.8,0) m=(-40,-30,0)  → 90°  (kamera menghadap Timur)
  ///
  /// Guard: HP hampir datar (|az|/|a| > 0.9) → pertahankan heading terakhir.
  static double? computeCameraHeading({
    required Vector3D a,
    required Vector3D m,
    double? lastHeading,
  }) {
    if (a.length < 1e-6) return lastHeading;
    final up = a.normalize();

    // Guard: jika HP hampir datar (kamera tegak lurus ke atas/bawah),
    // heading dari kompas tidak reliable — pertahankan heading terakhir.
    final dotKamera = up.dot(const Vector3D(0, 0, -1)).abs();
    if (dotKamera > 0.9) {
      return lastHeading;
    }

    final crossMA = Vector3D.cross(m, a);
    if (crossMA.length < 1e-9) {
      return lastHeading;
    }
    final east = crossMA.normalize();
    final north = Vector3D.cross(up, east);

    final headingRad = math.atan2(-east.z, -north.z);
    return ARProjector.normalizeAngleDeg(headingRad * 180.0 / math.pi);
  }

  // --- Getters Sensor & Status ---

  double get accelX => _accelX;
  double get accelY => _accelY;
  double get accelZ => _accelZ;
  double get magX => _magX;
  double get magY => _magY;
  double get magZ => _magZ;
  double get magMagnitude => _magMagnitude;
  double get magEventsPerSec => _magEventsPerSec;

  double get devicePitchDeg => _devicePitchDeg;
  double get tiltDeg => _devicePitchDeg;
  bool get isTiltValid => _devicePitchDeg >= 55.0 && _devicePitchDeg <= 90.0;

  double? get cameraHeading => _hasCameraHeading ? _filteredCameraHeading : (_hasCompass ? _filteredCompassHeading : null);
  double get compassHeadingFlutterCompass => _filteredCompassHeading;

  /// Memvalidasi status kompas/heading
  bool get isCameraHeadingValid =>
      _hasCompass &&
      _lastCompassEventTime != null &&
      DateTime.now().difference(_lastCompassEventTime!).inMilliseconds <= 2000;

  /// Heading valid jika sensor kompas aktif dan diperbarui dalam 1.5 detik terakhir
  bool get isHeadingValid =>
      _hasCompass &&
      _lastCompassEventTime != null &&
      DateTime.now().difference(_lastCompassEventTime!).inMilliseconds <= 1500;

  /// True jika menggunakan kompas standar/flat (tanpa orientasi kamera remapped)
  bool get isUsingFallbackCompass => !_hasCameraHeading;
  String get headingSourceLabel {
    return 'flutter_compass';
  }

  double get preferredHeading {
    return compassHeadingFlutterCompass;
  }

  double get filteredCompassHeading => _filteredCompassHeading;
  double get rawHeadingFlat => _rawCompassHeading;
  double? get rawHeadingCamera => _hasCameraHeading ? _cameraHeadingDeg : null;

  /// Tidak ada mismatch karena kedua heading bersumber dari rotation vector yang konsisten.
  bool get headingMismatchWarning => false;

  bool get isPedometerActive => _isPedometerActive;
  bool get isFallbackMode => !_isPedometerActive;
  String get activeStepSourceName => _isPedometerActive ? 'Pedometer' : 'Accelerometer';
  int get pedometerStepCount => _pedometerStepCount;
  int get accelStepCount => _accelStepCount;
  DateTime? get lastStepEventTime => _lastStepEventTime;
  String get lastStepEventTimeFormatted {
    if (_lastStepEventTime == null) return '-';
    final t = _lastStepEventTime!;
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    final s = t.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  double get gyroMagnitude => _gyroMagnitude;
  double get mapHeadingOffsetDeg => _mapHeadingOffsetDeg;
  bool get hasCompass => _hasCompass;
  bool get isSimulationMode => _isSimulationMode;
  bool get isCalibrated => _isCalibrated;
  double get stepLengthMeters => _stepLengthMeters;
  int get stepCount => _stepCount;

  // Getters untuk Debug Overlay
  double get accelMagnitudeRealtime => _filteredAccelMag;
  double get accelPeak2Sec {
    if (_recentAccelSamples.isEmpty) return _filteredAccelMag;
    double maxMag = 0.0;
    for (final s in _recentAccelSamples) {
      if (s.mag > maxMag) maxMag = s.mag;
    }
    return maxMag;
  }
  int get acceptedStepCount => _stepCount;
  int get rejectedStepCount => _rejectedStepCount;
  int get rejectedGyroCount => _rejectedGyroCount;
  int get rejectedPitchCount => _rejectedPitchCount;
  int get rejectedIntervalCount => _rejectedIntervalCount;
  int get rejectedAmplitudeCount => _rejectedAmplitudeCount;
  String get lastRejectReason => _lastRejectReason;

  double get effectiveMapHeading {
    final raw = (compassHeadingFlutterCompass + mapHeadingOffsetDeg) % 360.0;
    return (raw + 360.0) % 360.0;
  }

  /// Memulai pendengaran sensor fisik HP saat service dibuat (ketika ArPage dibuka).
  void _initSensors() {
    initPedometer();

    try {
      // 1. Kompas flutter_compass (Sensor TYPE_ROTATION_VECTOR, otomatis tilt-compensated)
      _compassSubscription = FlutterCompass.events?.listen(
        (event) {
          final now = DateTime.now();
          _lastCompassEventTime = now;
          _hasCompass = true;

          // Gunakan event.heading standar, hardware menolak camera mode
          double rawHeading = event.heading ?? 0.0;
          _rawCompassHeading = (rawHeading % 360.0 + 360.0) % 360.0;
          _filteredCompassHeading = _circularEma(_filteredCompassHeading, _rawCompassHeading, 0.2);

          _requestThrottleRepaint();
        },
        onError: (_) {
          _hasCompass = false;
        },
      );
    } catch (_) {
      _hasCompass = false;
    }

    try {
      // 2. Gyroscope (Deteksi HP sedang berputar cepat / digerakkan tangan)
      _gyroSubscription = gyroscopeEventStream(samplingPeriod: SensorInterval.uiInterval).listen(
        (event) {
          _gyroMagnitude = math.sqrt(event.x * event.x + event.y * event.y + event.z * event.z);
          if (_gyroMagnitude > 3.0) {
            _lastFastRotationTime = DateTime.now();
          }
        },
        onError: (_) {},
      );
    } catch (_) {}

    try {
      // 3. Magnetometer (Untuk menghitung heading kamera 3D)
      _magSubscription = magnetometerEventStream(samplingPeriod: SensorInterval.uiInterval).listen(
        (event) {
          _processMagnetometer(event);
        },
        onError: (_) {},
      );
    } catch (_) {}

    try {
      // 4. Accelerometer (Pitch/Tilt, Heading Kamera, & Step Detection)
      _accelSubscription = accelerometerEventStream(samplingPeriod: SensorInterval.uiInterval).listen(
        (event) {
          _processAccelerometer(event);
        },
        onError: (_) {},
      );
    } catch (_) {}
  }

  /// Handler pemrosesan event Magnetometer: low-pass filter & pencatatan frekuensi event.
  void _processMagnetometer(MagnetometerEvent event) {
    final now = DateTime.now();
    _lastMagEventTime = now;

    _magEventCountInWindow++;
    final dtSec = now.difference(_lastMagRateCalcTime).inMilliseconds / 1000.0;
    if (dtSec >= 1.0) {
      _magEventsPerSec = _magEventCountInWindow / dtSec;
      _magEventCountInWindow = 0;
      _lastMagRateCalcTime = now;
    }

    // Low-pass filter magnetometer (EMA alpha = 0.25)
    const double alphaM = 0.25;
    if (!_hasMag) {
      _magX = event.x;
      _magY = event.y;
      _magZ = event.z;
      _hasMag = true;
    } else {
      _magX = _magX * (1.0 - alphaM) + event.x * alphaM;
      _magY = _magY * (1.0 - alphaM) + event.y * alphaM;
      _magZ = _magZ * (1.0 - alphaM) + event.z * alphaM;
    }
    _magMagnitude = math.sqrt(_magX * _magX + _magY * _magY + _magZ * _magZ);
    _requestThrottleRepaint();
  }

  /// Inisialisasi pedometer dinonaktifkan (dipaksa menggunakan accelerometer manual).
  void initPedometer() {
    _pedometerSubscription?.cancel();
    _pedometerSubscription = null;
    _isPedometerActive = false;
  }

  /// Menetapkan mode fallback ke sensor accelerometer jika izin ditolak atau sensor tidak tersedia.
  void fallbackToAccelerometer() {
    _pedometerSubscription?.cancel();
    _pedometerSubscription = null;
    _isPedometerActive = false;
    notifyListeners();
  }

  /// Handler pemrosesan event dari Pedometer.stepCountStream.
  void _onPedometerEvent(StepCount event) {
    _isPedometerActive = true;
    final currentSteps = event.steps;

    // 1. Abaikan nilai pertama sebagai baseline
    if (_lastPedometerRawSteps == null) {
      _lastPedometerRawSteps = currentSteps;
      notifyListeners();
      return;
    }

    // 2. Tangani reset hitungan
    if (currentSteps < _lastPedometerRawSteps!) {
      _lastPedometerRawSteps = currentSteps;
      notifyListeners();
      return;
    }

    // 3. Hitung selisih (delta) dari nilai sebelumnya
    int delta = currentSteps - _lastPedometerRawSteps!;
    _lastPedometerRawSteps = currentSteps;

    if (delta <= 0) return;

    if (delta > 3) {
      delta = 3;
    }

    _pedometerStepCount += delta;
    _lastStepEventTime = event.timeStamp;

    for (int i = 0; i < delta; i++) {
      _onStepDetected(fromPedometer: true);
    }
  }

  /// Low-pass filter (Exponential Moving Average) untuk kompas cadangan
  void _applyCompassFilter(double rawHeading) {
    _filteredCompassHeading = _circularEma(_filteredCompassHeading, rawHeading, 0.15);
  }

  /// EMA sirkular umum dengan faktor alpha (0-1). Mencegah artefak 360°/0°.
  static double _circularEma(double current, double target, double alpha) {
    final currentRad = current * math.pi / 180.0;
    final targetRad = target * math.pi / 180.0;

    final curX = math.cos(currentRad);
    final curY = math.sin(currentRad);
    final tgtX = math.cos(targetRad);
    final tgtY = math.sin(targetRad);

    final avgX = (1.0 - alpha) * curX + alpha * tgtX;
    final avgY = (1.0 - alpha) * curY + alpha * tgtY;

    final filteredRad = math.atan2(avgY, avgX);
    return ARProjector.normalizeAngleDeg(filteredRad * 180.0 / math.pi);
  }

  /// Memproses data accelerometer untuk menghitung kemiringan (tilt),
  /// heading kamera 3D, dan mendeteksi langkah kaki (*step detection*).
  void _processAccelerometer(AccelerometerEvent event) {
    final now = DateTime.now();

    // Low-pass filter accelerometer (EMA alpha = 0.25)
    const double alphaA = 0.25;
    if (!_hasAccel) {
      _accelX = event.x;
      _accelY = event.y;
      _accelZ = event.z;
      _hasAccel = true;
    } else {
      _accelX = _accelX * (1.0 - alphaA) + event.x * alphaA;
      _accelY = _accelY * (1.0 - alphaA) + event.y * alphaA;
      _accelZ = _accelZ * (1.0 - alphaA) + event.z * alphaA;
    }

    // 1. Hitung Tilt (kemiringan vertikal HP: 0° datar, 90° tegak)
    final rawPitch = calculateTiltDeg(event.x, event.y, event.z);

    final dtMs = now.difference(_lastPitchTime).inMilliseconds;
    if (dtMs >= 40) {
      _pitchVelocity = (rawPitch - _lastRawPitch).abs() / (dtMs / 1000.0);
      _lastRawPitch = rawPitch;
      _lastPitchTime = now;
    }

    // Filter pitch halus
    _devicePitchDeg = _devicePitchDeg * 0.85 + rawPitch * 0.15;

    // 2. Step Detection untuk Dead Reckoning
    final rawMag = math.sqrt(
      event.x * event.x + event.y * event.y + event.z * event.z,
    );

    _filteredAccelMag = _filteredAccelMag * 0.65 + rawMag * 0.35;
    final mag = _filteredAccelMag;

    _recentAccelSamples.removeWhere((s) => now.difference(s.time).inMilliseconds > 2000);
    _recentAccelSamples.add(_AccelSample(now, mag));

    // BYPASS / NONAKTIFKAN PITCH GUARD & GYRO GUARD SEMENTARA
    // Biarkan SEMUA ayunan terhitung sebagai langkah
    const bool isRotatingFast = false;
    const bool isBeingLifted = false;
    const bool isPitchValid = true;

    // Deteksi Puncak (Peak) & Lembah (Valley) manual Accelerometer (Pedometer dinonaktifkan)
    if (!_accelPeakArmed) {
      if (mag > 10.3 && _prevAccelMagnitude <= 10.3) {
        if (isRotatingFast) {
          _rejectedGyroCount++;
          _rejectedStepCount++;
          _lastRejectReason = 'gyro guard (${_gyroMagnitude.toStringAsFixed(1)} rad/s)';
        } else if (isBeingLifted || !isPitchValid) {
          _rejectedPitchCount++;
          _rejectedStepCount++;
          _lastRejectReason = isBeingLifted
              ? 'pitch guard (${_pitchVelocity.toStringAsFixed(0)}°/s)'
              : 'pitch guard (sudut ${_devicePitchDeg.toStringAsFixed(0)}°)';
        } else {
          _accelPeakArmed = true;
          _peakArmTime = now;
          _peakMagnitude = mag;
        }
      }
    } else {
      if (mag > _peakMagnitude) {
        _peakMagnitude = mag;
      }

      final timeSinceArm = now.difference(_peakArmTime).inMilliseconds;

      if (isRotatingFast) {
        _accelPeakArmed = false;
        _rejectedGyroCount++;
        _rejectedStepCount++;
        _lastRejectReason = 'gyro guard (${_gyroMagnitude.toStringAsFixed(1)} rad/s)';
      } else if (isBeingLifted || !isPitchValid) {
        _accelPeakArmed = false;
        _rejectedPitchCount++;
        _rejectedStepCount++;
        _lastRejectReason = isBeingLifted
            ? 'pitch guard (${_pitchVelocity.toStringAsFixed(0)}°/s)'
            : 'pitch guard (sudut ${_devicePitchDeg.toStringAsFixed(0)}°)';
      } else if (timeSinceArm > 600) {
        _accelPeakArmed = false;
        _rejectedAmplitudeCount++;
        _rejectedStepCount++;
        _lastRejectReason = 'amplitudo kecil (timeout)';
      } else {
        final currentAmplitude = _peakMagnitude - mag;

        // Ambang amplitudo dinaikkan ke 0.8 (mengurangi ghost steps dari getaran tangan)
        if (currentAmplitude >= 0.8 && (mag <= 9.9 || mag > _prevAccelMagnitude)) {
          final timeSinceLastStep = now.difference(_lastStepTime).inMilliseconds;
          // Debounce time dinaikkan ke 450 ms agar langkah palsu tidak terhitung
          if (timeSinceLastStep < 450) {
            _accelPeakArmed = false;
            _rejectedIntervalCount++;
            _rejectedStepCount++;
            _lastRejectReason = 'interval ($timeSinceLastStep ms < 450 ms)';
          } else {
            _accelPeakArmed = false;
            _lastStepTime = now;
            _onStepDetected(fromPedometer: false);
          }
        } else if (mag > _prevAccelMagnitude && currentAmplitude < 0.8 && timeSinceArm >= 120) {
          _accelPeakArmed = false;
          _rejectedAmplitudeCount++;
          _rejectedStepCount++;
          _lastRejectReason = 'amplitudo kecil (${currentAmplitude.toStringAsFixed(2)} < 0.8)';
        }
      }
    }

    _prevAccelMagnitude = mag;
    _requestThrottleRepaint();
  }

  /// Method debug untuk mensimulasikan +1 langkah kaki secara manual (kDebugMode).
  void debugSimulateStep() {
    _onStepDetected(fromPedometer: _isPedometerActive);
    if (_isPedometerActive) {
      _pedometerStepCount++;
    }
  }

  /// Dipanggil saat satu langkah kaki terdeteksi.
  void _onStepDetected({bool fromPedometer = false}) {
    _stepCount++;
    _lastStepEventTime = DateTime.now();
    if (!fromPedometer) {
      _accelStepCount++;
    }

    if (_isSimulationMode) return;

    if (!controller.isNavigating) {
      notifyListeners();
      return;
    }

    controller.recordStep();

    final currentPos = controller.currentUserPosition;
    final layout = controller.layout;
    if (currentPos == null || layout == null) return;

    // Gunakan kompas murni terlepas dari status navigasi (Free-roam)
    final stepAngleRad = effectiveMapHeading * math.pi / 180.0;
    final dx = _stepLengthMeters * math.cos(stepAngleRad);
    final dy = _stepLengthMeters * math.sin(stepAngleRad);

    final newRawPos = Offset(currentPos.x + dx, currentPos.y + dy);
    controller.setManualPosition(newRawPos, headingDeg: effectiveMapHeading);
    notifyListeners();
  }

  /// Mengatur mode antara Simulasi atau Dead Reckoning.
  void setSimulationMode(bool enabled) {
    if (_isSimulationMode == enabled) return;
    _isSimulationMode = enabled;
    notifyListeners();
  }

  /// Mengatur panjang langkah per langkah kaki (meter). Rentang 0.6 - 0.7 m default.
  void setStepLength(double lengthMeters) {
    _stepLengthMeters = lengthMeters.clamp(0.5, 0.85);
    notifyListeners();
  }

  /// Kalibrasi posisi awal dan orientasi melalui data QR Code.
  bool calibrateWithQR({
    required String nodeId,
    double? headingOnMap,
  }) {
    final success = controller.calibrateWithNodeId(nodeId, heading: headingOnMap);
    if (!success) {
      return false;
    }

    if (headingOnMap != null) {
      // Kalibrasi: offset = bearing target di denah - heading sensor saat ini.
      double offset = (headingOnMap - preferredHeading) % 360.0;
      if (offset < 0) offset += 360.0;
      _mapHeadingOffsetDeg = offset;
    }

    _stepCount = 0;
    notifyListeners();
    return true;
  }

  /// Menandai status terkalibrasi secara manual.
  void setCalibrated(bool val) {
    _isCalibrated = val;
    notifyListeners();
  }

  /// Mereset kalibrasi ke kondisi belum terkalibrasi.
  void resetCalibration() {
    _isCalibrated = false;
    _mapHeadingOffsetDeg = 0.0;
    _stepCount = 0;
    _pedometerStepCount = 0;
    _accelStepCount = 0;
    _lastStepEventTime = null;
    _lastPedometerRawSteps = null;
    _rejectedStepCount = 0;
    _rejectedGyroCount = 0;
    _rejectedPitchCount = 0;
    _rejectedIntervalCount = 0;
    _rejectedAmplitudeCount = 0;
    _lastRejectReason = '';
    notifyListeners();
  }

  /// Melakukan kalibrasi arah hadap kompas dengan mengarahkan HP lurus ke arah [referencePoint]
  /// dari [startPoint] pada koordinat denah (dalam meter).
  void calibrateHeadingWithReference({
    required Offset startPoint,
    required Offset referencePoint,
    double? compassHeadingOverride,
  }) {
    final targetBearing = ARProjector.calculateBearingDeg(startPoint, referencePoint);
    final compassHeading = compassHeadingOverride ?? preferredHeading;
    double offset = (targetBearing - compassHeading) % 360.0;
    _mapHeadingOffsetDeg = (offset + 360.0) % 360.0;
    _isCalibrated = true;
    notifyListeners();
  }

  /// Mengatur offset heading denah secara manual via slider.
  void setManualHeadingOffset(double offsetDeg) {
    _mapHeadingOffsetDeg = ARProjector.normalizeAngleDeg(offsetDeg);
    _isCalibrated = true;
    notifyListeners();
  }

  /// Membalik arah orientasi sebesar 180° (jika panah terbalik / mirror).
  void flipHeading180() {
    _mapHeadingOffsetDeg = ARProjector.normalizeAngleDeg(_mapHeadingOffsetDeg + 180.0);
    _isCalibrated = true;
    notifyListeners();
  }

  /// Throttling notifikasi repaint ke ~30 FPS (setiap 33 ms).
  void _requestThrottleRepaint() {
    _hasPendingRepaint = true;
    if (_throttleTimer == null || !_throttleTimer!.isActive) {
      _throttleTimer = Timer(const Duration(milliseconds: 33), () {
        if (_hasPendingRepaint) {
          _hasPendingRepaint = false;
          notifyListeners();
        }
      });
    }
  }

  @override
  void dispose() {
    _throttleTimer?.cancel();
    _compassSubscription?.cancel();
    _gyroSubscription?.cancel();
    _magSubscription?.cancel();
    _accelSubscription?.cancel();
    _pedometerSubscription?.cancel();
    super.dispose();
  }
}

class _AccelSample {
  final DateTime time;
  final double mag;
  const _AccelSample(this.time, this.mag);
}
