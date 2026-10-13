import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:sensors_plus/sensors_plus.dart';
import '../models/parking_models.dart';
import 'ar_projector.dart';
import 'graph_snap.dart';
import 'navigation_controller.dart';

/// Service untuk memproses input sensor perangkat (kompas, accelerometer),
/// estimasi langkah kaki (*dead reckoning*), dan kalibrasi heading denah.
class ARSensorService extends ChangeNotifier {
  final NavigationController controller;

  // Sensor Subscriptions
  StreamSubscription<CompassEvent>? _compassSubscription;
  StreamSubscription<AccelerometerEvent>? _accelSubscription;

  // Nilai Sensor Terkini
  double _rawCompassHeading = 0.0;
  double _filteredCompassHeading = 0.0;
  double _devicePitchDeg = 20.0; // Default kemiringan HP menunduk 20°
  bool _hasCompass = false;

  // Kalibrasi Denah
  double _mapHeadingOffsetDeg = 0.0; // Offset kompas vs sumbu +X denah

  // Pedometer / Dead Reckoning
  bool _isSimulationMode = true; // Default simulasi agar mudah diuji tanpa berjalan
  double _stepLengthMeters = 0.7; // Panjang langkah default 0.7 meter
  int _stepCount = 0;
  DateTime _lastStepTime = DateTime.fromMillisecondsSinceEpoch(0);
  double _prevAccelMagnitude = 9.8;
  bool _accelPeakArmed = false;

  // Throttle Repaint (~30 FPS / 33 ms)
  Timer? _throttleTimer;
  bool _hasPendingRepaint = false;

  ARSensorService({
    required this.controller,
    bool isSimulationMode = true,
  }) : _isSimulationMode = isSimulationMode {
    _initSensors();
  }

  // Getters
  double get filteredCompassHeading => _filteredCompassHeading;
  double get devicePitchDeg => _devicePitchDeg;
  double get mapHeadingOffsetDeg => _mapHeadingOffsetDeg;
  bool get hasCompass => _hasCompass;
  bool get isSimulationMode => _isSimulationMode;
  double get stepLengthMeters => _stepLengthMeters;
  int get stepCount => _stepCount;

  /// Arah hadap efektif pengguna terhadap sumbu koordinat denah (dalam derajat 0 - 360°).
  double get effectiveMapHeading {
    if (_isSimulationMode && !_hasCompass) {
      // Jika dalam mode simulasi dan sensor kompas belum/tidak tersedia,
      // gunakan heading arah gerak dari simulasi controller.
      return controller.currentUserHeading ?? 0.0;
    }
    return ARProjector.compassToMapHeading(
      _filteredCompassHeading,
      _mapHeadingOffsetDeg,
    );
  }

  /// Memulai pendengaran sensor fisik HP.
  void _initSensors() {
    try {
      // 1. Kompas (Heading)
      _compassSubscription = FlutterCompass.events?.listen(
        (event) {
          final heading = event.heading;
          if (heading != null) {
            _hasCompass = true;
            _rawCompassHeading = ARProjector.normalizeAngleDeg(heading);
            _applyCompassFilter(_rawCompassHeading);
            _requestThrottleRepaint();
          }
        },
        onError: (_) {
          _hasCompass = false;
        },
      );
    } catch (_) {
      _hasCompass = false;
    }

    try {
      // 2. Accelerometer (Pitch & Step Detection)
      _accelSubscription = accelerometerEventStream().listen(
        (event) {
          _processAccelerometer(event);
        },
        onError: (_) {},
      );
    } catch (_) {}
  }

  /// Low-pass filter (Exponential Moving Average) untuk kompas menggunakan komponen trigonometri
  /// guna mencegah artefak lonjakan saat sudut melintasi 360° / 0°.
  void _applyCompassFilter(double rawHeading) {
    const alpha = 0.15; // Bobot filter responsif namun stabil
    final currentRad = _filteredCompassHeading * math.pi / 180.0;
    final targetRad = rawHeading * math.pi / 180.0;

    final curX = math.cos(currentRad);
    final curY = math.sin(currentRad);
    final tgtX = math.cos(targetRad);
    final tgtY = math.sin(targetRad);

    final avgX = (1.0 - alpha) * curX + alpha * tgtX;
    final avgY = (1.0 - alpha) * curY + alpha * tgtY;

    final filteredRad = math.atan2(avgY, avgX);
    _filteredCompassHeading = ARProjector.normalizeAngleDeg(
      filteredRad * 180.0 / math.pi,
    );
  }

  /// Memproses data accelerometer untuk menghitung sudut kemiringan (pitch)
  /// dan mendeteksi langkah kaki pengguna (*step detection*).
  void _processAccelerometer(AccelerometerEvent event) {
    // 1. Hitung Pitch (kemiringan vertikal HP saat digenggam)
    // Sumbu Z dan bidang XY
    final xyMag = math.sqrt(event.x * event.x + event.y * event.y);
    if (xyMag > 0.01) {
      final pitchRad = math.atan2(event.z, xyMag);
      final rawPitch = pitchRad * 180.0 / math.pi;
      // Batasi pitch pada rentang wajar pengguna memegang HP melihat jalan: 0° sampai 65°
      final clampedPitch = rawPitch.clamp(0.0, 65.0);
      // Filter pitch halus
      _devicePitchDeg = _devicePitchDeg * 0.85 + clampedPitch * 0.15;
    }

    // 2. Step Detection untuk Dead Reckoning (hanya aktif jika bukan mode simulasi)
    final mag = math.sqrt(
      event.x * event.x + event.y * event.y + event.z * event.z,
    );

    final now = DateTime.now();
    final timeSinceLastStep = now.difference(_lastStepTime).inMilliseconds;

    // Deteksi lonjakan percepatan saat tumit mendarat (peak threshold > 11.8 m/s^2)
    // dan lembah pemulihan (< 9.0 m/s^2) dengan batas minimal 320 ms per langkah (~maks 3 langkah/detik)
    if (!_accelPeakArmed && mag > 11.8 && _prevAccelMagnitude <= 11.8) {
      _accelPeakArmed = true;
    } else if (_accelPeakArmed && mag < 9.5 && timeSinceLastStep > 320) {
      _accelPeakArmed = false;
      _lastStepTime = now;
      _onStepDetected();
    }

    _prevAccelMagnitude = mag;
    _requestThrottleRepaint();
  }

  /// Dipanggil saat satu langkah kaki terdeteksi.
  void _onStepDetected() {
    _stepCount++;

    // Jika dalam mode simulasi, biarkan SimulatedPositionProvider yang menggerakkan posisi
    if (_isSimulationMode) return;

    final currentPos = controller.currentUserPosition;
    final layout = controller.layout;
    if (currentPos == null || layout == null) return;

    // Geser posisi ke arah hadap pengguna pada denah
    final headingRad = effectiveMapHeading * math.pi / 180.0;
    final dx = _stepLengthMeters * math.cos(headingRad);
    final dy = _stepLengthMeters * math.sin(headingRad);

    final newRawPos = Offset(currentPos.x + dx, currentPos.y + dy);

    // Snap posisi baru ke graf jalan denah agar tidak keluar lintasan
    final snap = snapToGraph(newRawPos, layout.nodes, layout.edges);
    final targetPos = (snap != null && !snap.isOffGraph)
        ? snap.snappedPosition
        : newRawPos;

    // Perbarui posisi pengguna di NavigationController
    controller.setManualPosition(targetPos);
    notifyListeners();
  }

  /// Mengatur mode antara Simulasi (posisi otomatis dari controller)
  /// atau Dead Reckoning (langkah kaki via accelerometer + kompas).
  void setSimulationMode(bool enabled) {
    if (_isSimulationMode == enabled) return;
    _isSimulationMode = enabled;
    notifyListeners();
  }

  /// Mengatur panjang langkah per langkah kaki (meter).
  void setStepLength(double lengthMeters) {
    _stepLengthMeters = lengthMeters.clamp(0.4, 1.2);
    notifyListeners();
  }

  /// Kalibrasi posisi awal dan orientasi melalui data QR Code.
  ///
  /// Menerima [nodeId] (misal 'c_l1' atau 'Lobby 1') dan opsional [headingOnMap]
  /// (arah hadap yang tercantum di stiker QR denah, dalam derajat 0 - 360°).
  bool calibrateWithQR({
    required String nodeId,
    double? headingOnMap,
  }) {
    final layout = controller.layout;
    if (layout == null) return false;

    // Cari node yang cocok atau lobby dengan ID tersebut
    Node? targetNode = layout.nodes.cast<Node?>().firstWhere(
          (n) => n?.id.toLowerCase() == nodeId.toLowerCase(),
          orElse: () => null,
        );

    if (targetNode == null) {
      final lobby = layout.lobbies.cast<Lobby?>().firstWhere(
            (l) =>
                l?.id.toLowerCase() == nodeId.toLowerCase() ||
                l?.name.toLowerCase() == nodeId.toLowerCase(),
            orElse: () => null,
          );
      if (lobby != null) {
        targetNode = layout.nodes.cast<Node?>().firstWhere(
              (n) => n?.id == lobby.entryNodeId,
              orElse: () => null,
            );
      }
    }

    if (targetNode == null) {
      return false;
    }

    // Set posisi pengguna ke node hasil scan
    controller.setManualPosition(Offset(targetNode.x, targetNode.y));

    // Kalibrasi offset kompas jika arah hadap stiker QR diketahui
    if (headingOnMap != null) {
      _mapHeadingOffsetDeg = ARProjector.normalizeAngleDeg(
        _filteredCompassHeading - headingOnMap,
      );
    }

    _stepCount = 0;
    notifyListeners();
    return true;
  }

  /// Mengatur offset heading denah secara manual via slider.
  void setManualHeadingOffset(double offsetDeg) {
    _mapHeadingOffsetDeg = ARProjector.normalizeAngleDeg(offsetDeg);
    notifyListeners();
  }

  /// Throttling notifikasi repaint ke ~30 FPS (setiap 33 ms)
  /// agar CustomPainter beranimasi dengan halus tanpa membebani GPU/CPU.
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
    _accelSubscription?.cancel();
    super.dispose();
  }
}
