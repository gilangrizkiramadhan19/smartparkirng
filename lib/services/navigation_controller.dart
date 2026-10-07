import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../models/parking_models.dart';
import 'a_star.dart';
import 'parking_repository.dart';

/// Controller state management untuk navigasi, pemilihan slot, dan dynamic rerouting.
class NavigationController extends ChangeNotifier {
  final ParkingRepository _repository;
  StreamSubscription<SlotUpdate>? _slotSubscription;

  // State denah & status
  ParkingLayout? _layout;
  bool _isLoading = true;
  String? _errorMessage;

  // State navigasi
  Lobby? _selectedLobby;
  ParkingSlot? _targetSlot;
  List<Node> _currentRoute = [];
  double _currentRouteDistance = 0.0;
  bool _isNavigating = false;
  Node? _currentUserPosition;
  String? _statusBanner;
  bool _isRerouting = false;

  NavigationController({required ParkingRepository repository})
      : _repository = repository {
    initialize();
  }

  // Getters
  ParkingLayout? get layout => _layout;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  Lobby? get selectedLobby => _selectedLobby;
  ParkingSlot? get targetSlot => _targetSlot;
  List<Node> get currentRoute => _currentRoute;
  double get currentRouteDistance => _currentRouteDistance;
  bool get isNavigating => _isNavigating;
  Node? get currentUserPosition => _currentUserPosition;
  String? get statusBanner => _statusBanner;
  bool get isRerouting => _isRerouting;

  int get availableSlotsCount =>
      _layout?.slots.where((s) => s.isAvailable).length ?? 0;
  int get totalSlotsCount => _layout?.slots.length ?? 0;

  /// Inisialisasi awal: mengambil data denah dan mendengarkan stream realtime.
  Future<void> initialize() async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      _layout = await _repository.getLayout();
      if (_layout != null && _layout!.lobbies.isNotEmpty) {
        _selectedLobby = _layout!.lobbies.first;
        _setUserPositionToLobby(_selectedLobby!);
      }

      // Berlangganan stream realtime update slot
      await _slotSubscription?.cancel();
      _slotSubscription = _repository.getSlotUpdates().listen(
        _handleSlotUpdate,
        onError: (err) {
          _statusBanner = 'Koneksi realtime bermasalah: $err';
          notifyListeners();
        },
      );
    } catch (e) {
      _errorMessage = 'Gagal memuat denah parkir: $e';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Memilih lobby masuk pengguna.
  void selectLobby(Lobby lobby) {
    if (_isNavigating) return; // Kunci lobby jika sedang navigasi aktif
    _selectedLobby = lobby;
    _setUserPositionToLobby(lobby);
    _currentRoute = [];
    _currentRouteDistance = 0.0;
    _targetSlot = null;
    _statusBanner = null;
    notifyListeners();
  }

  void _setUserPositionToLobby(Lobby lobby) {
    if (_layout == null) return;
    final entryNode = _layout!.nodes.cast<Node?>().firstWhere(
          (n) => n?.id == lobby.entryNodeId,
          orElse: () => null,
        );
    _currentUserPosition = entryNode ?? Node(id: lobby.entryNodeId, x: lobby.x, y: lobby.y);
  }

  /// Memilih slot tujuan secara manual dari klik peta.
  void selectTargetSlot(ParkingSlot slot) {
    if (_isNavigating) return;
    _targetSlot = slot;
    _calculateRouteToSlot(slot);
    notifyListeners();
  }

  /// Menghitung rute A* ke slot tertentu.
  bool _calculateRouteToSlot(ParkingSlot slot) {
    if (_layout == null || _currentUserPosition == null) return false;

    final path = AStar.findPath(
      nodes: _layout!.nodes,
      edges: _layout!.edges,
      startNodeId: _currentUserPosition!.id,
      targetNodeId: slot.entryNodeId,
    );

    if (path != null && path.isNotEmpty) {
      // Tambahkan titik slot itu sendiri di akhir polyline agar rute menunjuk langsung ke kotak parkir
      final slotNode = Node(id: 'slot_${slot.id}', x: slot.x, y: slot.y);
      _currentRoute = [...path, slotNode];
      _currentRouteDistance = AStar.calculatePathLength(_currentRoute);
      return true;
    } else {
      _currentRoute = [];
      _currentRouteDistance = 0.0;
      return false;
    }
  }

  /// Memilih slot kosong terbaik (rute terpendek dengan A*).
  ParkingSlot? findBestAvailableSlot() {
    if (_layout == null || _currentUserPosition == null) return null;

    final availableSlots = _layout!.slots.where((s) => s.isAvailable).toList();
    if (availableSlots.isEmpty) return null;

    ParkingSlot? bestSlot;
    double shortestDistance = double.infinity;
    List<Node>? bestPath;

    for (var slot in availableSlots) {
      final path = AStar.findPath(
        nodes: _layout!.nodes,
        edges: _layout!.edges,
        startNodeId: _currentUserPosition!.id,
        targetNodeId: slot.entryNodeId,
      );

      if (path != null) {
        final dist = AStar.calculatePathLength(path);
        if (dist < shortestDistance) {
          shortestDistance = dist;
          bestSlot = slot;
          bestPath = path;
        }
      }
    }

    if (bestSlot != null && bestPath != null) {
      final slotNode = Node(id: 'slot_${bestSlot.id}', x: bestSlot.x, y: bestSlot.y);
      _currentRoute = [...bestPath, slotNode];
      _currentRouteDistance = AStar.calculatePathLength(_currentRoute);
      _targetSlot = bestSlot;
      return bestSlot;
    }

    return null;
  }

  /// Memulai navigasi.
  void startNavigation({ParkingSlot? destination}) {
    if (_layout == null) return;

    final target = destination ?? _targetSlot ?? findBestAvailableSlot();
    if (target == null) {
      _statusBanner = 'Tidak ada slot parkir kosong yang tersedia!';
      notifyListeners();
      return;
    }

    _targetSlot = target;
    final success = _calculateRouteToSlot(target);

    if (success) {
      _isNavigating = true;
      _statusBanner = 'Navigasi aktif ke slot ${target.id} (${_currentRouteDistance.toStringAsFixed(1)}m)';
    } else {
      _statusBanner = 'Gagal menemukan jalur ke slot ${target.id}';
    }
    notifyListeners();
  }

  /// Menghentikan navigasi.
  void stopNavigation() {
    _isNavigating = false;
    _currentRoute = [];
    _currentRouteDistance = 0.0;
    _targetSlot = null;
    _statusBanner = 'Navigasi dihentikan.';
    notifyListeners();
  }

  /// Handler stream update status slot dari server / backend realtime.
  void _handleSlotUpdate(SlotUpdate update) {
    if (_layout == null) return;

    // Perbarui status slot di denah lokal
    final updatedSlots = _layout!.slots.map((s) {
      if (s.id == update.slotId) {
        return s.copyWith(status: update.status);
      }
      return s;
    }).toList();

    _layout = ParkingLayout(
      width: _layout!.width,
      height: _layout!.height,
      lobbies: _layout!.lobbies,
      nodes: _layout!.nodes,
      edges: _layout!.edges,
      slots: updatedSlots,
    );

    // Cek jika slot yang berubah adalah slot tujuan saat sedang bernavigasi
    if (_isNavigating &&
        _targetSlot != null &&
        _targetSlot!.id == update.slotId &&
        update.status != SlotStatus.available) {
      // DYNAMIC REROUTING!
      _triggerDynamicRerouting(previousSlotId: update.slotId);
    } else {
      notifyListeners();
    }
  }

  /// Menjalankan dynamic rerouting otomatis saat slot tujuan terisi.
  void _triggerDynamicRerouting({required String previousSlotId}) {
    _isRerouting = true;
    _statusBanner = '⚠️ Slot $previousSlotId baru saja terisi! Mencari rute alternatif...';
    notifyListeners();

    // Beri jeda animasi 500ms agar user menyadari pergantian
    Timer(const Duration(milliseconds: 500), () {
      final newSlot = findBestAvailableSlot();

      if (newSlot != null) {
        _targetSlot = newSlot;
        _statusBanner = '✅ Rerouting berhasil! Menuju slot ${newSlot.id} (${_currentRouteDistance.toStringAsFixed(1)}m)';
      } else {
        _isNavigating = false;
        _targetSlot = null;
        _currentRoute = [];
        _statusBanner = '❌ Semua slot parkir terisi penuh!';
      }

      _isRerouting = false;
      notifyListeners();
    });
  }

  /// Simulasi tombol: Mengubah status slot tujuan menjadi 'occupied'
  /// untuk menguji fitur dynamic rerouting secara langsung.
  Future<void> simulateTargetOccupied() async {
    if (_targetSlot == null) return;
    await _repository.updateSlotStatus(_targetSlot!.id, SlotStatus.occupied);
  }

  /// Simulasi: Toggle status ketersediaan slot tertentu.
  Future<void> simulateToggleSlot(String slotId) async {
    final slot = _layout?.slots.cast<ParkingSlot?>().firstWhere(
          (s) => s?.id == slotId,
          orElse: () => null,
        );
    if (slot == null) return;

    final newStatus = slot.isAvailable ? SlotStatus.occupied : SlotStatus.available;
    await _repository.updateSlotStatus(slotId, newStatus);
  }

  /// Format data rute JSON siap kirim ke Unity (`flutter_unity_widget`).
  ///
  /// Catatan koordinat Unity (3D):
  /// - X denah -> X Unity (lebar)
  /// - Y denah -> Z Unity (kedalaman lantai)
  /// - Ketinggian lantai Y Unity = 0.0 (menempel di lantai)
  String routeJsonForUnity() {
    if (_currentRoute.isEmpty || _targetSlot == null) {
      return jsonEncode({
        'status': 'idle',
        'points': [],
      });
    }

    final points3D = _currentRoute.map((node) {
      return {
        'id': node.id,
        'x': node.x,
        'y': 0.0, // Ketinggian lantai di Unity
        'z': node.y, // Sumbu Y 2D denah dipetakan ke sumbu Z Unity
      };
    }).toList();

    final payload = {
      'status': 'active',
      'targetSlotId': _targetSlot!.id,
      'totalDistanceMeters': _currentRouteDistance,
      'pointsCount': points3D.length,
      'points': points3D,
    };

    return jsonEncode(payload);
  }

  void clearBanner() {
    _statusBanner = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _slotSubscription?.cancel();
    _repository.dispose();
    super.dispose();
  }
}
