import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

/// Model representasi posisi pengguna di dalam ruangan.
class UserPosition {
  /// Posisi dalam satuan meter pada denah (y positif ke bawah).
  final Offset position;

  /// Arah hadap / orientasi pengguna dalam derajat (0 - 360°, opsional).
  final double? headingDeg;

  /// Waktu posisi dicatat / dipancarkan.
  final DateTime timestamp;

  const UserPosition({
    required this.position,
    this.headingDeg,
    required this.timestamp,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UserPosition &&
          runtimeType == other.runtimeType &&
          position == other.position &&
          headingDeg == other.headingDeg &&
          timestamp == other.timestamp;

  @override
  int get hashCode => Object.hash(position, headingDeg, timestamp);

  @override
  String toString() =>
      'UserPosition(x: ${position.dx.toStringAsFixed(2)}, y: ${position.dy.toStringAsFixed(2)}, heading: ${headingDeg?.toStringAsFixed(1)}°)';
}

/// Kontrak provider posisi pengguna.
///
/// Dibuat independen tanpa ketergantungan pada UI maupun [NavigationController]
/// agar dapat diganti dengan implementasi perangkat nyata (seperti Immersal / VPS / BLE)
/// di masa mendatang tanpa mengubah logika controller.
abstract class PositionProvider {
  /// Stream pemancar posisi pengguna secara realtime.
  Stream<UserPosition> get positions;

  /// Memulai pemancaran posisi.
  void start();

  /// Menghentikan pemancaran posisi sementara.
  void stop();

  /// Membersihkan sumber daya dan menutup stream.
  void dispose();

  /// Notifikasi ketika rute navigasi baru ditetapkan.
  /// Implementasi default tidak melakukan apa-apa (provider sensor nyata akan mengabaikannya).
  void onRouteChanged(List<Offset> route) {}
}

/// Implementasi tiruan yang menyimulasikan pergerakan pengguna di sepanjang rute.
class SimulatedPositionProvider implements PositionProvider {
  final StreamController<UserPosition> _controller =
      StreamController<UserPosition>.broadcast();

  Timer? _timer;
  double _speed; // meter per detik (default 1.5 m/s)
  bool _isRunning = false;
  bool _isPaused = false;

  List<Offset> _remainingWaypoints = [];
  Offset? _currentPosition;
  double? _currentHeadingDeg;
  DateTime? _lastTickTime;

  SimulatedPositionProvider({
    double initialSpeed = 1.5,
    Offset? initialPosition,
  })  : _speed = initialSpeed,
        _currentPosition = initialPosition;

  @override
  Stream<UserPosition> get positions => _controller.stream;

  double get speed => _speed;
  bool get isRunning => _isRunning;
  bool get isPaused => _isPaused;
  Offset? get currentPosition => _currentPosition;

  /// Mengatur kecepatan simulasi gerak (m/s).
  void setSpeed(double speed) {
    _speed = speed > 0 ? speed : 0.5;
  }

  /// Menjeda simulasi.
  void pause() {
    _isPaused = true;
  }

  /// Melanjutkan simulasi setelah dijeda.
  void resume() {
    if (_isRunning) {
      _isPaused = false;
      _lastTickTime = DateTime.now();
    }
  }

  @override
  void start() {
    if (_isRunning) return;
    _isRunning = true;
    _isPaused = false;
    _lastTickTime = DateTime.now();

    // Pancarkan posisi awal jika sudah ada
    if (_currentPosition != null) {
      _controller.add(UserPosition(
        position: _currentPosition!,
        headingDeg: _currentHeadingDeg,
        timestamp: DateTime.now(),
      ));
    }

    _timer?.cancel();
    // Frekuensi tick ~10 kali per detik (setiap 100 milidetik)
    _timer = Timer.periodic(const Duration(milliseconds: 100), _onTick);
  }

  @override
  void stop() {
    _isRunning = false;
    _isPaused = false;
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    stop();
    _controller.close();
  }

  @override
  void onRouteChanged(List<Offset> route) {
    if (route.isEmpty) {
      _remainingWaypoints = [];
      return;
    }

    if (_currentPosition == null) {
      // Belum ada posisi sebelumnya: mulai dari titik awal rute
      _currentPosition = route.first;
      _remainingWaypoints = List<Offset>.from(route.sublist(1));
      if (_isRunning) {
        _controller.add(UserPosition(
          position: _currentPosition!,
          headingDeg: _currentHeadingDeg,
          timestamp: DateTime.now(),
        ));
      }
    } else {
      // Posisi pengguna saat ini sudah ada:
      // Pertahankan posisi pengguna dan JANGAN melompat ke awal rute.
      // Waypoint baru adalah daftar rute setelah posisi saat ini.
      final newWaypoints = List<Offset>.from(route);
      if (newWaypoints.isNotEmpty) {
        final distToStart = (newWaypoints.first - _currentPosition!).distance;
        // Jika titik pertama rute hampir sama dengan posisi saat ini (< 0.2m),
        // lewati titik pertama agar tidak bolak-balik di tempat
        if (distToStart < 0.2) {
          newWaypoints.removeAt(0);
        }
      }
      _remainingWaypoints = newWaypoints;
    }
  }

  void _onTick(Timer timer) {
    if (!_isRunning || _isPaused || _remainingWaypoints.isEmpty) return;

    final now = DateTime.now();
    final dt = _lastTickTime != null
        ? (now.difference(_lastTickTime!).inMicroseconds / 1000000.0)
        : 0.1;
    _lastTickTime = now;

    if (dt <= 0 || dt > 1.0) {
      return;
    }

    double distanceToMove = _speed * dt;
    Offset current = _currentPosition ?? _remainingWaypoints.removeAt(0);

    while (distanceToMove > 0 && _remainingWaypoints.isNotEmpty) {
      final nextTarget = _remainingWaypoints.first;
      final dist = (nextTarget - current).distance;

      if (dist <= 0.001) {
        _remainingWaypoints.removeAt(0);
        continue;
      }

      if (distanceToMove >= dist) {
        // Berhasil melewati segmen ini menuju target
        distanceToMove -= dist;
        current = nextTarget;
        _remainingWaypoints.removeAt(0);
      } else {
        // Melangkah sebagian sepanjang segmen saat ini
        final ratio = distanceToMove / dist;
        final dx = nextTarget.dx - current.dx;
        final dy = nextTarget.dy - current.dy;
        current = Offset(current.dx + dx * ratio, current.dy + dy * ratio);

        // Hitung sudut heading arah gerak
        final rad = math.atan2(dy, dx);
        final deg = (rad * 180.0 / math.pi) % 360.0;
        _currentHeadingDeg = deg >= 0 ? deg : deg + 360.0;

        distanceToMove = 0.0;
      }
    }

    _currentPosition = current;
    _controller.add(UserPosition(
      position: current,
      headingDeg: _currentHeadingDeg,
      timestamp: now,
    ));
  }
}

/// Implementasi provider manual untuk memindahkan posisi pengguna melalui ketukan/drag pada denah.
class ManualPositionProvider implements PositionProvider {
  final StreamController<UserPosition> _controller =
      StreamController<UserPosition>.broadcast();

  UserPosition? _lastPosition;
  bool _isRunning = false;

  ManualPositionProvider({Offset? initialPosition}) {
    if (initialPosition != null) {
      _lastPosition = UserPosition(
        position: initialPosition,
        timestamp: DateTime.now(),
      );
    }
  }

  @override
  Stream<UserPosition> get positions => _controller.stream;

  UserPosition? get currentPosition => _lastPosition;

  /// Memperbarui posisi pengguna secara manual.
  void setPosition(Offset position, {double? headingDeg}) {
    _lastPosition = UserPosition(
      position: position,
      headingDeg: headingDeg,
      timestamp: DateTime.now(),
    );
    if (_isRunning) {
      _controller.add(_lastPosition!);
    }
  }

  @override
  void start() {
    _isRunning = true;
    if (_lastPosition != null) {
      _controller.add(_lastPosition!);
    }
  }

  @override
  void stop() {
    _isRunning = false;
  }

  @override
  void dispose() {
    stop();
    _controller.close();
  }

  @override
  void onRouteChanged(List<Offset> route) {
    // Mode manual tidak mengubah posisi secara otomatis ketika rute berubah.
  }
}
