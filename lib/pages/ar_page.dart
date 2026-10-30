import 'dart:async';
import 'dart:math' as math;
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/map_data.dart';
import '../models/parking_models.dart';
import '../services/ar_projector.dart';
import '../services/ar_sensor_service.dart';
import '../services/navigation_controller.dart';
import '../widgets/ar_manual_calibration_sheet.dart';
import '../widgets/ar_overlay_painter.dart';
import '../widgets/destination_picker_sheet.dart';
import '../widgets/map_painter.dart';

/// Halaman Navigasi Augmented Reality (AR) Indoor Fullscreen murni menggunakan Flutter/Dart.
class ArPage extends StatefulWidget {
  final NavigationController controller;

  const ArPage({super.key, required this.controller});

  @override
  State<ArPage> createState() => _ArPageState();
}

class _ArPageState extends State<ArPage> with SingleTickerProviderStateMixin {
  CameraController? _cameraController;
  late final ARSensorService _sensorService;
  late final AnimationController _pulseAnimationController;

  bool _isCameraInitialized = false;
  bool _isPermissionDenied = false;
  String? _cameraErrorMessage;

  // Mini-Map Interaktif
  final TransformationController _mapTransformController = TransformationController();
  bool _isMiniMapExpanded = false;
  bool _miniMapAutoFollow = true;

  // Sudut relatif penuntun utama yang telah dihaluskan (low-pass filter)
  double _smoothedRelativeAngleDeg = 0.0;
  bool _isDebugExpanded = false;

  // State Kalibrasi Manual AR (Tanpa QR)
  bool _showCalibrationWizard = false;
  int _calibrationStep = 0; // 0 = pilih posisi awal, 1 = kalibrasi arah
  MapNode? _calibrationStartNode;
  MapNode? _calibrationRefNode;
  bool _isCalibratingHeading = false;
  bool _isCalibrationSuccess = false;
  double _calibrationOffsetCorrection = 0.0; // Koreksi manual ±180° setelah kalibrasi
  double _baseCalibrationOffset = 0.0;        // Offset murni dari sensor, sebelum koreksi slider

  // Debounce Peringatan "Putar Balik" (2.5 detik) untuk menangkal interferensi magnetik
  DateTime? _uTurnStartTime;
  Map<String, dynamic>? _lastNonUTurnInstruction;

  @override
  void initState() {
    super.initState();
    _sensorService = ARSensorService(controller: widget.controller);

    _pulseAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();

    _initCamera();

    // Minta izin runtime aktivitas fisik (pedometer) saat masuk ArPage
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkAndRequestActivityRecognition();
    });

    // Reset posisi lama saat masuk ArPage bila belum dikalibrasi
    if (!_sensorService.isCalibrated) {
      widget.controller.resetUserPositionAndStartNode();
      _showCalibrationWizard = true;
      _calibrationStep = 0;
      // Coba pulihkan posisi terakhir dari SharedPreferences
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _tryRestoreLastPosition();
      });
    }
  }

  @override
  void dispose() {
    _mapTransformController.dispose();
    _pulseAnimationController.dispose();
    _sensorService.dispose();
    _cameraController?.dispose();
    super.dispose();
  }

  Future<void> _initCamera() async {
    try {
      final status = await Permission.camera.request();
      if (!status.isGranted) {
        if (mounted) {
          setState(() {
            _isPermissionDenied = true;
          });
        }
        return;
      }

      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        if (mounted) {
          setState(() {
            _cameraErrorMessage = 'Tidak ada perangkat kamera yang terdeteksi.';
          });
        }
        return;
      }

      final backCamera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      final controller = CameraController(
        backCamera,
        ResolutionPreset.high,
        enableAudio: false,
      );

      await controller.initialize();

      if (mounted) {
        setState(() {
          _cameraController = controller;
          _isCameraInitialized = true;
          _isPermissionDenied = false;
          _cameraErrorMessage = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _cameraErrorMessage = 'Gagal menginisialisasi kamera: $e';
        });
      }
    }
  }

  /// Meminta izin runtime ACTIVITY_RECOGNITION dengan dialog edukatif singkat.
  Future<void> _checkAndRequestActivityRecognition() async {
    try {
      final status = await Permission.activityRecognition.status;
      if (status.isGranted) {
        _sensorService.initPedometer();
        return;
      }

      if (!mounted) return;

      // Tampilkan dialog singkat menjelaskan alasan kebutuhan sensor langkah
      final bool? proceed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1E222D),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(
            children: [
              Icon(Icons.directions_walk, color: Color(0xFF00E5FF)),
              SizedBox(width: 8),
              Text(
                'Izin Deteksi Langkah',
                style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          content: const Text(
            'Aplikasi membutuhkan izin Aktivitas Fisik (Pedometer) agar deteksi langkah kaki tetap andal saat HP dipegang tegak selama navigasi AR.',
            style: TextStyle(color: Color(0xFFB0B7C3), fontSize: 13, height: 1.4),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Tolak', style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00E5FF),
                foregroundColor: Colors.black,
              ),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Izinkan', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      );

      if (proceed == true) {
        final reqStatus = await Permission.activityRecognition.request();
        if (reqStatus.isGranted) {
          _sensorService.initPedometer();
        } else {
          _handleActivityRecognitionDenied();
        }
      } else {
        _handleActivityRecognitionDenied();
      }
    } catch (_) {
      _handleActivityRecognitionDenied();
    }
  }

  /// Penanganan saat izin aktivitas fisik ditolak: fallback ke accelerometer.
  void _handleActivityRecognitionDenied() {
    _sensorService.fallbackToAccelerometer();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Izin langkah ditolak. Menggunakan Mode langkah cadangan (Accelerometer).'),
          backgroundColor: Color(0xFF2C3240),
          duration: Duration(seconds: 3),
        ),
      );
    }
  }

  /// Menyimpan posisi terakhir ke SharedPreferences lalu menghentikan navigasi.
  /// [completeArrival] = true  → simpan koordinat TUJUAN (user menekan "Saya sudah sampai").
  /// [completeArrival] = false → simpan koordinat USER terdekat saat ini (Hentikan di tengah jalan).
  Future<void> _saveAndStop({bool completeArrival = false}) async {
    await widget.controller.saveLastPosition(
      headingOffsetDeg: _sensorService.mapHeadingOffsetDeg,
      useDestination: completeArrival, // true → simpan node tujuan, false → simpan posisi user
    );
    if (completeArrival) {
      widget.controller.completeArrival();
    } else {
      widget.controller.stopNavigation();
    }
  }

  /// Memulihkan posisi navigasi terakhir jika dikonfirmasi pengguna.
  /// Menampilkan konfirmasi terlebih dahulu agar tidak memaksakan posisi lama bila pengguna berpindah tempat.
  Future<void> _tryRestoreLastPosition() async {
    final saved = await widget.controller.loadLastPosition();
    if (saved == null || !mounted) return;

    final nodeId = saved['nodeId'] as String;
    final double savedOffset = (saved['headingOffset'] as double?) ?? 0.0;

    // Cari node di floor saat ini berdasarkan ID yang disimpan
    final floor = widget.controller.currentFloor;
    MapNode? restoredNode;
    if (floor != null) {
      try {
        restoredNode = floor.nodes.firstWhere((n) => n.id == nodeId);
      } catch (_) {
        restoredNode = null;
      }
    }

    // Jika node tidak ditemukan, fallback: buat node virtual dari koordinat yang disimpan
    if (restoredNode == null) {
      final x = saved['x'] as double;
      final y = saved['y'] as double;
      restoredNode = MapNode(
        id: nodeId,
        name: nodeId,
        type: NodeType.junction,
        x: x,
        y: y,
      );
    }

    // 1 & 2. Tampilkan dialog konfirmasi ke pengguna sebelum mengubah posisi
    final bool? confirmRestore = await _showRestoreConfirmationDialog(restoredNode);

    if (!mounted) return;

    if (confirmRestore == true) {
      // 3. Tombol "Ya": Jalankan logika restore posisi (set start node/posisi dan bypass kalibrasi)
      widget.controller.setStartNode(restoredNode);
      _sensorService.setManualHeadingOffset(savedOffset);

      setState(() {
        _showCalibrationWizard = false;
        _calibrationStartNode = restoredNode;
        _isCalibrationSuccess = true;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Posisi terakhir dipulihkan: ${restoredNode.name}'),
          backgroundColor: const Color(0xFF00E5FF),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
        ),
      );
    } else {
      // 4. Tombol "Tidak (Pilih Ulang)": Hapus data tersimpan dan buka pemilihan awal baru
      await widget.controller.clearSavedPosition();
      _showInitialCalibrationDialog();
    }
  }

  /// Menampilkan dialog konfirmasi posisi terakhir.
  Future<bool?> _showRestoreConfirmationDialog(MapNode node) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E222D),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.history_toggle_off, color: Color(0xFF00E5FF)),
            SizedBox(width: 10),
            Text(
              'Konfirmasi Posisi',
              style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        content: Text(
          'Apakah Anda masih berada di ${node.name}?',
          style: const TextStyle(color: Color(0xFFB0B7C3), fontSize: 14, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text(
              'Tidak (Pilih Ulang)',
              style: TextStyle(color: Colors.grey, fontWeight: FontWeight.w600),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00E5FF),
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Ya', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  /// Menampilkan dialog/wizard kalibrasi awal agar pengguna dapat memilih node awal baru.
  void _showInitialCalibrationDialog() {
    if (!mounted) return;
    setState(() {
      widget.controller.resetUserPositionAndStartNode();
      _showCalibrationWizard = true;
      _calibrationStep = 0;
      _calibrationStartNode = null;
      _calibrationRefNode = null;
      _isCalibrationSuccess = false;
    });
  }

  Offset? _getNextRoutePoint(Offset userPos, List<Node> route) {
    if (route.isEmpty) return null;
    if (route.length == 1) {
      return Offset(route.first.x, route.first.y);
    }
    // Langsung arahkan panah ke segmen berikutnya (route[1]) tanpa memotong jalan!
    // Ini memastikan panah selalu siku-siku mengikuti lorong dan pintu.
    return Offset(route[1].x, route[1].y);
  }

  /// Memperhalus sudut rotasi relatif menggunakan shortest-path Angular Lerp
  void _updateSmoothedAngle(Offset userRawPos, List<Node> route) {
    final nextTarget = _getNextRoutePoint(userRawPos, route);
    if (nextTarget == null) return;

    final targetBearing = ARProjector.calculateBearingDeg(userRawPos, nextTarget);
    final safeHeading = ((_sensorService.effectiveMapHeading % 360.0) + 360.0) % 360.0;
    final rawRelative = ARProjector.calculateRelativeAngleDeg(
      targetBearing,
      safeHeading,
    );

    // Terapkan Lerp sudut terpendek (shortest path) dengan faktor 0.15 per frame
    // agar panah tidak berputar instan 90° akibat kompas terganggu
    _smoothedRelativeAngleDeg = ARProjector.lerpAngleDeg(
      _smoothedRelativeAngleDeg,
      rawRelative,
      0.15,
    );
  }

  /// Menghitung jarak sepanjang rute menuju tikungan/belokan pertama berikutnya (>35°)
  double? _calculateDistanceToNextTurn(Offset userPos, List<Node> route) {
    if (route.length < 2) return null;
    final points = <Offset>[userPos, ...route.map((n) => Offset(n.x, n.y))];
    double accumulated = 0.0;

    for (int i = 1; i < points.length - 1; i++) {
      final prev = points[i - 1];
      final curr = points[i];
      final next = points[i + 1];

      accumulated += (curr - prev).distance;

      final b1 = ARProjector.calculateBearingDeg(prev, curr);
      final b2 = ARProjector.calculateBearingDeg(curr, next);
      final turnAngle = ARProjector.angleDifferenceDeg(b2, b1);

      if (turnAngle.abs() >= 35.0) {
        return accumulated;
      }
    }
    return null;
  }

  /// Menghasilkan teks instruksi belokan dari satu sumber kebenaran (sudut relatif)
  Map<String, dynamic> _getTurnInstruction(List<Node> route, Node? userPos) {
    if (!_sensorService.isCalibrated) {
      return {
        'icon': Icons.tune,
        'title': 'Kalibrasi AR Diperlukan',
        'subtitle': 'Tentukan posisi awal & kalibrasi arah hadap',
      };
    }

    final destName = widget.controller.targetDestination?.name ??
        (widget.controller.targetSlot != null ? 'Slot ${widget.controller.targetSlot!.id}' : 'Tujuan');

    if (!widget.controller.isNavigating) {
      return {
        'icon': Icons.navigation,
        'title': 'Siap Memulai Navigasi',
        'subtitle': 'Tekan Mulai Navigasi AR untuk melanjutkan ke $destName',
      };
    }

    if (route.isEmpty || userPos == null) {
      return {
        'icon': Icons.check_circle,
        'title': 'Tiba di Tujuan',
        'subtitle': 'Anda telah sampai di $destName',
      };
    }

    final userOffset = Offset(userPos.x, userPos.y);
    final nextTarget = _getNextRoutePoint(userOffset, route) ?? Offset(route.first.x, route.first.y);

    // Satu sumber kebenaran: guidance dihitung dari selisih bearing target vs heading HP
    final safeHeading = ((_sensorService.effectiveMapHeading % 360.0) + 360.0) % 360.0;
    final guidance = ARProjector.getOffScreenGuidance(
      userPos: userOffset,
      userHeadingDeg: safeHeading,
      targetPoint: nextTarget,
    );

    // 2. Debounce Peringatan "Putar Balik" (2.5 detik):
    // Tahan instruksi Putar Balik jika hanya terjadi lonjakan sesaat akibat interferensi magnetik (kulkas/kompor logam).
    bool isUTurnDebounced = false;
    if (guidance.direction == TurnDirection.uTurn) {
      _uTurnStartTime ??= DateTime.now();
      final elapsedMs = DateTime.now().difference(_uTurnStartTime!).inMilliseconds;
      if (elapsedMs >= 2500) {
        isUTurnDebounced = true;
      }
    } else {
      _uTurnStartTime = null;
    }

    // Jika guidance menyuruh Putar Balik tapi belum konsisten > 2.5 detik berturut-turut,
    // tahan dulu dan kembalikan instruksi sebelumnya atau fallback ke "Lurus".
    if (guidance.direction == TurnDirection.uTurn && !isUTurnDebounced) {
      if (_lastNonUTurnInstruction != null) {
        return _lastNonUTurnInstruction!;
      }
      return {
        'icon': Icons.straight,
        'title': 'Lurus Mengikuti Rute',
        'subtitle': 'Jarak sisa: ${widget.controller.currentRouteDistance.toStringAsFixed(1)} m menuju $destName',
        'direction': TurnDirection.straight,
      };
    }

    final distToNextTurn = _calculateDistanceToNextTurn(userOffset, route);

    IconData icon;
    switch (guidance.direction) {
      case TurnDirection.straight:
        icon = Icons.straight;
        break;
      case TurnDirection.slightRight:
        icon = Icons.turn_slight_right;
        break;
      case TurnDirection.right:
        icon = Icons.turn_right;
        break;
      case TurnDirection.slightLeft:
        icon = Icons.turn_slight_left;
        break;
      case TurnDirection.left:
        icon = Icons.turn_left;
        break;
      case TurnDirection.uTurn:
        icon = Icons.u_turn_right;
        break;
    }

    String title;
    if (guidance.direction == TurnDirection.uTurn) {
      title = 'Putar Balik';
    } else if (guidance.direction == TurnDirection.straight) {
      if (distToNextTurn != null && distToNextTurn < 4.0) {
        title = 'Lurus (Segera Ada Belokan)';
      } else {
        title = 'Lurus Mengikuti Rute';
      }
    } else {
      if (distToNextTurn != null && distToNextTurn < 3.0) {
        title = 'Segera ${guidance.label}';
      } else if (distToNextTurn != null) {
        title = 'Dalam ${distToNextTurn.toStringAsFixed(0)} m, ${guidance.label}';
      } else {
        title = guidance.label;
      }
    }

    final totalRemaining = widget.controller.currentRouteDistance;
    final subtitle = distToNextTurn != null
        ? 'Belokan dalam ${distToNextTurn.toStringAsFixed(1)} m • Sisa: ${totalRemaining.toStringAsFixed(1)} m'
        : 'Jarak sisa: ${totalRemaining.toStringAsFixed(1)} m menuju $destName';

    final result = {
      'icon': icon,
      'title': title,
      'subtitle': subtitle,
      'direction': guidance.direction,
    };

    if (guidance.direction != TurnDirection.uTurn) {
      _lastNonUTurnInstruction = result;
    }

    return result;
  }

  /// Mendapatkan daftar node tetangga non-junction dari [nodeId] di graf.
  List<MapNode> _getNeighborNodes(String nodeId) {
    final floor = widget.controller.currentFloor;
    if (floor == null) return [];

    final neighborIds = <String>{};
    for (final edge in floor.edges) {
      if (edge.from == nodeId) {
        neighborIds.add(edge.to);
      }
      if (edge.to == nodeId && (edge.bidirectional)) {
        neighborIds.add(edge.from);
      }
    }

    return floor.nodes
        .where((n) => neighborIds.contains(n.id) && n.type != NodeType.junction)
        .toList();
  }

  /// Mendapatkan node acuan default untuk kalibrasi arah.
  MapNode? _getDefaultReferenceNode(MapNode startNode) {
    final floor = widget.controller.currentFloor;
    if (floor == null) return null;

    // 1. Prioritas TERTINGGI: Tujuan navigasi yang sudah dipilih user!
    // Karena user pasti ingin berjalan menghadap ke arah tujuan, bukan ke belakang.
    final targetDest = widget.controller.targetDestination;
    if (targetDest != null && targetDest.id != startNode.id) {
      final destNode = floor.findNodeById(targetDest.id);
      if (destNode != null) return destNode;
    }

    // 2. Prioritas kedua: Titik berikutnya pada rute aktif yang berbeda dari startNode
    final route = widget.controller.currentRoute;
    if (route.isNotEmpty) {
      for (final rNode in route) {
        if (rNode.id != startNode.id) {
          final mapNode = floor.findNodeById(rNode.id);
          if (mapNode != null && mapNode.type != NodeType.junction) {
            return mapNode;
          }
        }
      }
    }

    // 3. Prioritas ketiga: Node tetangga non-junction terdekat
    final neighbors = _getNeighborNodes(startNode.id);
    if (neighbors.isNotEmpty) {
      neighbors.sort((a, b) {
        final da = math.sqrt(math.pow(a.x - startNode.x, 2) + math.pow(a.y - startNode.y, 2));
        final db = math.sqrt(math.pow(b.x - startNode.x, 2) + math.pow(b.y - startNode.y, 2));
        return da.compareTo(db);
      });
      return neighbors.first;
    }

    // 4. Fallback tetangga apapun
    final allNeighborIds = <String>{};
    for (final edge in floor.edges) {
      if (edge.from == startNode.id) allNeighborIds.add(edge.to);
      if (edge.to == startNode.id && edge.bidirectional) allNeighborIds.add(edge.from);
    }

    final allNeighbors = floor.nodes.where((n) => allNeighborIds.contains(n.id)).toList();
    if (allNeighbors.isNotEmpty) {
      allNeighbors.sort((a, b) {
        final da = math.sqrt(math.pow(a.x - startNode.x, 2) + math.pow(a.y - startNode.y, 2));
        final db = math.sqrt(math.pow(b.x - startNode.x, 2) + math.pow(b.y - startNode.y, 2));
        return da.compareTo(db);
      });
      return allNeighbors.first;
    }

    return null;
  }

  /// Proses kalibrasi arah hadap: rata-rata preferredHeading selama ~1 detik, lalu hitung offset.
  Future<void> _performHeadingCalibration() async {
    if (_calibrationStartNode == null || _calibrationRefNode == null) return;

    setState(() {
      _isCalibratingHeading = true;
      _isCalibrationSuccess = false;
    });

    final samples = <double>[];
    final completer = Completer<void>();

    int count = 0;
    Timer.periodic(const Duration(milliseconds: 100), (timer) {
      // Gunakan preferredHeading (headingForCameraMode bila tersedia)
      samples.add(_sensorService.preferredHeading);
      count++;
      if (count >= 10) {
        timer.cancel();
        completer.complete();
      }
    });

    await completer.future;

    if (!mounted) return;

    double sumCos = 0, sumSin = 0;
    for (final s in samples) {
      final rad = s * math.pi / 180.0;
      sumCos += math.cos(rad);
      sumSin += math.sin(rad);
    }
    final avgRad = math.atan2(sumSin / samples.length, sumCos / samples.length);
    final avgPreferred = ARProjector.normalizeAngleDeg(avgRad * 180.0 / math.pi);

    _sensorService.calibrateHeadingWithReference(
      startPoint: Offset(_calibrationStartNode!.x, _calibrationStartNode!.y),
      referencePoint: Offset(_calibrationRefNode!.x, _calibrationRefNode!.y),
      // Kirim rata-rata preferredHeading — sudah dipilih oleh sensor service sesuai pitch
      compassHeadingOverride: avgPreferred,
    );

    setState(() {
      _isCalibratingHeading = false;
      _isCalibrationSuccess = true;
      _calibrationOffsetCorrection = 0.0;
      _baseCalibrationOffset = _sensorService.mapHeadingOffsetDeg;
    });
    // Jangan auto-close wizard agar user bisa melihat status sukses,
    // menggunakan tombol "Balik 180°" jika arah terbalik, dan menekan "Selesai ✓".
  }

  /// Memusatkan tampilan mini-map ke posisi pengguna saat ini
  void _centerMiniMapOnUser(Size viewportSize) {
    final userPos = widget.controller.currentUserPosition;
    final layout = widget.controller.layout;
    if (userPos == null || layout == null) return;

    const mapScale = 16.0;
    final userCanvasX = userPos.x * mapScale;
    final userCanvasY = userPos.y * mapScale;

    final currentZoom = _mapTransformController.value.getMaxScaleOnAxis().clamp(0.8, 5.0);

    final tx = (viewportSize.width / 2.0) - (userCanvasX * currentZoom);
    final ty = (viewportSize.height / 2.0) - (userCanvasY * currentZoom);

    _mapTransformController.value = Matrix4.translationValues(tx, ty, 0.0)
      ..multiply(Matrix4.diagonal3Values(currentZoom, currentZoom, 1.0));
  }

  /// Melakukan zoom in (+) atau zoom out (-) pada InteractiveViewer mini-map
  void _zoomMiniMap(double factor, Size viewportSize) {
    final currentMatrix = _mapTransformController.value;
    final currentScale = currentMatrix.getMaxScaleOnAxis();
    final newScale = (currentScale * factor).clamp(0.6, 6.0);
    final scaleRatio = newScale / currentScale;

    final cx = viewportSize.width / 2.0;
    final cy = viewportSize.height / 2.0;

    final newMatrix = Matrix4.translationValues(cx, cy, 0.0)
      ..multiply(Matrix4.diagonal3Values(scaleRatio, scaleRatio, 1.0))
      ..multiply(Matrix4.translationValues(-cx, -cy, 0.0))
      ..multiply(currentMatrix);

    _mapTransformController.value = newMatrix;
    setState(() {
      _miniMapAutoFollow = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 1. Layer Dasar: Camera Preview (atau Virtual Floor jika simulasi)
          _buildCameraLayer(),

          // 2. Layer AR: Chevrons 3D, Panah Penuntun 3D Utama, Floating Pin
          _buildArOverlayLayer(),

          // 3. Layer HUD Atas: Header, Turn-by-Turn, Status Banner
          _buildTopHudLayer(),

          // 4. Layer HUD Bawah: Ringkasan Rute / Kontrol Navigasi & Mini-Map Compact
          _buildBottomHudLayer(),

          // 5. Layer Overlay Mini-Map Besar (jika dibuka)
          if (_isMiniMapExpanded) _buildExpandedMiniMapOverlay(),

          // 6. Layer Debug Overlay (hanya kDebugMode)
          if (kDebugMode) _buildDebugOverlay(),

          // 7. Layer Wizard Kalibrasi Posisi & Arah
          if (_showCalibrationWizard) _buildCalibrationWizard(),
        ],
      ),
    );
  }

  /// Menampilkan preview kamera fullscreen atau fallback virtual
  Widget _buildCameraLayer() {
    if (_isPermissionDenied) {
      return Container(
        color: const Color(0xFF161922),
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.camera_alt_outlined, size: 72, color: Color(0xFFFF5252)),
            const SizedBox(height: 16),
            const Text(
              'Izin Kamera Dibutuhkan',
              style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'Fitur AR Navigation memerlukan akses kamera untuk menampilkan panduan rute di atas lantai area parkir.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white60, fontSize: 13),
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white70,
                    side: const BorderSide(color: Colors.white24),
                  ),
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Kembali'),
                ),
                const SizedBox(width: 12),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00E5FF),
                    foregroundColor: Colors.black,
                  ),
                  onPressed: () async {
                    await openAppSettings();
                    _initCamera();
                  },
                  icon: const Icon(Icons.settings),
                  label: const Text('Buka Pengaturan'),
                ),
              ],
            ),
          ],
        ),
      );
    }

    if (!_isCameraInitialized || _cameraController == null) {
      return Container(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0, 0.2),
            radius: 1.2,
            colors: [Color(0xFF1E2330), Color(0xFF0B0D13)],
          ),
        ),
        child: Stack(
          children: [
            CustomPaint(
              size: Size.infinite,
              painter: _CyberFloorPainter(),
            ),
            if (_cameraErrorMessage != null)
              Positioned(
                top: 90,
                left: 20,
                right: 20,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0x66FF9800),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.orangeAccent),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.videocam_off, color: Colors.orangeAccent, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Mode Simulasi Visual ($_cameraErrorMessage)',
                          style: const TextStyle(color: Colors.white, fontSize: 11),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      );
    }

    return SizedBox.expand(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: _cameraController!.value.previewSize?.height ?? 1080,
          height: _cameraController!.value.previewSize?.width ?? 1920,
          child: CameraPreview(_cameraController!),
        ),
      ),
    );
  }

  /// Menampilkan AR Overlay (Panah 3D, Panah Penuntun Utama, Pin, Indikator belok)
  Widget _buildArOverlayLayer() {
    return AnimatedBuilder(
      animation: Listenable.merge([
        widget.controller,
        _sensorService,
        _pulseAnimationController,
      ]),
      builder: (context, _) {
        final ctrl = widget.controller;

        // PISAHKAN LOGIKA POSISI:
        // Gunakan Pos Raw (lastRawPosition) untuk proyeksi kamera AR & perhitungan sudut panah.
        // Pos Snap (currentUserPosition) hanya dipakai untuk minimap 2D.
        final rawPos = ctrl.lastRawPosition;
        final snappedPos = ctrl.currentUserPosition;
        final arUserOffset = rawPos ??
            (snappedPos != null ? Offset(snappedPos.x, snappedPos.y) : null);

        if (arUserOffset != null && ctrl.currentRoute.isNotEmpty) {
          _updateSmoothedAngle(
            arUserOffset,
            ctrl.currentRoute,
          );
        }

        return CustomPaint(
          size: Size.infinite,
          painter: AROverlayPainter(
            currentRoute: ctrl.currentRoute,
            userPosition: snappedPos,
            rawUserPosition: arUserOffset,
            mapHeadingDeg: ((_sensorService.effectiveMapHeading % 360.0) + 360.0) % 360.0,
            pitchDeg: (90.0 - _sensorService.devicePitchDeg).clamp(0.0, 75.0),
            targetSlot: ctrl.targetSlot,
            animationValue: _pulseAnimationController.value,
            isNavigating: ctrl.isNavigating,
            isCalibrated: _sensorService.isCalibrated,
            smoothedRelativeAngleDeg: _smoothedRelativeAngleDeg,
          ),
        );
      },
    );
  }

  /// Menampilkan HUD Bagian Atas (Header, Back, Status, Turn-by-Turn Card)
  Widget _buildTopHudLayer() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
          child: ListenableBuilder(
            listenable: Listenable.merge([widget.controller, _sensorService]),
            builder: (context, _) {
              final ctrl = widget.controller;
              final instruction = _getTurnInstruction(
                ctrl.currentRoute,
                ctrl.currentUserPosition,
              );

              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Baris Atas: Tombol Back, Pill Tujuan, Kalibrasi Ulang, Cari Toilet
                  Row(
                    children: [
                      CircleAvatar(
                        backgroundColor: const Color(0xCC1E222D),
                        child: IconButton(
                          icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white, size: 18),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Pill Slot / Lokasi Tujuan
                      Expanded(
                        child: InkWell(
                          onTap: () => DestinationPickerSheet.show(context, widget.controller),
                          borderRadius: BorderRadius.circular(20),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                            decoration: BoxDecoration(
                              color: const Color(0xCC1E222D),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(color: const Color(0xFF00E5FF)),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.place, color: Color(0xFF00E5FF), size: 16),
                                const SizedBox(width: 6),
                                Flexible(
                                  child: Text(
                                    ctrl.targetDestination?.name ??
                                        (ctrl.targetSlot != null ? 'Slot ${ctrl.targetSlot!.id}' : 'Pilih Tujuan'),
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Tombol Kalibrasi Ulang (selalu terlihat selama di AR)
                      CircleAvatar(
                        backgroundColor: _sensorService.isCalibrated
                            ? const Color(0xCC1E222D)
                            : const Color(0xCCFF6F00),
                        child: IconButton(
                          tooltip: 'Kalibrasi Ulang Posisi & Arah',
                          icon: Icon(
                            Icons.my_location,
                            color: _sensorService.isCalibrated
                                ? const Color(0xFF00FF88)
                                : Colors.white,
                            size: 20,
                          ),
                          onPressed: () {
                            setState(() {
                              _sensorService.resetCalibration();
                              widget.controller.resetUserPositionAndStartNode();
                              _showCalibrationWizard = true;
                              _calibrationStep = 0;
                              _calibrationStartNode = null;
                              _calibrationRefNode = null;
                              _isCalibrationSuccess = false;
                            });
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Tombol Cari Toilet Terdekat
                      if (ctrl.hasToilets)
                        CircleAvatar(
                          backgroundColor: const Color(0xCC1E222D),
                          child: IconButton(
                            tooltip: 'Cari Toilet Terdekat',
                            icon: const Icon(Icons.wc, color: Color(0xFFA855F7), size: 20),
                            onPressed: () => ctrl.findNearestToilet(),
                          ),
                        ),
                      const SizedBox(width: 8),
                      // Tombol Cari / Ganti Tujuan
                      CircleAvatar(
                        backgroundColor: const Color(0xCC1E222D),
                        child: IconButton(
                          tooltip: 'Pilih Tujuan Navigasi',
                          icon: const Icon(Icons.search, color: Color(0xFF00E5FF), size: 20),
                          onPressed: () => DestinationPickerSheet.show(context, widget.controller),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 10),

                  // Banner Rerouting / Status
                  if (ctrl.statusBanner != null) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: ctrl.isRerouting
                            ? const Color(0xE6FF6F00)
                            : const Color(0xE600E676),
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: const [
                          BoxShadow(color: Colors.black45, blurRadius: 6, offset: Offset(0, 2)),
                        ],
                      ),
                      child: Row(
                        children: [
                          Icon(
                            ctrl.isRerouting ? Icons.alt_route : Icons.info_outline,
                            color: Colors.black,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              ctrl.statusBanner!,
                              style: const TextStyle(
                                color: Colors.black,
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],

                  // Kartu Turn-By-Turn HUD (Satu Sumber Kebenaran)
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xDE1E222D),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.white12),
                      boxShadow: const [
                        BoxShadow(color: Colors.black54, blurRadius: 10, offset: Offset(0, 4)),
                      ],
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: const Color(0x3300FF88),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            instruction['icon'] as IconData,
                            color: const Color(0xFF00FF88),
                            size: 28,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                instruction['title'] as String,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                instruction['subtitle'] as String,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        // Indikator Jarak Sisa
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              '${ctrl.currentRouteDistance.toStringAsFixed(1)} m',
                              style: const TextStyle(
                                color: Color(0xFF00E5FF),
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              '~${(ctrl.currentRouteDistance / 1.2).round()} dtk',
                              style: const TextStyle(color: Colors.white54, fontSize: 11),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// Menampilkan HUD Bagian Bawah:
  /// - Jika sudah tiba di tujuan: Kartu Selesai ("Anda telah tiba di tujuan", tombol Selesai kembali ke peta)
  /// - Jika navigasi belum mulai: Ringkasan Rute + Tombol "Mulai Navigasi"
  /// - Jika navigasi aktif: Mini-Map Compact + Tombol "Saya sudah sampai", "Koreksi posisi", "Hentikan"
  Widget _buildBottomHudLayer() {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: ListenableBuilder(
            listenable: Listenable.merge([
              widget.controller,
              widget.controller.userPositionNotifier,
              _sensorService,
            ]),
            builder: (context, _) {
              final ctrl = widget.controller;

              // Kondisi 0: Sudah tiba di tujuan
              final hasArrived = ctrl.hasArrived;

              if (hasArrived) {
                return _buildArrivalCard(ctrl);
              }

              // Kondisi 1: Sensor sudah terkalibrasi tetapi navigasi belum dimulai
              // Tampilkan Ringkasan Rute dan tombol Mulai Navigasi AR
              if (_sensorService.isCalibrated && !ctrl.isNavigating) {
                return _buildRouteSummaryCard(ctrl);
              }

              // Kondisi 2: Navigasi aktif atau kalibrasi berjalan
              return Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // Mini-Map Compact di Pojok Kiri Bawah
                  _buildMiniMapCompactWidget(),

                  // Kolom Tombol Aksi di Kanan Bawah
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Chip Info Mode Sensor (hanya tampil di kDebugMode)
                      if (kDebugMode)
                        InkWell(
                          onTap: () => ArManualCalibrationSheet.show(context, _sensorService),
                          borderRadius: BorderRadius.circular(16),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                            decoration: BoxDecoration(
                              color: const Color(0xCC1E222D),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: _sensorService.isSimulationMode
                                    ? const Color(0xFF00E5FF)
                                    : const Color(0xFF00FF88),
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  _sensorService.isSimulationMode
                                      ? Icons.play_circle_outline
                                      : Icons.directions_walk,
                                  size: 14,
                                  color: _sensorService.isSimulationMode
                                      ? const Color(0xFF00E5FF)
                                      : const Color(0xFF00FF88),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  _sensorService.isSimulationMode
                                      ? 'Simulasi'
                                      : 'Langkah: ${_sensorService.stepCount}',
                                  style: const TextStyle(color: Colors.white, fontSize: 11),
                                ),
                              ],
                            ),
                          ),
                        ),
                      if (kDebugMode) const SizedBox(height: 8),

                      // Tombol-tombol selama navigasi aktif
                      if (ctrl.isNavigating) ...[
                        // 1. Tombol "Saya sudah sampai" (cadangan jika dead reckoning melenceng)
                        ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF00FF88),
                            foregroundColor: Colors.black,
                            elevation: 3,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          ),
                          onPressed: () {
                            _saveAndStop(completeArrival: true);
                          },
                          icon: const Icon(Icons.check_circle, size: 16),
                          label: const Text(
                            'Saya sudah sampai',
                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                          ),
                        ),
                        const SizedBox(height: 6),

                        // 2. Tombol "Koreksi posisi" (pilih node tempat berdiri)
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            backgroundColor: const Color(0xDD1E222D),
                            foregroundColor: const Color(0xFF00E5FF),
                            side: const BorderSide(color: Color(0xFF00E5FF), width: 1.2),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          ),
                          onPressed: () {
                            _showPositionCorrectionSheet(context);
                          },
                          icon: const Icon(Icons.edit_location_alt, size: 16),
                          label: const Text(
                            'Koreksi posisi',
                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                          ),
                        ),
                        const SizedBox(height: 6),

                        // 3. Tombol "Hentikan"
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            backgroundColor: const Color(0xDD1E222D),
                            foregroundColor: const Color(0xFFFF5252),
                            side: const BorderSide(color: Color(0xFFFF5252), width: 1.2),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          ),
                          onPressed: () {
                            _saveAndStop();
                          },
                          icon: const Icon(Icons.stop_circle_outlined, size: 16),
                          label: const Text(
                            'Hentikan',
                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],

                      // Tombol Kalibrasi Manual
                      FloatingActionButton.small(
                        heroTag: 'ar_calib_btn',
                        backgroundColor: const Color(0xCC1E222D),
                        foregroundColor: const Color(0xFF00FF88),
                        tooltip: 'Pengaturan & Kalibrasi',
                        onPressed: () => ArManualCalibrationSheet.show(context, _sensorService),
                        child: const Icon(Icons.tune),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// Kartu yang muncul saat tiba di tujuan: pesan tiba dan tombol "Selesai" untuk kembali ke peta
  Widget _buildArrivalCard(NavigationController ctrl) {
    final destName = ctrl.targetDestination?.name ??
        (ctrl.targetSlot != null ? 'Slot ${ctrl.targetSlot!.id}' : 'Tujuan');

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xF21E2330),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF00FF88), width: 1.8),
        boxShadow: const [
          BoxShadow(color: Colors.black87, blurRadius: 16, offset: Offset(0, 6)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0x3300FF88),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.check_circle, color: Color(0xFF00FF88), size: 24),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Tiba di Tujuan',
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                    Text(
                      'Anda telah tiba di $destName',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00FF88),
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              elevation: 4,
            ),
            onPressed: () async {
              await widget.controller.saveLastPosition(
                headingOffsetDeg: _sensorService.mapHeadingOffsetDeg,
              );
              if (mounted) Navigator.pop(context);
            },
            icon: const Icon(Icons.check, size: 20),
            label: const Text(
              'Selesai',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  /// Sheet pemilih node tempat user berdiri untuk mengoreksi posisi jika dead reckoning melenceng
  void _showPositionCorrectionSheet(BuildContext context) {
    final floor = widget.controller.currentFloor;
    if (floor == null) return;

    final namedNodes = floor.nodes
        .where((n) => n.type != NodeType.junction)
        .toList();

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E222D),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Icon(Icons.edit_location_alt, color: Color(0xFF00E5FF)),
                    const SizedBox(width: 8),
                    const Text(
                      'Koreksi Posisi Anda',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white70),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                const Text(
                  'Pilih lokasi/ruangan tempat Anda sedang berdiri saat ini:',
                  style: TextStyle(color: Colors.white60, fontSize: 12),
                ),
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.45,
                  ),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: namedNodes.length,
                    separatorBuilder: (context, index) => const Divider(color: Colors.white10, height: 1),
                    itemBuilder: (ctx, index) {
                      final node = namedNodes[index];
                      return ListTile(
                        leading: const Icon(Icons.place, color: Color(0xFF00FF88), size: 20),
                        title: Text(
                          node.name,
                          style: const TextStyle(color: Colors.white, fontSize: 14),
                        ),
                        subtitle: Text(
                          '(${node.x.toStringAsFixed(1)}m, ${node.y.toStringAsFixed(1)}m)',
                          style: const TextStyle(color: Colors.white38, fontSize: 11),
                        ),
                        onTap: () {
                          widget.controller.correctPositionToNode(node);
                          Navigator.pop(ctx);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('Posisi dikoreksi ke ${node.name}'),
                              backgroundColor: const Color(0xFF00E5FF),
                              duration: const Duration(seconds: 2),
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Ringkasan rute yang ditampilkan sebelum navigasi dimulai
  Widget _buildRouteSummaryCard(NavigationController ctrl) {
    final destName = ctrl.targetDestination?.name ??
        (ctrl.targetSlot != null ? 'Slot ${ctrl.targetSlot!.id}' : '(Belum pilih tujuan)');

    // Hitung apakah tombol Mulai Navigasi AR bisa aktif
    final isCalibrated = _sensorService.isCalibrated;
    final hasStart = ctrl.startNode != null;
    final hasDest = ctrl.targetDestination != null || ctrl.targetSlot != null;
    final startDiffDest = ctrl.startNode == null ||
        ctrl.targetDestination == null ||
        ctrl.startNode!.id != ctrl.targetDestination!.id;
    final hasRoute = ctrl.currentRoute.length >= 2 && ctrl.currentRouteDistance > 0.05;

    final canStartNavigation = isCalibrated && hasStart && hasDest && startDiffDest && hasRoute;

    String? disabledReason;
    if (!canStartNavigation) {
      if (!isCalibrated) {
        disabledReason = 'Kalibrasi arah dulu';
      } else if (!hasStart) {
        disabledReason = 'Pilih posisi awal dulu';
      } else if (!hasDest) {
        disabledReason = 'Pilih tujuan dulu';
      } else if (!startDiffDest) {
        disabledReason = 'Anda sudah di tujuan, pilih tujuan lain';
      } else if (!hasRoute) {
        disabledReason = 'Rute tidak ditemukan';
      }
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xF21E2330),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF00E5FF), width: 1.5),
        boxShadow: const [
          BoxShadow(color: Colors.black87, blurRadius: 16, offset: Offset(0, 6)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0x3300E5FF),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.route, color: Color(0xFF00E5FF), size: 20),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Ringkasan Rute',
                  style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
              Text(
                '${ctrl.currentRouteDistance.toStringAsFixed(1)} m',
                style: const TextStyle(
                  color: Color(0xFF00FF88),
                  fontSize: 17,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Dari -> Ke
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0x55000000),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white10),
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    const Icon(Icons.my_location, color: Color(0xFF00FF88), size: 14),
                    const SizedBox(width: 8),
                    const Text('Dari: ', style: TextStyle(color: Colors.white54, fontSize: 12)),
                    Expanded(
                      child: Text(
                        ctrl.startNode?.name ?? 'Posisi Anda',
                        style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const Divider(color: Colors.white12, height: 12),
                Row(
                  children: [
                    const Icon(Icons.place, color: Color(0xFFFF5252), size: 14),
                    const SizedBox(width: 8),
                    const Text('Ke:   ', style: TextStyle(color: Colors.white54, fontSize: 12)),
                    Expanded(
                      child: Text(
                        destName,
                        style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          // Tombol Mulai Navigasi AR
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: canStartNavigation
                  ? const Color(0xFF00FF88)
                  : const Color(0xFF3A3D4E),
              foregroundColor: canStartNavigation ? Colors.black : Colors.white38,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              elevation: canStartNavigation ? 4 : 0,
            ),
            onPressed: canStartNavigation
                ? () {
                    if (ctrl.targetDestination != null) {
                      ctrl.startRouteNavigation();
                    } else {
                      ctrl.startNavigation();
                    }
                  }
                : null,
            icon: const Icon(Icons.navigation, size: 20),
            label: const Text(
              'Mulai Navigasi AR',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
            ),
          ),
          // Tampilkan alasan jika tombol nonaktif
          if (disabledReason != null) ...[
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.info_outline, color: Color(0xFFFFB74D), size: 13),
                const SizedBox(width: 4),
                Text(
                  disabledReason,
                  style: const TextStyle(
                    color: Color(0xFFFFB74D),
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// Mini-map mode compact di pojok kiri bawah (tap untuk memperbesar)
  Widget _buildMiniMapCompactWidget() {
    return ListenableBuilder(
      listenable: Listenable.merge([
        widget.controller,
        widget.controller.userPositionNotifier,
        widget.controller.userHeadingNotifier,
        _sensorService,
      ]),
      builder: (context, _) {
        final layout = widget.controller.layout;
        if (layout == null) return const SizedBox.shrink();

        const mapWidth = 115.0;
        const mapHeight = 85.0;

        return GestureDetector(
          onTap: () {
            setState(() {
              _isMiniMapExpanded = true;
              _miniMapAutoFollow = true;
            });
          },
          child: Container(
            width: mapWidth,
            height: mapHeight,
            decoration: BoxDecoration(
              color: const Color(0xFF161922),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFF00E5FF), width: 1.5),
              boxShadow: const [
                BoxShadow(color: Colors.black54, blurRadius: 8, offset: Offset(0, 3)),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              children: [
                CustomPaint(
                  size: const Size(mapWidth, mapHeight),
                  painter: MapPainter(
                    layout: layout,
                    floor: widget.controller.currentFloor,
                    route: widget.controller.currentRoute,
                    targetSlot: widget.controller.targetSlot,
                    targetDestination: widget.controller.targetDestination,
                    userPosition: widget.controller.currentUserPosition,
                    headingDeg: _sensorService.effectiveMapHeading,
                    selectedLobby: widget.controller.selectedLobby,
                    scale: 2.2,
                  ),
                ),
                Positioned(
                  top: 4,
                  right: 4,
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      color: Colors.black87,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Icon(
                      Icons.open_in_full,
                      color: Color(0xFF00FF88),
                      size: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Overlay Mini-Map Besar dengan InteractiveViewer (pinch-zoom, pan, auto-follow, zoom +/-, pusatkan)
  /// Menutup tidak lebih dari separuh layar dan diletakkan di bagian atas agar TIDAK MENUTUPI panah utama
  Widget _buildExpandedMiniMapOverlay() {
    return ListenableBuilder(
      listenable: Listenable.merge([
        widget.controller,
        widget.controller.userPositionNotifier,
        widget.controller.userHeadingNotifier,
        _sensorService,
      ]),
      builder: (context, _) {
        final layout = widget.controller.layout;
        if (layout == null) return const SizedBox.shrink();

        final screenSize = MediaQuery.of(context).size;
        final overlayWidth = math.min(screenSize.width * 0.62, 280.0);
        final overlayHeight = math.min(screenSize.height * 0.36, 250.0);

        const mapCanvasScale = 16.0;
        final mapCanvasWidth = layout.width * mapCanvasScale;
        final mapCanvasHeight = layout.height * mapCanvasScale;

        final viewportSize = Size(overlayWidth, overlayHeight - 34);

        if (_miniMapAutoFollow && widget.controller.currentUserPosition != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || !_miniMapAutoFollow) return;
            _centerMiniMapOnUser(viewportSize);
          });
        }

        return Positioned(
          top: 135,
          left: 16,
          child: Container(
            width: overlayWidth,
            height: overlayHeight,
            decoration: BoxDecoration(
              color: const Color(0xFF141824),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFF00E5FF), width: 1.5),
              boxShadow: const [
                BoxShadow(color: Colors.black87, blurRadius: 14, offset: Offset(0, 5)),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                // Header Mini-Map
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  color: const Color(0xFF1E2332),
                  child: Row(
                    children: [
                      const Icon(Icons.map, color: Color(0xFF00E5FF), size: 14),
                      const SizedBox(width: 6),
                      const Text(
                        'Denah Lokasi',
                        style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                      ),
                      const Spacer(),
                      InkWell(
                        onTap: () {
                          setState(() {
                            _isMiniMapExpanded = false;
                          });
                        },
                        child: Container(
                          padding: const EdgeInsets.all(2),
                          decoration: BoxDecoration(
                            color: Colors.white12,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Icon(Icons.close, color: Colors.white70, size: 14),
                        ),
                      ),
                    ],
                  ),
                ),
                // Canvas Denah dengan InteractiveViewer
                Expanded(
                  child: Stack(
                    children: [
                      InteractiveViewer(
                        transformationController: _mapTransformController,
                        minScale: 0.5,
                        maxScale: 6.0,
                        boundaryMargin: const EdgeInsets.all(150),
                        onInteractionStart: (_) {
                          if (_miniMapAutoFollow) {
                            setState(() {
                              _miniMapAutoFollow = false;
                            });
                          }
                        },
                        child: CustomPaint(
                          size: Size(mapCanvasWidth, mapCanvasHeight),
                          painter: MapPainter(
                            layout: layout,
                            floor: widget.controller.currentFloor,
                            route: widget.controller.currentRoute,
                            targetSlot: widget.controller.targetSlot,
                            targetDestination: widget.controller.targetDestination,
                            userPosition: widget.controller.currentUserPosition,
                            headingDeg: _sensorService.effectiveMapHeading,
                            selectedLobby: widget.controller.selectedLobby,
                            scale: mapCanvasScale,
                            zoomScale: _mapTransformController.value.getMaxScaleOnAxis(),
                          ),
                        ),
                      ),
                      // Tombol Kontrol: Pusatkan ke Saya, Zoom In (+), Zoom Out (-)
                      Positioned(
                        right: 6,
                        bottom: 6,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _buildMapActionButton(
                              icon: Icons.my_location,
                              tooltip: 'Pusatkan ke Saya',
                              isActive: _miniMapAutoFollow,
                              onTap: () {
                                setState(() {
                                  _miniMapAutoFollow = true;
                                });
                                _centerMiniMapOnUser(viewportSize);
                              },
                            ),
                            const SizedBox(height: 4),
                            _buildMapActionButton(
                              icon: Icons.add,
                              tooltip: 'Perbesar',
                              onTap: () => _zoomMiniMap(1.25, viewportSize),
                            ),
                            const SizedBox(height: 4),
                            _buildMapActionButton(
                              icon: Icons.remove,
                              tooltip: 'Perkecil',
                              onTap: () => _zoomMiniMap(0.8, viewportSize),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildMapActionButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    bool isActive = false,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: isActive ? const Color(0xCC00FF88) : const Color(0xCC1E222D),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isActive ? Colors.white : const Color(0xFF00E5FF),
            width: 1.0,
          ),
        ),
        child: Icon(
          icon,
          size: 14,
          color: isActive ? Colors.black : Colors.white,
        ),
      ),
    );
  }

  /// Debug overlay: collapsible panel di pojok kanan atas agar tidak menutupi panah navigasi (hanya kDebugMode)
  Widget _buildDebugOverlay() {
    return Positioned(
      top: 135,
      right: 16,
      child: ListenableBuilder(
        listenable: Listenable.merge([
          _sensorService,
          widget.controller,
          widget.controller.userPositionNotifier,
          widget.controller.userHeadingNotifier,
        ]),
        builder: (context, _) {
          if (!_isDebugExpanded) {
            return GestureDetector(
              onTap: () => setState(() => _isDebugExpanded = true),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F1420),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFF00E5FF), width: 1.0),
                  boxShadow: const [
                    BoxShadow(color: Colors.black54, blurRadius: 6, offset: Offset(0, 2)),
                  ],
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.bug_report, color: Color(0xFF00E5FF), size: 14),
                    SizedBox(width: 4),
                    Text(
                      'DEBUG',
                      style: TextStyle(
                        color: Color(0xFF00FF88),
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }

          final ctrl = widget.controller;
          final userPos = ctrl.currentUserPosition;
          final rawPos = ctrl.lastRawPosition;
          final snapPosStr = userPos != null
              ? '(${userPos.x.toStringAsFixed(2)}, ${userPos.y.toStringAsFixed(2)})'
              : '-';
          final rawPosStr = rawPos != null
              ? '(${rawPos.dx.toStringAsFixed(2)}, ${rawPos.dy.toStringAsFixed(2)})'
              : '-';

          // Status navigasi: idle / berjalan / tiba
          String navStatus;
          if (ctrl.isNavigating) {
            navStatus = 'BERJALAN';
          } else if (ctrl.hasArrived) {
            navStatus = 'TIBA';
          } else {
            navStatus = 'IDLE';
          }

          final offset = _sensorService.mapHeadingOffsetDeg;
          final mapHeading = _sensorService.effectiveMapHeading;
          final mismatch = _sensorService.headingMismatchWarning;
          final stepsSinceStart = ctrl.stepsSinceStart;
          final stepsTotal = _sensorService.stepCount;
          final traveledDist = ctrl.distanceTraveled;
          final remDist = ctrl.currentRouteDistance;
          final progressPct = (ctrl.routeProgress * 100).toStringAsFixed(0);

          String bearingStr = '-';
          String diffStr = '-';
          String distNextStr = '-';
          if (userPos != null && ctrl.currentRoute.isNotEmpty) {
            final userOff = Offset(userPos.x, userPos.y);
            final nextPt = _getNextRoutePoint(userOff, ctrl.currentRoute) ??
                Offset(ctrl.currentRoute.first.x, ctrl.currentRoute.first.y);
            final bearing = ARProjector.calculateBearingDeg(userOff, nextPt);
            final angleDiff = ARProjector.angleDifferenceDeg(bearing, mapHeading);
            final distNext = (nextPt - userOff).distance;

            bearingStr = '${bearing.toStringAsFixed(1)}°';
            diffStr = '${angleDiff.toStringAsFixed(1)}°';
            distNextStr = '${distNext.toStringAsFixed(1)} m';
          }

          final maxHeight = MediaQuery.of(context).size.height * 0.45;

          return Container(
            width: 250,
            constraints: BoxConstraints(maxHeight: maxHeight),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFF0F1420),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFF00E5FF), width: 0.8),
              boxShadow: const [
                BoxShadow(color: Colors.black87, blurRadius: 10, offset: Offset(0, 4)),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('🐛 DEBUG AR', style: TextStyle(color: Color(0xFF00FF88), fontSize: 11, fontWeight: FontWeight.bold)),
                    GestureDetector(
                      onTap: () => setState(() => _isDebugExpanded = false),
                      child: const Padding(
                        padding: EdgeInsets.all(2),
                        child: Icon(Icons.close, color: Colors.white70, size: 16),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Flexible(
                  child: SingleChildScrollView(
                    child: DefaultTextStyle(
                      style: const TextStyle(
                        color: Color(0xFF00FF88),
                        fontSize: 9.5,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w500,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('Status  : $navStatus'),
                          Text('Sumber  : ${_sensorService.activeStepSourceName}'),
                          if (_sensorService.isFallbackMode)
                            Container(
                              margin: const EdgeInsets.symmetric(vertical: 2),
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: const Color(0x33FFB300),
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(color: const Color(0xFFFFB300), width: 0.8),
                              ),
                              child: const Text(
                                'Mode langkah cadangan',
                                style: TextStyle(color: Color(0xFFFFB300), fontSize: 9, fontWeight: FontWeight.bold),
                              ),
                            ),
                          Text('Langkah : $stepsSinceStart (nav) | Tot: $stepsTotal (OK)'),
                          Text('Per-Src : Pedometer: ${_sensorService.pedometerStepCount} | Accel: ${_sensorService.accelStepCount}'),
                          Text('Wkt Evt : ${_sensorService.lastStepEventTimeFormatted}'),
                          Text('Ditolak : ${_sensorService.rejectedStepCount} (amp:${_sensorService.rejectedAmplitudeCount}, intv:${_sensorService.rejectedIntervalCount}, gyro:${_sensorService.rejectedGyroCount}, pitch:${_sensorService.rejectedPitchCount})'),
                          if (_sensorService.lastRejectReason.isNotEmpty)
                            Text('Tolak Krn: ${_sensorService.lastRejectReason}', style: const TextStyle(color: Colors.amberAccent)),
                          Text('Accel   : ${_sensorService.accelMagnitudeRealtime.toStringAsFixed(2)} m/s² (Peak2s: ${_sensorService.accelPeak2Sec.toStringAsFixed(2)})'),
                          Text('GyroMag : ${_sensorService.gyroMagnitude.toStringAsFixed(2)} rad/s'),
                          Text('Ditempuh: ${traveledDist.toStringAsFixed(1)} m | Sisa: ${remDist.toStringAsFixed(1)} m ($progressPct%)'),
                          Text('Pos Snap: $snapPosStr'),
                          Text('Pos Raw : $rawPosStr'),
                          // --- Heading breakdown ---
                          const Divider(color: Colors.white12, height: 6),
                          Text('Accel   : (${_sensorService.accelX.toStringAsFixed(2)}, ${_sensorService.accelY.toStringAsFixed(2)}, ${_sensorService.accelZ.toStringAsFixed(2)}) m/s²'),
                          Text('Mag     : (${_sensorService.magX.toStringAsFixed(1)}, ${_sensorService.magY.toStringAsFixed(1)}, ${_sensorService.magZ.toStringAsFixed(1)}) uT'),
                          Text('|m|     : ${_sensorService.magMagnitude.toStringAsFixed(1)} uT | MagRate: ${_sensorService.magEventsPerSec.toStringAsFixed(1)} evt/s'),
                          Text('Tilt    : ${_sensorService.devicePitchDeg.toStringAsFixed(1)}° (tegak: ${_sensorService.isTiltValid ? "✅" : "❌"})'),
                          Text(
                            _sensorService.cameraHeading != null
                                ? 'H-Baru  : ${_sensorService.cameraHeading!.toStringAsFixed(1)}° (${_sensorService.isHeadingValid ? "VALID" : "INVALID"})'
                                : 'H-Baru  : - (INVALID)',
                            style: TextStyle(color: _sensorService.isHeadingValid ? const Color(0xFF00FF88) : const Color(0xFFFF5252)),
                          ),
                          Text('H-FlComp: ${_sensorService.compassHeadingFlutterCompass.toStringAsFixed(1)}° (flutter_compass)'),
                          Text('H-Pakai : ${_sensorService.preferredHeading.toStringAsFixed(1)}° (${_sensorService.headingSourceLabel})'),
                          if (mismatch)
                            Container(
                              margin: const EdgeInsets.symmetric(vertical: 2),
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: const Color(0x33FF5252),
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(color: const Color(0xFFFF5252), width: 0.8),
                              ),
                              child: const Text(
                                '⚠️ Heading datar vs kamera beda > 30°',
                                style: TextStyle(color: Color(0xFFFF5252), fontSize: 9, fontWeight: FontWeight.bold),
                              ),
                            ),
                          Text('Offset  : ${offset.toStringAsFixed(1)}°  (headingOffset)'),
                          Text('Bearing : $bearingStr | Δ:$diffStr | Next: $distNextStr'),
                          Text('Calibr  : ${_sensorService.isCalibrated ? "✅" : "❌"}'),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              SizedBox(
                                height: 26,
                                child: ElevatedButton.icon(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFF00E5FF),
                                    foregroundColor: Colors.black,
                                    padding: const EdgeInsets.symmetric(horizontal: 8),
                                    visualDensity: VisualDensity.compact,
                                  ),
                                  onPressed: () {
                                    _sensorService.debugSimulateStep();
                                  },
                                  icon: const Icon(Icons.directions_walk, size: 14),
                                  label: const Text('+1 lkg', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                                ),
                              ),
                              const SizedBox(width: 6),
                              SizedBox(
                                height: 26,
                                child: ElevatedButton.icon(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFFFF5252),
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(horizontal: 6),
                                    visualDensity: VisualDensity.compact,
                                  ),
                                  onPressed: () {
                                    _sensorService.flipHeading180();
                                  },
                                  icon: const Icon(Icons.sync, size: 14),
                                  label: const Text('180°', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// Wizard kalibrasi posisi & arah (2 langkah):
  /// Step 0: "Anda berdiri di mana?" - pilih node awal
  /// Step 1: "Kalibrasi Arah" - hadapkan HP ke node acuan, tekan kalibrasi
  Widget _buildCalibrationWizard() {
    return Container(
      color: const Color(0xFF0B0E17),
      child: SafeArea(
        child: _calibrationStep == 0
            ? _buildCalibStepPickPosition()
            : _buildCalibStepCalibrateHeading(),
      ),
    );
  }

  /// Step 0: Pilih posisi awal ("Anda berdiri di mana?")
  Widget _buildCalibStepPickPosition() {
    final destinations = widget.controller.availableDestinations;

    return Column(
      children: [
        const SizedBox(height: 20),
        // Header
        Row(
          children: [
            const SizedBox(width: 16),
            CircleAvatar(
              backgroundColor: const Color(0xFF1E222D),
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white70, size: 20),
                onPressed: () {
                  setState(() => _showCalibrationWizard = false);
                },
              ),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Anda berdiri di mana?',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    'Pilih lokasi terdekat dari posisi Anda sekarang',
                    style: TextStyle(color: Colors.white60, fontSize: 13),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 16),
          ],
        ),
        const SizedBox(height: 16),
        // Step indicator
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              _buildStepDot(0, 'Posisi'),
              Expanded(
                child: Container(height: 2, color: Colors.white24),
              ),
              _buildStepDot(1, 'Arah'),
            ],
          ),
        ),
        const SizedBox(height: 16),
        // Daftar node
        Expanded(
          child: destinations.isEmpty
              ? const Center(
                  child: Text(
                    'Tidak ada node bernama pada denah.',
                    style: TextStyle(color: Colors.white54, fontSize: 14),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: destinations.length,
                  separatorBuilder: (context, index) => const SizedBox(height: 8),
                  itemBuilder: (ctx, i) {
                    final node = destinations[i];
                    final isSelected = _calibrationStartNode?.id == node.id;
                    return Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () {
                          setState(() => _calibrationStartNode = node);
                        },
                        child: Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? const Color(0x3300FF88)
                                : const Color(0xFF1A1D27),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: isSelected
                                  ? const Color(0xFF00FF88)
                                  : Colors.white12,
                              width: isSelected ? 2 : 1,
                            ),
                          ),
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: isSelected
                                      ? const Color(0xFF00FF88)
                                      : const Color(0xFF262A38),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Icon(
                                  _nodeTypeIcon(node.type),
                                  color: isSelected ? Colors.black : Colors.white70,
                                  size: 22,
                                ),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      node.name,
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                                        fontSize: 15,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      'Koordinat: (${node.x.toStringAsFixed(1)}m, ${node.y.toStringAsFixed(1)}m)',
                                      style: const TextStyle(color: Colors.white38, fontSize: 11),
                                    ),
                                  ],
                                ),
                              ),
                              if (isSelected)
                                const Icon(Icons.check_circle, color: Color(0xFF00FF88), size: 22),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
        // Tombol Lanjut
        Padding(
          padding: const EdgeInsets.all(16),
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: _calibrationStartNode != null
                  ? const Color(0xFF00FF88)
                  : const Color(0xFF2A2E3D),
              foregroundColor: _calibrationStartNode != null ? Colors.black : Colors.white38,
              minimumSize: const Size.fromHeight(50),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            onPressed: _calibrationStartNode == null
                ? null
                : () {
                    // Set node awal pada controller; returns false jika start == dest
                    final ok = widget.controller.setStartNode(_calibrationStartNode!);
                    if (!ok) {
                      // Posisi awal == tujuan saat ini: peringatkan user dan buka pemilih tujuan baru
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              'Anda sudah di "${_calibrationStartNode!.name}", pilih tujuan lain.',
                            ),
                            backgroundColor: const Color(0xFFFF5252),
                            duration: const Duration(seconds: 3),
                          ),
                        );
                        // Buka picker tujuan agar user bisa ganti tujuan
                        DestinationPickerSheet.show(context, widget.controller);
                      }
                      return; // Jangan lanjut ke step kalibrasi arah
                    }
                    // Cari acuan default
                    final ref = _getDefaultReferenceNode(_calibrationStartNode!);
                    setState(() {
                      _calibrationRefNode = ref;
                      _calibrationStep = 1;
                    });
                  },
            child: const Text(
              'Lanjut ke Kalibrasi Arah →',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
        ),
      ],
    );
  }

  /// Step 1: Kalibrasi arah ("Hadapkan HP ke arah node acuan")
  Widget _buildCalibStepCalibrateHeading() {
    final floor = widget.controller.currentFloor;
    final allTargets = floor?.nodes
        .where((n) => n.type != NodeType.junction && n.id != _calibrationStartNode?.id)
        .toList() ?? <MapNode>[];

    // Letakkan target terpilih atau tujuan di paling depan daftar chip
    if (_calibrationRefNode != null) {
      allTargets.sort((a, b) {
        if (a.id == _calibrationRefNode!.id) return -1;
        if (b.id == _calibrationRefNode!.id) return 1;
        return 0;
      });
    }

    // Rentang pitch tegak: 55° - 90° (HP dipegang seperti saat berjalan)
    const double pitchLow = 55.0;
    const double pitchHigh = 90.0;

    return Column(
      children: [
        const SizedBox(height: 20),
        // Header
        Row(
          children: [
            const SizedBox(width: 16),
            CircleAvatar(
              backgroundColor: const Color(0xFF1E222D),
              child: IconButton(
                icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white70, size: 18),
                onPressed: () {
                  setState(() {
                    _calibrationStep = 0;
                    _isCalibrationSuccess = false;
                  });
                },
              ),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Kalibrasi Arah',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    'Kalibrasi kompas agar panah AR sesuai arah fisik',
                    style: TextStyle(color: Colors.white60, fontSize: 13),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 16),
          ],
        ),
        const SizedBox(height: 16),
        // Step indicator
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              _buildStepDot(0, 'Posisi'),
              Expanded(child: Container(height: 2, color: const Color(0xFF00FF88))),
              _buildStepDot(1, 'Arah'),
            ],
          ),
        ),
        const SizedBox(height: 20),

        // Instruksi utama
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            children: [
              Icon(
                _isCalibrationSuccess
                    ? Icons.check_circle
                    : _isCalibratingHeading
                        ? Icons.hourglass_top
                        : Icons.stay_current_portrait,
                color: _isCalibrationSuccess
                    ? const Color(0xFF00FF88)
                    : const Color(0xFF00E5FF),
                size: 64,
              ),
              const SizedBox(height: 16),
              Text(
                _isCalibrationSuccess
                    ? 'Terkalibrasi! ✅'
                    : _isCalibratingHeading
                        ? 'Mengukur kompas...'
                        : 'Hadapkan HP lurus ke arah:',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (!_isCalibrationSuccess && !_isCalibratingHeading) ...[
                const SizedBox(height: 8),
                Text(
                  _calibrationRefNode?.name ?? '(pilih node acuan)',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFF00FF88),
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Dari: ${_calibrationStartNode?.name ?? "-"}',
                  style: const TextStyle(color: Colors.white54, fontSize: 13),
                ),
                const SizedBox(height: 14),
                // Instruksi pegang tegak
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: const Color(0x2200E5FF),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0x6600E5FF)),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.stay_current_portrait, color: Color(0xFF00E5FF), size: 20),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Pegang HP tegak seperti saat berjalan, lalu arahkan kamera ke tujuan.',
                          style: TextStyle(color: Color(0xFFB0D8FF), fontSize: 12, height: 1.4),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),

        const SizedBox(height: 16),

        // Chips untuk mengganti node acuan
        if (!_isCalibratingHeading && !_isCalibrationSuccess) ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Ganti node acuan:',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 40,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: allTargets.length,
                    separatorBuilder: (context, index) => const SizedBox(width: 8),
                    itemBuilder: (ctx, i) {
                      final node = allTargets[i];
                      final isSelected = _calibrationRefNode?.id == node.id;
                      return ChoiceChip(
                        label: Text(
                          node.name,
                          style: TextStyle(
                            color: isSelected ? Colors.black : Colors.white70,
                            fontSize: 12,
                          ),
                        ),
                        selected: isSelected,
                        selectedColor: const Color(0xFF00FF88),
                        backgroundColor: const Color(0xFF2A2E3D),
                        onSelected: (_) {
                          setState(() => _calibrationRefNode = node);
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],

        const Spacer(),

        // Indikator pitch & kompas live
        if (!_isCalibrationSuccess)
          ListenableBuilder(
            listenable: _sensorService,
            builder: (context, _) {
              final pitch = _sensorService.devicePitchDeg;
              final isTiltValid = _sensorService.isTiltValid;
              final isHeadingValid = _sensorService.isHeadingValid;

              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  children: [
                    // Bar indikator pitch (tilt)
                    Row(
                      children: [
                        const Icon(Icons.screen_rotation_alt, color: Colors.white38, size: 14),
                        const SizedBox(width: 6),
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: (pitch / 90.0).clamp(0.0, 1.0),
                              minHeight: 8,
                              backgroundColor: const Color(0xFF2A2E3D),
                              valueColor: AlwaysStoppedAnimation<Color>(
                                isTiltValid ? const Color(0xFF00FF88) : const Color(0xFFFFB300),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${pitch.toStringAsFixed(0)}°',
                          style: TextStyle(
                            color: isTiltValid ? const Color(0xFF00FF88) : const Color(0xFFFFB300),
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    // Status pitch / sensor
                    Text(
                      !isTiltValid
                          ? '⚠️ Miringkan HP ke posisi tegak (${pitchLow.toInt()}°–${pitchHigh.toInt()}°)'
                          : !isHeadingValid
                              ? '⏳ Menunggu sensor kompas...'
                              : '✅ Posisi tegak terdeteksi — siap kalibrasi',
                      style: TextStyle(
                        color: !isTiltValid
                            ? const Color(0xFFFFB300)
                            : !isHeadingValid
                                ? const Color(0xFF00E5FF)
                                : const Color(0xFF00FF88),
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Kompas: ${_sensorService.preferredHeading.toStringAsFixed(1)}°'
                      '  ${_sensorService.hasCompass || _sensorService.isCameraHeadingValid ? "🧭" : "⚠️ No compass"}'
                      '  (${_sensorService.headingSourceLabel})',
                      style: const TextStyle(color: Colors.white38, fontSize: 11),
                    ),
                  ],
                ),
              );
            },
          ),

        const SizedBox(height: 12),

        // Slider koreksi manual — muncul setelah kalibrasi sukses
        // Agar user bisa koreksi jika panah terbalik (±180°) atau miring (±90°)
        if (_isCalibrationSuccess)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: ListenableBuilder(
              listenable: _sensorService,
              builder: (context, _) {
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: const Color(0x1500FF88),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0x4400FF88)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.tune, color: Color(0xFF00FF88), size: 16),
                          const SizedBox(width: 8),
                          const Text(
                            'Koreksi arah (jika panah terbalik/miring):',
                            style: TextStyle(color: Color(0xFF00FF88), fontSize: 12, fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const Text('-180°', style: TextStyle(color: Colors.white38, fontSize: 10)),
                          Expanded(
                            child: Slider(
                              value: _calibrationOffsetCorrection,
                              min: -180.0,
                              max: 180.0,
                              divisions: 72, // step 5°
                              activeColor: const Color(0xFF00FF88),
                              inactiveColor: const Color(0xFF2A2E3D),
                              label: '${_calibrationOffsetCorrection.toStringAsFixed(0)}°',
                              onChanged: (val) {
                                setState(() => _calibrationOffsetCorrection = val);
                                // Selalu hitung dari base offset (bukan dari offset yang sudah dimodifikasi)
                                _sensorService.setManualHeadingOffset(
                                  _baseCalibrationOffset + val,
                                );
                              },
                            ),
                          ),
                          const Text('+180°', style: TextStyle(color: Colors.white38, fontSize: 10)),
                        ],
                      ),
                      Center(
                        child: Text(
                          'Koreksi: ${_calibrationOffsetCorrection >= 0 ? "+" : ""}${_calibrationOffsetCorrection.toStringAsFixed(0)}°  |  '
                          'Offset aktif: ${_sensorService.mapHeadingOffsetDeg.toStringAsFixed(0)}°',
                          style: const TextStyle(color: Colors.white54, fontSize: 11),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          TextButton(
                            onPressed: () {
                              setState(() => _calibrationOffsetCorrection = 0.0);
                              // Reset slider tapi JANGAN reset offset kalibrasi
                            },
                            child: const Text('Reset slider', style: TextStyle(color: Colors.white38, fontSize: 11)),
                          ),
                          TextButton(
                            style: TextButton.styleFrom(foregroundColor: const Color(0xFFFF5252)),
                            onPressed: () {
                              // Tombol cepat: balik 180° dari koreksi saat ini
                              final newCorrection = _calibrationOffsetCorrection + 180.0;
                              final clamped = newCorrection > 180.0 ? newCorrection - 360.0 : newCorrection;
                              setState(() => _calibrationOffsetCorrection = clamped);
                              _sensorService.setManualHeadingOffset(
                                _baseCalibrationOffset + clamped,
                              );
                            },
                            child: const Text('Balik 180° (panah terbalik)', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              },
            ),
          ),

        const SizedBox(height: 4),

        // Tombol kalibrasi
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: ListenableBuilder(
            listenable: _sensorService,
            builder: (context, _) {
              final isTiltValid = _sensorService.isTiltValid;
              final isHeadingValid = _sensorService.isHeadingValid;
              // Izinkan kalibrasi meski heading dari kamera tidak valid,
              // selama HP dipegang tegak (isTiltValid) dan ada node acuan.
              // flutter_compass selalu tersedia sebagai fallback.
              final canPress = _calibrationRefNode != null &&
                  !_isCalibratingHeading &&
                  (isTiltValid || _isCalibrationSuccess);

              String buttonLabel;
              if (_isCalibrationSuccess) {
                buttonLabel = 'Selesai ✓';
              } else if (_isCalibratingHeading) {
                buttonLabel = 'Mengukur kompas...';
              } else if (!isTiltValid) {
                buttonLabel = 'Pegang HP tegak';
              } else if (!isHeadingValid) {
                buttonLabel = 'Kalibrasi (kompas lemah, bisa lanjut)';
              } else {
                buttonLabel = 'Kalibrasi Sekarang';
              }

              return ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _isCalibrationSuccess
                      ? const Color(0xFF00FF88)
                      : canPress
                          ? const Color(0xFF00E5FF)
                          : const Color(0xFF2A2E3D),
                  foregroundColor: _isCalibrationSuccess || canPress ? Colors.black : Colors.white38,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  minimumSize: const Size.fromHeight(52),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                onPressed: canPress
                    ? (_isCalibrationSuccess
                        ? () {
                            setState(() {
                              _showCalibrationWizard = false;
                              _calibrationOffsetCorrection = 0.0;
                            });
                          }
                        : _performHeadingCalibration)
                    : null,
                icon: Icon(
                  _isCalibrationSuccess
                      ? Icons.check
                      : _isCalibratingHeading
                          ? Icons.hourglass_top
                          : Icons.explore,
                ),
                label: Text(
                  buttonLabel,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  /// Dot indicator untuk step kalibrasi
  Widget _buildStepDot(int step, String label) {
    final isActive = _calibrationStep >= step;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isActive ? const Color(0xFF00FF88) : const Color(0xFF2A2E3D),
            border: Border.all(
              color: isActive ? const Color(0xFF00FF88) : Colors.white24,
              width: 2,
            ),
          ),
          child: Center(
            child: Text(
              '${step + 1}',
              style: TextStyle(
                color: isActive ? Colors.black : Colors.white54,
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            color: isActive ? const Color(0xFF00FF88) : Colors.white38,
            fontSize: 10,
          ),
        ),
      ],
    );
  }

  /// Ikon sesuai tipe node
  IconData _nodeTypeIcon(NodeType type) {
    switch (type) {
      case NodeType.entrance:
        return Icons.door_front_door;
      case NodeType.room:
        return Icons.meeting_room;
      case NodeType.slot:
        return Icons.local_parking;
      case NodeType.toilet:
        return Icons.wc;
      case NodeType.stairs:
        return Icons.stairs;
      case NodeType.elevator:
        return Icons.elevator;
      default:
        return Icons.place;
    }
  }
}

/// Painter grid lantai perspektif untuk mode simulasi visual tanpa kamera
class _CyberFloorPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final horizonY = size.height * 0.45;
    final gridPaint = Paint()
      ..color = const Color(0x1F00E5FF)
      ..strokeWidth = 1.0;

    double y = horizonY + 20;
    double step = 8;
    while (y < size.height) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
      y += step;
      step *= 1.25;
    }

    final vanishingPoint = Offset(size.width / 2, horizonY);
    for (double x = -size.width * 0.5; x <= size.width * 1.5; x += size.width / 8) {
      canvas.drawLine(vanishingPoint, Offset(x, size.height), gridPaint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
