import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/parking_models.dart';
import '../services/ar_projector.dart';
import '../services/ar_sensor_service.dart';
import '../services/navigation_controller.dart';
import '../widgets/ar_manual_calibration_sheet.dart';
import '../widgets/ar_overlay_painter.dart';
import '../widgets/ar_qr_scanner_sheet.dart';
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
  bool _isMiniMapExpanded = false;

  @override
  void initState() {
    super.initState();
    _sensorService = ARSensorService(controller: widget.controller);

    _pulseAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();

    _initCamera();
  }

  @override
  void dispose() {
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

  /// Menghasilkan teks instruksi belokan turn-by-turn dari rute saat ini
  Map<String, dynamic> _getTurnInstruction(List<Node> route, Node? userPos) {
    if (route.isEmpty || userPos == null) {
      return {
        'icon': Icons.check_circle,
        'title': 'Tiba di Tujuan',
        'subtitle': 'Anda telah sampai di slot tujuan',
      };
    }

    if (route.length == 1) {
      final dist = (Offset(route.first.x, route.first.y) - Offset(userPos.x, userPos.y)).distance;
      return {
        'icon': Icons.local_parking,
        'title': 'Slot Tujuan di Depan',
        'subtitle': 'Jarak: ${dist.toStringAsFixed(1)} m ke slot parkir',
      };
    }

    // Hitung jarak ke node berikutnya
    final nextNode = route[1];
    final distToNext = (Offset(nextNode.x, nextNode.y) - Offset(userPos.x, userPos.y)).distance;

    if (route.length >= 3) {
      final afterNext = route[2];
      final b1 = ARProjector.calculateBearingDeg(
        Offset(userPos.x, userPos.y),
        Offset(nextNode.x, nextNode.y),
      );
      final b2 = ARProjector.calculateBearingDeg(
        Offset(nextNode.x, nextNode.y),
        Offset(afterNext.x, afterNext.y),
      );
      final turnDiff = ARProjector.angleDifferenceDeg(b2, b1);

      if (turnDiff > 35.0 && turnDiff <= 145.0) {
        return {
          'icon': Icons.turn_right,
          'title': distToNext < 3.0 ? 'Segera Belok Kanan' : 'Dalam ${distToNext.toStringAsFixed(0)} m, Belok Kanan',
          'subtitle': 'Ikuti lorong menuju slot',
        };
      } else if (turnDiff < -35.0 && turnDiff >= -145.0) {
        return {
          'icon': Icons.turn_left,
          'title': distToNext < 3.0 ? 'Segera Belok Kiri' : 'Dalam ${distToNext.toStringAsFixed(0)} m, Belok Kiri',
          'subtitle': 'Ikuti lorong menuju slot',
        };
      } else if (turnDiff.abs() > 145.0) {
        return {
          'icon': Icons.u_turn_right,
          'title': 'Putar Balik',
          'subtitle': 'Arahkan haluan kendaraan',
        };
      }
    }

    return {
      'icon': Icons.straight,
      'title': 'Lurus Mengikuti Lorong',
      'subtitle': 'Jarak sisa: ${widget.controller.currentRouteDistance.toStringAsFixed(1)} m',
    };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 1. Layer Dasar: Camera Preview (atau Simulated Cyber Floor jika tanpa kamera fisik)
          _buildCameraLayer(),

          // 2. Layer AR: CustomPainter dengan chevrons 3D, floating pin, dan turn guidance
          _buildArOverlayLayer(),

          // 3. Layer HUD Atas: Header, Turn-by-Turn, Status Banner
          _buildTopHudLayer(),

          // 4. Layer HUD Bawah: Kontrol Kalibrasi, Mini-Map, Info Rute
          _buildBottomHudLayer(),
        ],
      ),
    );
  }

  /// Menampilkan preview kamera fullscreen atau fallback tampilan virtual
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
      // Background simulasi bertekstur modern gelap (mendukung testing desktop/emulator)
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
            // Grid lantai perspektif halus
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
                          'Mode Simulasi Visual (${_cameraErrorMessage!})',
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

    // Kamera aktif: render CameraPreview fullscreen dengan aspect ratio cover
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

  /// Menampilkan AR Overlay (Panah 3D, Pin, Indikator belok)
  Widget _buildArOverlayLayer() {
    return AnimatedBuilder(
      animation: Listenable.merge([
        widget.controller,
        _sensorService,
        _pulseAnimationController,
      ]),
      builder: (context, _) {
        final ctrl = widget.controller;
        return CustomPaint(
          size: Size.infinite,
          painter: AROverlayPainter(
            currentRoute: ctrl.currentRoute,
            userPosition: ctrl.currentUserPosition,
            mapHeadingDeg: _sensorService.effectiveMapHeading,
            pitchDeg: _sensorService.devicePitchDeg,
            targetSlot: ctrl.targetSlot,
            animationValue: _pulseAnimationController.value,
          ),
        );
      },
    );
  }

  /// Menampilkan HUD Bagian Atas
  Widget _buildTopHudLayer() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
          child: ListenableBuilder(
            listenable: widget.controller,
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
                  // Baris Atas: Tombol Back & Kalibrasi QR & Info Slot
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      CircleAvatar(
                        backgroundColor: const Color(0xCC1E222D),
                        child: IconButton(
                          icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white, size: 18),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ),
                      // Pill Slot Tujuan
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                        decoration: BoxDecoration(
                          color: const Color(0xCC1E222D),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: const Color(0xFF00E5FF)),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.local_parking, color: Color(0xFF00E5FF), size: 16),
                            const SizedBox(width: 6),
                            Text(
                              ctrl.targetSlot != null ? 'Slot ${ctrl.targetSlot!.id}' : 'Tanpa Target',
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                      // Tombol QR Scan
                      CircleAvatar(
                        backgroundColor: const Color(0xCC1E222D),
                        child: IconButton(
                          tooltip: 'Kalibrasi via QR',
                          icon: const Icon(Icons.qr_code_scanner, color: Color(0xFF00FF88), size: 20),
                          onPressed: () => ArQrScannerSheet.show(context, _sensorService),
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

                  // Kartu Turn-By-Turn HUD
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

  /// Menampilkan HUD Bagian Bawah (Mini-Map, Pengaturan, Status Sensor)
  Widget _buildBottomHudLayer() {
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Baris Bar mini-map dan tool kontrol
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // Mini-Map di Pojok Kiri Bawah
                  _buildMiniMapWidget(),

                  // Tombol Kalibrasi Manual & Simulasi
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Chip Info Mode Sensor
                      ListenableBuilder(
                        listenable: _sensorService,
                        builder: (context, _) {
                          final isSim = _sensorService.isSimulationMode;
                          return InkWell(
                            onTap: () => ArManualCalibrationSheet.show(context, _sensorService),
                            borderRadius: BorderRadius.circular(16),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                              decoration: BoxDecoration(
                                color: const Color(0xCC1E222D),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: isSim ? const Color(0xFF00E5FF) : const Color(0xFF00FF88),
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    isSim ? Icons.play_circle_outline : Icons.directions_walk,
                                    size: 14,
                                    color: isSim ? const Color(0xFF00E5FF) : const Color(0xFF00FF88),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    isSim ? 'Simulasi' : 'Langkah: ${_sensorService.stepCount}',
                                    style: const TextStyle(color: Colors.white, fontSize: 11),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                      const SizedBox(height: 8),

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
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Mini-map yang memanfaatkan MapPainter yang sudah ada
  Widget _buildMiniMapWidget() {
    return ListenableBuilder(
      listenable: Listenable.merge([
        widget.controller,
        _sensorService,
      ]),
      builder: (context, _) {
        final layout = widget.controller.layout;
        if (layout == null) return const SizedBox.shrink();

        final mapWidth = _isMiniMapExpanded ? 240.0 : 130.0;
        final mapHeight = _isMiniMapExpanded ? 180.0 : 95.0;
        final scale = _isMiniMapExpanded ? 4.5 : 2.5;

        return GestureDetector(
          onTap: () {
            setState(() {
              _isMiniMapExpanded = !_isMiniMapExpanded;
            });
          },
          child: Container(
            width: mapWidth,
            height: mapHeight,
            decoration: BoxDecoration(
              color: const Color(0xE6161922),
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
                  size: Size(mapWidth, mapHeight),
                  painter: MapPainter(
                    layout: layout,
                    route: widget.controller.currentRoute,
                    targetSlot: widget.controller.targetSlot,
                    userPosition: widget.controller.currentUserPosition,
                    headingDeg: _sensorService.effectiveMapHeading,
                    selectedLobby: widget.controller.selectedLobby,
                    scale: scale,
                  ),
                ),
                Positioned(
                  top: 4,
                  right: 4,
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Icon(
                      _isMiniMapExpanded ? Icons.close_fullscreen : Icons.open_in_full,
                      color: Colors.white70,
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
}

/// Painter grid lantai perspektif untuk mode simulasi visual tanpa kamera
class _CyberFloorPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final horizonY = size.height * 0.45;
    final gridPaint = Paint()
      ..color = const Color(0x1F00E5FF)
      ..strokeWidth = 1.0;

    // Garis horizontal berjarak perspektif
    double y = horizonY + 20;
    double step = 8;
    while (y < size.height) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
      y += step;
      step *= 1.25;
    }

    // Garis vertikal memancar dari titik lenyap
    final vanishingPoint = Offset(size.width / 2, horizonY);
    for (double x = -size.width * 0.5; x <= size.width * 1.5; x += size.width / 8) {
      canvas.drawLine(vanishingPoint, Offset(x, size.height), gridPaint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
