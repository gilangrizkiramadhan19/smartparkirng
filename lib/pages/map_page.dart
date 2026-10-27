import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../models/map_data.dart';
import '../models/parking_models.dart';
import '../services/ar_sensor_service.dart';
import '../services/navigation_controller.dart';
import '../widgets/ar_qr_scanner_sheet.dart';
import '../widgets/destination_picker_sheet.dart';
import '../widgets/map_painter.dart';
import 'ar_page.dart';

class MapPage extends StatefulWidget {
  final NavigationController controller;

  const MapPage({super.key, required this.controller});

  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> {
  final TransformationController _transformationController =
      TransformationController();
  late final ARSensorService _sensorService;
  final double _scaleFactor = 18.0; // 1 meter = 18 pixels
  double _currentZoom = 1.0;
  Size _viewportSize = Size.zero;
  bool _hasInitialFitted = false;

  @override
  void initState() {
    super.initState();
    _sensorService = ARSensorService(controller: widget.controller);
    _transformationController.addListener(_onTransformationChanged);
  }

  void _onTransformationChanged() {
    final scale = _transformationController.value.getMaxScaleOnAxis();
    if ((scale - _currentZoom).abs() > 0.05) {
      setState(() {
        _currentZoom = scale;
      });
    }
  }

  @override
  void dispose() {
    _transformationController.removeListener(_onTransformationChanged);
    _sensorService.dispose();
    _transformationController.dispose();
    super.dispose();
  }

  void _handleTapOnMap(TapUpDetails details) {
    final layout = widget.controller.layout;
    if (layout == null) return;

    final tapX = details.localPosition.dx / _scaleFactor;
    final tapY = details.localPosition.dy / _scaleFactor;

    // 1. Cek apakah pengguna mengetuk salah satu node bernama (ruangan, toilet, entrance, dll)
    final nodes = widget.controller.currentFloor?.nodes ?? [];
    for (var node in nodes) {
      if (node.type == NodeType.junction) continue;
      final dist = (Offset(node.x, node.y) - Offset(tapX, tapY)).distance;
      if (dist < 1.2) {
        widget.controller.selectDestination(node);
        return;
      }
    }

    // 2. Cek apakah mengetuk slot parkir (jika ada)
    for (var slot in layout.slots) {
      final halfW = slot.width / 2;
      final halfH = slot.height / 2;
      if (tapX >= (slot.x - halfW) &&
          tapX <= (slot.x + halfW) &&
          tapY >= (slot.y - halfH) &&
          tapY <= (slot.y + halfH)) {
        if (!widget.controller.isNavigating) {
          _showSlotDetailModal(slot);
        }
        return;
      }
    }

    // 3. Tap untuk memindahkan posisi hanya aktif di debug mode jika simulasi dinyalakan
    if (kDebugMode &&
        widget.controller.isNavigating &&
        widget.controller.positionMode == NavigationPositionMode.simulation) {
      widget.controller.setManualPosition(Offset(tapX, tapY));
    }
  }

  void _centerOnUserPosition() {
    final pos = widget.controller.currentUserPosition;
    if (pos == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Posisi Anda belum diketahui. Pindai QR terlebih dahulu.'),
          duration: Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final targetX = pos.x * _scaleFactor;
    final targetY = pos.y * _scaleFactor;
    final zoom = _currentZoom.clamp(1.5, 3.5);
    final vw = _viewportSize.width > 0 ? _viewportSize.width : MediaQuery.of(context).size.width;
    final vh = _viewportSize.height > 0 ? _viewportSize.height : MediaQuery.of(context).size.height;

    // Geser kamera sehingga posisi user pas di tengah layar (dengan kompensasi panel bawah)
    final tx = (vw / 2) - (targetX * zoom);
    final ty = ((vh - 180) / 2) - (targetY * zoom);

    _transformationController.value = Matrix4.translationValues(tx, ty, 0.0)
      ..scaleByDouble(zoom, zoom, 1.0, 1.0);
  }

  void _fitMapToScreen() {
    final layout = widget.controller.layout;
    if (layout == null) return;
    final floorWidth = widget.controller.currentFloor?.width ?? layout.width;
    final floorHeight = widget.controller.currentFloor?.length ?? layout.height;
    final mapWidth = floorWidth * _scaleFactor;
    final mapHeight = floorHeight * _scaleFactor;
    if (mapWidth <= 0 || mapHeight <= 0) return;

    final vw = _viewportSize.width > 0 ? _viewportSize.width : MediaQuery.of(context).size.width;
    final vh = _viewportSize.height > 0 ? _viewportSize.height : MediaQuery.of(context).size.height;

    final availW = vw - 32;
    final availH = vh - 220; // Ruang vertikal di atas panel kontrol bawah
    if (availW <= 0 || availH <= 0) return;

    final scaleX = availW / mapWidth;
    final scaleY = availH / mapHeight;
    final fitScale = math.min(scaleX, scaleY).clamp(0.5, 2.5);

    final tx = (vw - mapWidth * fitScale) / 2;
    final ty = math.max(16.0, (availH - mapHeight * fitScale) / 2 + 16.0);

    _transformationController.value = Matrix4.translationValues(tx, ty, 0.0)
      ..scaleByDouble(fitScale, fitScale, 1.0, 1.0);
  }

  void _zoomTo(double newScale) {
    final vw = _viewportSize.width > 0 ? _viewportSize.width : MediaQuery.of(context).size.width;
    final vh = _viewportSize.height > 0 ? _viewportSize.height : MediaQuery.of(context).size.height;
    final cx = vw / 2;
    final cy = vh / 2;
    final oldMatrix = _transformationController.value;
    final currentScale = oldMatrix.getMaxScaleOnAxis();
    if (currentScale == 0) return;
    final factor = newScale / currentScale;

    final translation = oldMatrix.getTranslation();
    final newTx = cx - (cx - translation.x) * factor;
    final newTy = cy - (cy - translation.y) * factor;

    _transformationController.value = Matrix4.translationValues(newTx, newTy, 0.0)
      ..scaleByDouble(newScale, newScale, 1.0, 1.0);
  }

  void _showSlotDetailModal(ParkingSlot slot) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E222D),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Slot Parkir ${slot.id}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: slot.isAvailable
                          ? const Color(0x3300E676)
                          : const Color(0x33FF1744),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: slot.isAvailable
                            ? const Color(0xFF00E676)
                            : const Color(0xFFFF1744),
                      ),
                    ),
                    child: Text(
                      slot.isAvailable ? 'Tersedia' : 'Terisi',
                      style: TextStyle(
                        color: slot.isAvailable
                            ? const Color(0xFF00E676)
                            : const Color(0xFFFF5252),
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'Posisi: (${slot.x.toStringAsFixed(1)}m, ${slot.y.toStringAsFixed(1)}m) • Akses Masuk: ${slot.entryNodeId}',
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white70,
                        side: const BorderSide(color: Colors.white24),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      onPressed: () {
                        widget.controller.simulateToggleSlot(slot.id);
                        Navigator.pop(ctx);
                      },
                      icon: const Icon(Icons.sync_alt, size: 18),
                      label: Text(
                        slot.isAvailable ? 'Jadikan Terisi' : 'Jadikan Kosong',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF00E5FF),
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      onPressed: slot.isAvailable
                          ? () {
                              Navigator.pop(ctx);
                              widget.controller.selectTargetSlot(slot);
                              widget.controller.startNavigation(destination: slot);
                            }
                          : null,
                      icon: const Icon(Icons.navigation, size: 18),
                      label: const Text('Navigasi ke Sini',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  void _showArJsonPayloadDialog() {
    final jsonString = widget.controller.routeJsonForUnity();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E222D),
        title: const Row(
          children: [
            Icon(Icons.view_in_ar, color: Color(0xFF00E5FF)),
            SizedBox(width: 8),
            Text('Data AR (JSON Payload)', style: TextStyle(color: Colors.white, fontSize: 16)),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Data koordinat rute 3D siap integrasi AR:',
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF12141A),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.white12),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    jsonString,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: Color(0xFF00E676),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Tutup', style: TextStyle(color: Color(0xFF00E5FF))),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final ctrl = widget.controller;

        if (ctrl.isLoading) {
          return const Scaffold(
            backgroundColor: Color(0xFF12141A),
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: Color(0xFF00E5FF)),
                  SizedBox(height: 16),
                  Text('Memuat denah...', style: TextStyle(color: Colors.white70)),
                ],
              ),
            ),
          );
        }

        if (ctrl.errorMessage != null) {
          return Scaffold(
            backgroundColor: const Color(0xFF12141A),
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline, color: Colors.redAccent, size: 56),
                    const SizedBox(height: 16),
                    const Text(
                      'Gagal Memvalidasi Denah',
                      style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      ctrl.errorMessage!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                    const SizedBox(height: 20),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF00E5FF),
                        foregroundColor: Colors.black,
                      ),
                      onPressed: ctrl.initialize,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Coba Lagi', style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
              ),
            ),
          );
        }

        final layout = ctrl.layout!;
        final floorWidth = ctrl.currentFloor?.width ?? layout.width;
        final floorHeight = ctrl.currentFloor?.length ?? layout.height;
        final mapWidth = floorWidth * _scaleFactor;
        final mapHeight = floorHeight * _scaleFactor;

        return Scaffold(
          backgroundColor: const Color(0xFF12141A),
          appBar: AppBar(
            backgroundColor: const Color(0xFF161922),
            elevation: 0,
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Smart Indoor Navigation',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: Colors.white),
                ),
                Text(
                  ctrl.currentFloor?.name ?? 'Denah Gedung',
                  style: const TextStyle(fontSize: 11, color: Color(0xFF00E5FF)),
                ),
              ],
            ),
            actions: [
              // Pemilih Lantai jika multi-lantai
              if (ctrl.isMultiFloor) ...[
                DropdownButton<int>(
                  value: ctrl.selectedFloorIndex,
                  dropdownColor: const Color(0xFF1E222D),
                  underline: const SizedBox(),
                  icon: const Icon(Icons.layers, color: Color(0xFF00E5FF), size: 18),
                  items: List.generate(ctrl.mapData!.floors.length, (i) {
                    return DropdownMenuItem<int>(
                      value: i,
                      child: Text(
                        ctrl.mapData!.floors[i].name,
                        style: const TextStyle(color: Colors.white, fontSize: 12),
                      ),
                    );
                  }),
                  onChanged: (idx) {
                    if (idx != null) ctrl.selectFloor(idx);
                  },
                ),
                const SizedBox(width: 8),
              ],

              // Badge ketersediaan slot (hanya bila ada node slot)
              if (ctrl.hasSlots)
                Center(
                  child: Container(
                    margin: const EdgeInsets.only(right: 12),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF232733),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: ctrl.availableSlotsCount > 0
                                ? const Color(0xFF00E676)
                                : const Color(0xFFFF1744),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '${ctrl.availableSlotsCount}/${ctrl.totalSlotsCount} Slot',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          body: Stack(
            children: [
              // 1. Kanvas Peta Interaktif (Pinch-to-zoom & Pan)
              Positioned.fill(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    _viewportSize = Size(constraints.maxWidth, constraints.maxHeight);
                    if (!_hasInitialFitted && mapWidth > 0 && mapHeight > 0) {
                      _hasInitialFitted = true;
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        _fitMapToScreen();
                      });
                    }
                    return InteractiveViewer(
                      transformationController: _transformationController,
                      minScale: 0.5,
                      maxScale: 6.0,
                      boundaryMargin: const EdgeInsets.all(400),
                      constrained: false,
                      panEnabled: true,
                      scaleEnabled: true,
                      child: GestureDetector(
                        onTapUp: _handleTapOnMap,
                        child: SizedBox(
                          width: mapWidth,
                          height: mapHeight,
                          child: ListenableBuilder(
                            listenable: Listenable.merge([
                              ctrl.userPositionNotifier,
                              ctrl.userHeadingNotifier,
                              ctrl.currentRouteNotifier,
                            ]),
                            builder: (context, _) {
                              return CustomPaint(
                                size: Size(mapWidth, mapHeight),
                                painter: MapPainter(
                                  layout: layout,
                                  floor: ctrl.currentFloor,
                                  route: ctrl.currentRouteNotifier.value,
                                  targetSlot: ctrl.targetSlot,
                                  targetDestination: ctrl.targetDestination,
                                  userPosition: ctrl.userPositionNotifier.value,
                                  headingDeg: ctrl.userHeadingNotifier.value,
                                  selectedLobby: ctrl.selectedLobby,
                                  scale: _scaleFactor,
                                  zoomScale: _currentZoom,
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),

              // 2. Banner Notifikasi
              if (ctrl.statusBanner != null)
                Positioned(
                  top: 12,
                  left: 16,
                  right: 16,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: ctrl.isRerouting
                          ? const Color(0xFFFFAB00)
                          : const Color(0xFF1E222D),
                      borderRadius: BorderRadius.circular(10),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.4),
                          blurRadius: 8,
                          offset: const Offset(0, 4),
                        ),
                      ],
                      border: Border.all(
                        color: ctrl.isRerouting
                            ? const Color(0xFFFFD600)
                            : const Color(0xFF00E5FF).withValues(alpha: 0.4),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          ctrl.isRerouting
                              ? Icons.warning_amber_rounded
                              : Icons.info_outline,
                          color: ctrl.isRerouting ? Colors.black87 : const Color(0xFF00E5FF),
                          size: 20,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            ctrl.statusBanner!,
                            style: TextStyle(
                              color: ctrl.isRerouting ? Colors.black87 : Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        GestureDetector(
                          onTap: ctrl.clearBanner,
                          child: Icon(
                            Icons.close,
                            size: 16,
                            color: ctrl.isRerouting ? Colors.black54 : Colors.white54,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

              // 3. Tombol Aksi Cepat Mengambang: AR, QR, Pusatkan, Muat Semua
              Positioned(
                top: ctrl.statusBanner != null ? 70 : 16,
                right: 16,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    GestureDetector(
                      onLongPress: _showArJsonPayloadDialog,
                      child: FloatingActionButton.extended(
                        heroTag: 'map_ar_btn',
                        backgroundColor: const Color(0xFF1E222D),
                        foregroundColor: const Color(0xFF00FF88),
                        tooltip: 'Buka Kamera Navigasi AR Fullscreen (Tahan untuk Payload JSON)',
                        icon: const Icon(Icons.view_in_ar),
                        label: const Text(
                          'Kamera AR',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                        ),
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => ArPage(controller: widget.controller),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 10),
                    FloatingActionButton.small(
                      heroTag: 'map_qr_btn',
                      backgroundColor: const Color(0xFF1E222D),
                      foregroundColor: const Color(0xFF00E5FF),
                      tooltip: 'Scan QR Lokasi Awal',
                      onPressed: () => ArQrScannerSheet.show(context, _sensorService),
                      child: const Icon(Icons.qr_code_scanner),
                    ),
                    const SizedBox(height: 10),
                    FloatingActionButton.small(
                      heroTag: 'map_center_user_btn',
                      backgroundColor: const Color(0xFF1E222D),
                      foregroundColor: const Color(0xFF00E5FF),
                      tooltip: 'Pusatkan ke posisi saya',
                      onPressed: _centerOnUserPosition,
                      child: const Icon(Icons.my_location),
                    ),
                    const SizedBox(height: 10),
                    FloatingActionButton.small(
                      heroTag: 'map_fit_screen_btn',
                      backgroundColor: const Color(0xFF1E222D),
                      foregroundColor: Colors.white,
                      tooltip: 'Muat semua denah',
                      onPressed: _fitMapToScreen,
                      child: const Icon(Icons.fit_screen),
                    ),
                    const SizedBox(height: 10),
                    Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E222D),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.add, color: Colors.white, size: 20),
                            tooltip: 'Perbesar Denah',
                            onPressed: () {
                              final newZoom = (_currentZoom * 1.3).clamp(0.5, 6.0);
                              _zoomTo(newZoom);
                            },
                          ),
                          Container(
                            height: 1,
                            width: 24,
                            color: Colors.white12,
                          ),
                          IconButton(
                            icon: const Icon(Icons.remove, color: Colors.white, size: 20),
                            tooltip: 'Perkecil Denah',
                            onPressed: () {
                              final newZoom = (_currentZoom / 1.3).clamp(0.5, 6.0);
                              _zoomTo(newZoom);
                            },
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              // 4. Panel Navigasi & Kontrol Bawah
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: _buildBottomControlPanel(ctrl),
              ),
            ],
          ),
        );
      },
    );
  }

  IconData _getTurnIcon(String instruction) {
    final lower = instruction.toLowerCase();
    if (lower.contains('kiri')) return Icons.turn_left;
    if (lower.contains('kanan')) return Icons.turn_right;
    if (lower.contains('putar')) return Icons.u_turn_left;
    if (lower.contains('tiba')) return Icons.check_circle_outline;
    if (lower.contains('mendekati')) return Icons.near_me;
    return Icons.straight;
  }

  Widget _buildBottomControlPanel(NavigationController ctrl) {
    // 1. Tentukan Nama & Koordinat TITIK AWAL ("Dari")
    String startName;
    String startCoord;
    if (ctrl.startNode != null) {
      startName = ctrl.startNode!.name;
      startCoord = '(${ctrl.startNode!.x.toStringAsFixed(1)}m, ${ctrl.startNode!.y.toStringAsFixed(1)}m)';
    } else if (ctrl.currentUserPosition != null) {
      final userPos = ctrl.currentUserPosition!;
      final matchedNode = ctrl.currentFloor?.nodes.cast<MapNode?>().firstWhere(
        (n) => n != null && (Offset(n.x, n.y) - Offset(userPos.x, userPos.y)).distance < 0.3,
        orElse: () => null,
      );
      startName = matchedNode?.name ?? (ctrl.selectedLobby?.name ?? 'Posisi Anda');
      startCoord = '(${userPos.x.toStringAsFixed(1)}m, ${userPos.y.toStringAsFixed(1)}m)';
    } else {
      startName = 'Belum ditentukan';
      startCoord = 'Pindai QR / Pilih Titik Awal';
    }

    // 2. Tentukan Nama & Koordinat TITIK TUJUAN ("Ke")
    String destName;
    String destCoord;
    final hasDestination = ctrl.targetDestination != null || ctrl.targetSlot != null;
    if (ctrl.targetDestination != null) {
      destName = ctrl.targetDestination!.name;
      destCoord = '(${ctrl.targetDestination!.x.toStringAsFixed(1)}m, ${ctrl.targetDestination!.y.toStringAsFixed(1)}m)';
    } else if (ctrl.targetSlot != null) {
      destName = 'Slot Parkir ${ctrl.targetSlot!.id}';
      destCoord = '(${ctrl.targetSlot!.x.toStringAsFixed(1)}m, ${ctrl.targetSlot!.y.toStringAsFixed(1)}m)';
    } else {
      destName = 'Pilih Tujuan Navigasi';
      destCoord = '-';
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E222D),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.5),
            blurRadius: 12,
            offset: const Offset(0, -4),
          ),
        ],
        border: Border.all(color: Colors.white12),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Panel Kartu DARI dan KE dengan tombol Tukar
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFF161922),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white12),
              ),
              child: Column(
                children: [
                  // Baris DARI
                  InkWell(
                    onTap: !ctrl.isNavigating
                        ? () => DestinationPickerSheet.show(context, ctrl, isSelectingStart: true)
                        : null,
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2.0),
                      child: Row(
                        children: [
                          Container(
                            width: 26,
                            height: 26,
                            decoration: BoxDecoration(
                              color: const Color(0x3300E676),
                              shape: BoxShape.circle,
                              border: Border.all(color: const Color(0xFF00E676), width: 1.5),
                            ),
                            child: const Center(
                              child: Icon(Icons.trip_origin, size: 14, color: Color(0xFF00E676)),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    const Text(
                                      'Dari: ',
                                      style: TextStyle(color: Colors.white54, fontSize: 11, fontWeight: FontWeight.bold),
                                    ),
                                    Expanded(
                                      child: Text(
                                        startName,
                                        style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                                Text(
                                  'Koordinat: $startCoord',
                                  style: const TextStyle(color: Color(0xFF00E676), fontSize: 11, fontFamily: 'monospace'),
                                ),
                              ],
                            ),
                          ),
                          if (!ctrl.isNavigating)
                            const Icon(Icons.edit_location_alt_outlined, color: Colors.white38, size: 18),
                        ],
                      ),
                    ),
                  ),

                  // Divider dengan tombol Tukar (Swap)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Row(
                      children: [
                        const SizedBox(width: 12),
                        Container(width: 2, height: 16, color: Colors.white24),
                        const SizedBox(width: 14),
                        Expanded(child: Container(height: 1, color: Colors.white10)),
                        if (!ctrl.isNavigating && ctrl.targetDestination != null && ctrl.startNode != null) ...[
                          InkWell(
                            onTap: () => ctrl.swapStartAndDestination(),
                            borderRadius: BorderRadius.circular(12),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: const Color(0xFF232733),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: Colors.white24),
                              ),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.swap_vert, size: 14, color: Color(0xFF00E5FF)),
                                  SizedBox(width: 2),
                                  Text(
                                    'Tukar',
                                    style: TextStyle(color: Color(0xFF00E5FF), fontSize: 10, fontWeight: FontWeight.bold),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),

                  // Baris KE
                  InkWell(
                    onTap: !ctrl.isNavigating
                        ? () => DestinationPickerSheet.show(context, ctrl, isSelectingStart: false)
                        : null,
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2.0),
                      child: Row(
                        children: [
                          Container(
                            width: 26,
                            height: 26,
                            decoration: BoxDecoration(
                              color: const Color(0x33FFAB00),
                              shape: BoxShape.circle,
                              border: Border.all(color: const Color(0xFFFFAB00), width: 1.5),
                            ),
                            child: const Center(
                              child: Icon(Icons.location_on, size: 15, color: Color(0xFFFFD600)),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    const Text(
                                      'Ke: ',
                                      style: TextStyle(color: Colors.white54, fontSize: 11, fontWeight: FontWeight.bold),
                                    ),
                                    Expanded(
                                      child: Text(
                                        destName,
                                        style: TextStyle(
                                          color: hasDestination ? Colors.white : Colors.white38,
                                          fontSize: 13,
                                          fontWeight: FontWeight.bold,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                                Text(
                                  'Koordinat: $destCoord',
                                  style: TextStyle(
                                    color: hasDestination ? const Color(0xFFFFD600) : Colors.white38,
                                    fontSize: 11,
                                    fontFamily: 'monospace',
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (!ctrl.isNavigating)
                            const Icon(Icons.search, color: Color(0xFF00E5FF), size: 18),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 12),

            // Info Jarak Rute & Turn-by-Turn Instruction
            ListenableBuilder(
              listenable: Listenable.merge([
                ctrl.routeDistanceNotifier,
                ctrl.turnInstructionNotifier,
              ]),
              builder: (context, _) {
                final dist = ctrl.routeDistanceNotifier.value;
                final instruction = ctrl.turnInstructionNotifier.value;

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (dist > 0 || ctrl.isNavigating) ...[
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.directions_walk, color: Color(0xFF00E5FF), size: 18),
                              const SizedBox(width: 6),
                              Text(
                                'Jarak: ${dist.toStringAsFixed(1)} m • ~${(dist / 1.2).round()} dtk',
                                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                              ),
                            ],
                          ),
                          if (ctrl.isNavigating)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                              decoration: BoxDecoration(
                                color: const Color(0x3300E676),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: const Color(0xFF00E676)),
                              ),
                              child: const Text(
                                'Navigasi Aktif',
                                style: TextStyle(
                                  color: Color(0xFF00E676),
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                    if (instruction.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: const Color(0xFF141822),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0xFF00E5FF).withValues(alpha: 0.3)),
                        ),
                        child: Row(
                          children: [
                            Icon(_getTurnIcon(instruction), color: const Color(0xFF00E5FF), size: 18),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                instruction,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                );
              },
            ),

            const SizedBox(height: 12),

            // Baris Tombol Aksi
            if (!ctrl.isNavigating) ...[
              Row(
                children: [
                  // Jika tujuan sudah dipilih -> Tombol Utama "Mulai Navigasi"
                  if (hasDestination) ...[
                    Expanded(
                      flex: 3,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF00E5FF),
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: () {
                          if (ctrl.targetDestination != null) {
                            ctrl.startRouteNavigation();
                          } else {
                            ctrl.startNavigation();
                          }
                        },
                        icon: const Icon(Icons.navigation, size: 20),
                        label: const Text(
                          'Mulai Navigasi',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ] else ...[
                    // Jika belum memilih tujuan -> Tombol Utama "Pilih Tujuan"
                    Expanded(
                      flex: 3,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF00E5FF),
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: () => DestinationPickerSheet.show(context, ctrl),
                        icon: const Icon(Icons.search, size: 20),
                        label: const Text(
                          'Pilih Tujuan',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],

                  // Tombol Toilet jika ada toilet
                  if (ctrl.hasToilets) ...[
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFA855F7),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: () => ctrl.findNearestToilet(),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.wc, size: 18),
                          SizedBox(width: 4),
                          Text('Toilet', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],

                  // Tombol Cari Slot Parkir jika ada slot
                  if (ctrl.hasSlots) ...[
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF00E676),
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: () => ctrl.startNavigation(),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.local_parking, size: 18),
                          SizedBox(width: 4),
                          Text('Slot', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],

                  // Tombol AR
                  Expanded(
                    flex: 2,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF00FF88),
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ArPage(controller: widget.controller),
                          ),
                        );
                      },
                      icon: const Icon(Icons.view_in_ar, size: 18),
                      label: const Text(
                        'AR',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                    ),
                  ),
                ],
              ),
            ] else ...[
              // Tombol kontrol saat navigasi aktif
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFFFF5252),
                        side: const BorderSide(color: Color(0xFFFF5252)),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: () => ctrl.stopNavigation(),
                      icon: const Icon(Icons.stop, size: 20),
                      label: const Text('Hentikan Navigasi', style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF00FF88),
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ArPage(controller: widget.controller),
                          ),
                        );
                      },
                      icon: const Icon(Icons.view_in_ar, size: 20),
                      label: const Text('Buka AR', style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

