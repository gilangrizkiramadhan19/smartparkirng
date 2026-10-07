import 'package:flutter/material.dart';
import '../models/parking_models.dart';
import '../services/navigation_controller.dart';
import '../widgets/map_painter.dart';

class MapPage extends StatefulWidget {
  final NavigationController controller;

  const MapPage({super.key, required this.controller});

  @override
  State<MapPage> createState() => _MapPageState();
}

class _MapPageState extends State<MapPage> {
  final TransformationController _transformationController =
      TransformationController();
  final double _scaleFactor = 18.0; // 1 meter = 18 pixels

  @override
  void dispose() {
    _transformationController.dispose();
    super.dispose();
  }

  void _handleTapOnMap(TapUpDetails details) {
    final layout = widget.controller.layout;
    if (layout == null) return;

    // Koordinat tap relatif ke canvas denah dalam satuan meter
    final tapX = details.localPosition.dx / _scaleFactor;
    final tapY = details.localPosition.dy / _scaleFactor;

    // Cari slot yang ditekan pengguna
    for (var slot in layout.slots) {
      final halfW = slot.width / 2;
      final halfH = slot.height / 2;
      if (tapX >= (slot.x - halfW) &&
          tapX <= (slot.x + halfW) &&
          tapY >= (slot.y - halfH) &&
          tapY <= (slot.y + halfH)) {
        _showSlotDetailModal(slot);
        return;
      }
    }
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
            Text('Data AR Unity (JSON)', style: TextStyle(color: Colors.white, fontSize: 16)),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Data berikut dikirim dari Flutter ke Unity melalui flutter_unity_widget untuk merender panah 3D di lantai:',
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
                  Text('Memuat denah parkir...', style: TextStyle(color: Colors.white70)),
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
                    const Icon(Icons.error_outline, color: Colors.redAccent, size: 48),
                    const SizedBox(height: 12),
                    Text(ctrl.errorMessage!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white)),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: ctrl.initialize,
                      child: const Text('Coba Lagi'),
                    ),
                  ],
                ),
              ),
            ),
          );
        }

        final layout = ctrl.layout!;
        final mapWidth = layout.width * _scaleFactor;
        final mapHeight = layout.height * _scaleFactor;

        return Scaffold(
          backgroundColor: const Color(0xFF12141A),
          appBar: AppBar(
            backgroundColor: const Color(0xFF161922),
            elevation: 0,
            title: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Smart Indoor Parking',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
                ),
                Text(
                  'Sistem Navigasi & Dynamic Rerouting',
                  style: TextStyle(fontSize: 11, color: Colors.white60),
                ),
              ],
            ),
            actions: [
              // Badge status ketersediaan slot
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
                        '${ctrl.availableSlotsCount}/${ctrl.totalSlotsCount} Kosong',
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
                child: InteractiveViewer(
                  transformationController: _transformationController,
                  minScale: 0.4,
                  maxScale: 3.5,
                  boundaryMargin: const EdgeInsets.all(200),
                  constrained: false,
                  child: GestureDetector(
                    onTapUp: _handleTapOnMap,
                    child: SizedBox(
                      width: mapWidth,
                      height: mapHeight,
                      child: CustomPaint(
                        size: Size(mapWidth, mapHeight),
                        painter: MapPainter(
                          layout: layout,
                          route: ctrl.currentRoute,
                          targetSlot: ctrl.targetSlot,
                          userPosition: ctrl.currentUserPosition,
                          selectedLobby: ctrl.selectedLobby,
                          scale: _scaleFactor,
                        ),
                      ),
                    ),
                  ),
                ),
              ),

              // 2. Banner Notifikasi / Dynamic Rerouting Alert
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

              // 3. Pilihan Lobby Masuk (di pojok kiri atas bawah banner)
              Positioned(
                top: ctrl.statusBanner != null ? 70 : 16,
                left: 16,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E222D).withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.white24),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.meeting_room, color: Color(0xFFB388FF), size: 16),
                      const SizedBox(width: 6),
                      DropdownButton<String>(
                        value: ctrl.selectedLobby?.id,
                        dropdownColor: const Color(0xFF1E222D),
                        underline: const SizedBox(),
                        isDense: true,
                        style: const TextStyle(color: Colors.white, fontSize: 12),
                        icon: const Icon(Icons.arrow_drop_down, color: Colors.white70),
                        items: layout.lobbies.map((lobby) {
                          return DropdownMenuItem<String>(
                            value: lobby.id,
                            child: Text(lobby.name),
                          );
                        }).toList(),
                        onChanged: ctrl.isNavigating
                            ? null
                            : (lobbyId) {
                                if (lobbyId == null) return;
                                final lobby = layout.lobbies.firstWhere((l) => l.id == lobbyId);
                                ctrl.selectLobby(lobby);
                              },
                      ),
                    ],
                  ),
                ),
              ),

              // 4. Floating Action Button: AR Unity Payload Preview
              Positioned(
                top: ctrl.statusBanner != null ? 70 : 16,
                right: 16,
                child: FloatingActionButton.small(
                  heroTag: 'ar_btn',
                  backgroundColor: const Color(0xFF1E222D),
                  foregroundColor: const Color(0xFF00E5FF),
                  tooltip: 'Lihat Payload AR Unity',
                  onPressed: _showArJsonPayloadDialog,
                  child: const Icon(Icons.view_in_ar),
                ),
              ),

              // 5. Panel Navigasi & Kontrol Bawah
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

  Widget _buildBottomControlPanel(NavigationController ctrl) {
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
            // Info Slot Tujuan & Jarak
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: ctrl.targetSlot != null
                            ? const Color(0x33FFAB00)
                            : const Color(0x3300E5FF),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        ctrl.isNavigating ? Icons.navigation : Icons.local_parking,
                        color: ctrl.targetSlot != null
                            ? const Color(0xFFFFD600)
                            : const Color(0xFF00E5FF),
                        size: 24,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          ctrl.targetSlot != null
                              ? 'Slot Tujuan: ${ctrl.targetSlot!.id}'
                              : 'Belum memilih slot',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          ctrl.targetSlot != null
                              ? 'Jarak: ${ctrl.currentRouteDistance.toStringAsFixed(1)} m • ~${(ctrl.currentRouteDistance / 1.2).round()} dtk'
                              : 'Ketuk slot di denah atau klik Rute Otomatis',
                          style: const TextStyle(color: Colors.white60, fontSize: 12),
                        ),
                      ],
                    ),
                  ],
                ),
                if (ctrl.isNavigating)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
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

            const SizedBox(height: 16),

            // Tombol Aksi Navigasi
            if (!ctrl.isNavigating) ...[
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF00E5FF),
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: () => ctrl.startNavigation(),
                      icon: const Icon(Icons.route, size: 20),
                      label: const Text(
                        'Rute Terdekat (A*)',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                      ),
                    ),
                  ),
                ],
              ),
            ] else ...[
              // Sedang Berjalan: Tombol Simulasi Dynamic Rerouting & Tombol Stop
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFFFF5252),
                        side: const BorderSide(color: Color(0xFFFF5252)),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: ctrl.stopNavigation,
                      icon: const Icon(Icons.stop, size: 18),
                      label: const Text('Berhenti', style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFFFAB00),
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: ctrl.simulateTargetOccupied,
                      icon: const Icon(Icons.bolt, size: 18),
                      label: const Text(
                        'Simulasi: Slot Terisi',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                      ),
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
