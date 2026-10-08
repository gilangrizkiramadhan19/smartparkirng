import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import '../models/parking_models.dart';
import 'a_star.dart';
import 'graph_snap.dart';
import 'parking_repository.dart';
import 'position_provider.dart';

/// Mode penyedia posisi navigasi.
enum NavigationPositionMode {
  simulation,
  manual,
}

/// Helper internal untuk graf pencarian rute sementara.
class _SearchGraph {
  final ParkingLayout layout;
  final String startNodeId;

  const _SearchGraph(this.layout, this.startNodeId);
}

/// Controller state management untuk navigasi, pemilihan slot, dan dynamic rerouting.
class NavigationController extends ChangeNotifier {
  final ParkingRepository _repository;
  StreamSubscription<SlotUpdate>? _slotSubscription;
  StreamSubscription<UserPosition>? _positionSubscription;

  // Position Provider & Mode
  PositionProvider _positionProvider;
  SimulatedPositionProvider? _simulatedProvider;
  ManualPositionProvider? _manualProvider;
  NavigationPositionMode _positionMode = NavigationPositionMode.simulation;

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
  double? _currentUserHeading;
  String? _statusBanner;
  bool _isRerouting = false;

  // Notifiers terpisah untuk frekuensi tinggi (~10 Hz) agar tidak merebuild seluruh UI
  final ValueNotifier<Node?> userPositionNotifier = ValueNotifier<Node?>(null);
  final ValueNotifier<double?> userHeadingNotifier = ValueNotifier<double?>(null);
  final ValueNotifier<List<Node>> currentRouteNotifier = ValueNotifier<List<Node>>([]);
  final ValueNotifier<double> routeDistanceNotifier = ValueNotifier<double>(0.0);

  NavigationController({
    required ParkingRepository repository,
    PositionProvider? positionProvider,
  })  : _repository = repository,
        _positionProvider = positionProvider ?? SimulatedPositionProvider() {
    _initPositionProvider();
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
  double? get currentUserHeading => _currentUserHeading;
  String? get statusBanner => _statusBanner;
  bool get isRerouting => _isRerouting;
  NavigationPositionMode get positionMode => _positionMode;
  PositionProvider get positionProvider => _positionProvider;

  bool get isSimulationPaused =>
      _positionProvider is SimulatedPositionProvider
          ? (_positionProvider as SimulatedPositionProvider).isPaused
          : false;

  double get simulationSpeed =>
      _positionProvider is SimulatedPositionProvider
          ? (_positionProvider as SimulatedPositionProvider).speed
          : 1.5;

  int get availableSlotsCount =>
      _layout?.slots.where((s) => s.isAvailable).length ?? 0;
  int get totalSlotsCount => _layout?.slots.length ?? 0;

  void _initPositionProvider() {
    if (_positionProvider is SimulatedPositionProvider) {
      _simulatedProvider = _positionProvider as SimulatedPositionProvider;
      _positionMode = NavigationPositionMode.simulation;
    } else if (_positionProvider is ManualPositionProvider) {
      _manualProvider = _positionProvider as ManualPositionProvider;
      _positionMode = NavigationPositionMode.manual;
    }
    _subscribeToPositionProvider();
  }

  void _subscribeToPositionProvider() {
    _positionSubscription?.cancel();
    _positionSubscription = _positionProvider.positions.listen(_handlePositionUpdate);
  }

  /// Beralih mode posisi antara Simulasi dan Manual.
  void setPositionMode(NavigationPositionMode mode) {
    if (_positionMode == mode) return;
    _positionMode = mode;

    _positionSubscription?.cancel();
    _positionProvider.stop();

    final currentOffset = _currentUserPosition != null
        ? Offset(_currentUserPosition!.x, _currentUserPosition!.y)
        : null;

    if (mode == NavigationPositionMode.simulation) {
      _simulatedProvider ??= SimulatedPositionProvider(
        initialPosition: currentOffset,
      );
      _positionProvider = _simulatedProvider!;
      if (_isNavigating && _currentRoute.isNotEmpty) {
        _simulatedProvider!.onRouteChanged(
          _currentRoute.map((n) => Offset(n.x, n.y)).toList(),
        );
        _simulatedProvider!.start();
      }
    } else {
      _manualProvider ??= ManualPositionProvider(
        initialPosition: currentOffset,
      );
      _positionProvider = _manualProvider!;
      if (_isNavigating) {
        _manualProvider!.start();
      }
    }

    _subscribeToPositionProvider();
    notifyListeners();
  }

  /// Mengatur posisi pengguna secara manual pada koordinat denah (satuan meter).
  void setManualPosition(Offset position) {
    if (_manualProvider != null) {
      _manualProvider!.setPosition(position);
    } else if (_positionProvider is ManualPositionProvider) {
      (_positionProvider as ManualPositionProvider).setPosition(position);
    } else {
      _handlePositionUpdate(UserPosition(
        position: position,
        timestamp: DateTime.now(),
      ));
    }
  }

  /// Menjeda jalannya simulasi pergerakan.
  void pauseSimulation() {
    if (_positionProvider is SimulatedPositionProvider) {
      (_positionProvider as SimulatedPositionProvider).pause();
      notifyListeners();
    }
  }

  /// Melanjutkan jalannya simulasi pergerakan.
  void resumeSimulation() {
    if (_positionProvider is SimulatedPositionProvider) {
      (_positionProvider as SimulatedPositionProvider).resume();
      notifyListeners();
    }
  }

  /// Mengatur kecepatan gerak simulasi (m/s).
  void setSimulationSpeed(double speed) {
    if (_positionProvider is SimulatedPositionProvider) {
      (_positionProvider as SimulatedPositionProvider).setSpeed(speed);
      notifyListeners();
    }
  }

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
    currentRouteNotifier.value = [];
    routeDistanceNotifier.value = 0.0;
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
    _currentUserHeading = null;
    userPositionNotifier.value = _currentUserPosition;
    userHeadingNotifier.value = null;
  }

  /// Handler pembaruan posisi pengguna dari [PositionProvider].
  void _handlePositionUpdate(UserPosition update) {
    if (_layout == null) return;

    // 1. Deteksi tiba di slot tujuan (< 1.5 m dari koordinat slot)
    if (_isNavigating && _targetSlot != null) {
      final targetOffset = Offset(_targetSlot!.x, _targetSlot!.y);
      final rawDist = (update.position - targetOffset).distance;
      if (rawDist < 1.5) {
        _isNavigating = false;
        _statusBanner = 'Anda sudah tiba di slot ${_targetSlot!.id}';
        _positionProvider.stop();
        _currentUserPosition = Node(
          id: 'user_pos',
          x: update.position.dx,
          y: update.position.dy,
        );
        userPositionNotifier.value = _currentUserPosition;
        userHeadingNotifier.value = update.headingDeg;
        _currentRoute = [];
        _currentRouteDistance = 0.0;
        currentRouteNotifier.value = [];
        routeDistanceNotifier.value = 0.0;
        notifyListeners();
        return;
      }
    }

    // 2. Snap posisi ke graf jalan
    final snap = snapToGraph(update.position, _layout!.nodes, _layout!.edges);
    if (snap == null || snap.isOffGraph) {
      // Di luar jangkauan graf: abaikan pembaruan
      return;
    }

    final snappedOffset = snap.snappedPosition;
    final snappedNode = Node(
      id: 'user_pos',
      x: snappedOffset.dx,
      y: snappedOffset.dy,
    );

    _currentUserPosition = snappedNode;
    _currentUserHeading = update.headingDeg;
    userPositionNotifier.value = snappedNode;
    userHeadingNotifier.value = update.headingDeg;

    // Cek juga deteksi tiba dari hasil snap (< 1.5 m)
    if (_isNavigating && _targetSlot != null) {
      final targetOffset = Offset(_targetSlot!.x, _targetSlot!.y);
      final snapDist = (snappedOffset - targetOffset).distance;
      if (snapDist < 1.5) {
        _isNavigating = false;
        _statusBanner = 'Anda sudah tiba di slot ${_targetSlot!.id}';
        _positionProvider.stop();
        _currentRoute = [];
        _currentRouteDistance = 0.0;
        currentRouteNotifier.value = [];
        routeDistanceNotifier.value = 0.0;
        notifyListeners();
        return;
      }
    }

    // 3. Pangkas rute sehingga hanya sisa rute di depan pengguna yang tersisa
    if (_isNavigating && _currentRoute.isNotEmpty) {
      _trimRoute(snappedOffset);
    }
  }

  /// Memangkas rute yang sudah dilalui dan menyisakan rute di depan pengguna.
  void _trimRoute(Offset userPos) {
    if (_currentRoute.length < 2) return;

    int bestSegmentIndex = 0;
    double minDistance = double.infinity;
    Offset bestProj = userPos;

    for (int i = 0; i < _currentRoute.length - 1; i++) {
      final a = Offset(_currentRoute[i].x, _currentRoute[i].y);
      final b = Offset(_currentRoute[i + 1].x, _currentRoute[i + 1].y);
      final dx = b.dx - a.dx;
      final dy = b.dy - a.dy;
      final lenSq = dx * dx + dy * dy;

      Offset proj;
      if (lenSq == 0) {
        proj = a;
      } else {
        final t = (((userPos.dx - a.dx) * dx + (userPos.dy - a.dy) * dy) / lenSq).clamp(0.0, 1.0);
        proj = Offset(a.dx + t * dx, a.dy + t * dy);
      }

      final dist = (userPos - proj).distance;
      if (dist < minDistance) {
        minDistance = dist;
        bestSegmentIndex = i;
        bestProj = proj;
      }
    }

    final userNode = Node(id: 'user_pos', x: bestProj.dx, y: bestProj.dy);
    final remainingNodes = _currentRoute.sublist(bestSegmentIndex + 1);

    _currentRoute = [userNode, ...remainingNodes];
    _currentRouteDistance = AStar.calculatePathLength(_currentRoute);
    currentRouteNotifier.value = _currentRoute;
    routeDistanceNotifier.value = _currentRouteDistance;
  }

  /// Membangun salinan graf denah dengan menyisipkan node virtual sementara (`user_virtual`)
  /// pada titik snap pengguna saat ini dan menghubungkannya ke kedua ujung edge.
  _SearchGraph _buildEffectiveSearchGraph() {
    final userPos = _currentUserPosition!;

    // Jika posisi pengguna cocok dengan node asli graf (seperti lobby c_l1 sebelum navigasi)
    final isOriginalNode = _layout!.nodes.any((n) => n.id == userPos.id);
    if (isOriginalNode &&
        !_isNavigating &&
        userPos.id != 'user_pos' &&
        userPos.id != 'user_virtual') {
      return _SearchGraph(_layout!, userPos.id);
    }

    // Jika posisi pengguna berasal dari provider (tengah lorong atau navigasi aktif):
    // Buat node virtual sementara 'user_virtual' pada salinan graf
    final snap = snapToGraph(Offset(userPos.x, userPos.y), _layout!.nodes, _layout!.edges);
    if (snap == null) {
      return _SearchGraph(_layout!, userPos.id);
    }

    final virtualNode = Node(
      id: 'user_virtual',
      x: snap.snappedPosition.dx,
      y: snap.snappedPosition.dy,
    );

    final virtualNodes = List<Node>.from(_layout!.nodes)..add(virtualNode);
    final virtualEdges = List<Edge>.from(_layout!.edges);

    final u = _layout!.nodes.firstWhere((n) => n.id == snap.edge.from);
    final v = _layout!.nodes.firstWhere((n) => n.id == snap.edge.to);

    final distU = AStar.calculateDistance(virtualNode, u);
    final distV = AStar.calculateDistance(virtualNode, v);

    virtualEdges.add(Edge(
      from: 'user_virtual',
      to: u.id,
      weight: distU,
      bidirectional: snap.edge.bidirectional,
    ));
    virtualEdges.add(Edge(
      from: 'user_virtual',
      to: v.id,
      weight: distV,
      bidirectional: snap.edge.bidirectional,
    ));

    final graphCopy = ParkingLayout(
      width: _layout!.width,
      height: _layout!.height,
      lobbies: _layout!.lobbies,
      nodes: virtualNodes,
      edges: virtualEdges,
      slots: _layout!.slots,
    );

    return _SearchGraph(graphCopy, 'user_virtual');
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

    final searchGraph = _buildEffectiveSearchGraph();
    final startId = searchGraph.startNodeId;

    final path = AStar.findPath(
      nodes: searchGraph.layout.nodes,
      edges: searchGraph.layout.edges,
      startNodeId: startId,
      targetNodeId: slot.entryNodeId,
    );

    if (path != null && path.isNotEmpty) {
      // Tambahkan titik slot itu sendiri di akhir polyline agar rute menunjuk langsung ke kotak parkir
      final slotNode = Node(id: 'slot_${slot.id}', x: slot.x, y: slot.y);
      _currentRoute = [...path, slotNode];
      _currentRouteDistance = AStar.calculatePathLength(_currentRoute);
      currentRouteNotifier.value = _currentRoute;
      routeDistanceNotifier.value = _currentRouteDistance;
      return true;
    } else {
      _currentRoute = [];
      _currentRouteDistance = 0.0;
      currentRouteNotifier.value = [];
      routeDistanceNotifier.value = 0.0;
      return false;
    }
  }

  /// Memilih slot kosong terbaik (rute terpendek dengan A*).
  ParkingSlot? findBestAvailableSlot() {
    if (_layout == null || _currentUserPosition == null) return null;

    final availableSlots = _layout!.slots.where((s) => s.isAvailable).toList();
    if (availableSlots.isEmpty) return null;

    final searchGraph = _buildEffectiveSearchGraph();
    final startId = searchGraph.startNodeId;

    ParkingSlot? bestSlot;
    double shortestDistance = double.infinity;
    List<Node>? bestRoute;

    debugPrint('=== [Evaluasi Kandidat Slot Parkir] ===');
    debugPrint(
        'Titik awal: $startId (${_currentUserPosition!.x}, ${_currentUserPosition!.y})');

    for (var slot in availableSlots) {
      final path = AStar.findPath(
        nodes: searchGraph.layout.nodes,
        edges: searchGraph.layout.edges,
        startNodeId: startId,
        targetNodeId: slot.entryNodeId,
      );

      if (path != null && path.isNotEmpty) {
        // Hitung jarak total TERMASUK ruas terakhir ke tengah slot
        final slotNode = Node(id: 'slot_${slot.id}', x: slot.x, y: slot.y);
        final fullRoute = [...path, slotNode];
        final totalDist = AStar.calculatePathLength(fullRoute);

        final traversedNodeIds = fullRoute.map((n) => n.id).toList();
        debugPrint(
            '  [Kandidat] id: ${slot.id}, panjang: ${totalDist.toStringAsFixed(2)}m, node: $traversedNodeIds');

        if (totalDist < shortestDistance) {
          shortestDistance = totalDist;
          bestSlot = slot;
          bestRoute = fullRoute;
        }
      } else {
        debugPrint(
            '  [Kandidat] id: ${slot.id}: tidak ditemukan rute ke entryNode ${slot.entryNodeId}');
      }
    }

    if (bestSlot != null && bestRoute != null) {
      _currentRoute = bestRoute;
      _currentRouteDistance = shortestDistance;
      _targetSlot = bestSlot;
      currentRouteNotifier.value = _currentRoute;
      routeDistanceNotifier.value = _currentRouteDistance;
      debugPrint(
          '>>> Pemenang: Slot ${bestSlot.id} (${shortestDistance.toStringAsFixed(2)}m)');
      return bestSlot;
    }

    return null;
  }

  /// Memulai navigasi.
  void startNavigation({ParkingSlot? destination}) {
    if (_layout == null) return;

    ParkingSlot? target;

    // 1. Cek parameter destination jika diberikan
    if (destination != null) {
      final freshDest = _layout!.slots.cast<ParkingSlot?>().firstWhere(
            (s) => s?.id == destination.id,
            orElse: () => null,
          );
      if (freshDest != null && freshDest.isAvailable) {
        target = freshDest;
      }
    }

    // 2. Jika tidak ada destination, cek apakah target lama masih available
    if (target == null && _targetSlot != null) {
      final freshTarget = _layout!.slots.cast<ParkingSlot?>().firstWhere(
            (s) => s?.id == _targetSlot!.id,
            orElse: () => null,
          );
      if (freshTarget != null && freshTarget.isAvailable) {
        target = freshTarget;
      }
    }

    // 3. Jika target lama sudah occupied atau belum ada, pilih ulang slot terbaik
    target ??= findBestAvailableSlot();

    if (target == null) {
      _statusBanner = 'Tidak ada slot parkir kosong yang tersedia!';
      notifyListeners();
      return;
    }

    _targetSlot = target;
    final success = _calculateRouteToSlot(target);

    if (success) {
      _isNavigating = true;
      _statusBanner =
          'Navigasi aktif ke slot ${target.id} (${_currentRouteDistance.toStringAsFixed(1)}m)';
      currentRouteNotifier.value = _currentRoute;
      routeDistanceNotifier.value = _currentRouteDistance;

      // Mulai penyedia posisi dan beri tahu perubahan rute
      _positionProvider.start();
      _positionProvider.onRouteChanged(
        _currentRoute.map((n) => Offset(n.x, n.y)).toList(),
      );
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
    currentRouteNotifier.value = [];
    routeDistanceNotifier.value = 0.0;
    _targetSlot = null;
    _statusBanner = 'Navigasi dihentikan.';
    _positionProvider.stop();
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
        currentRouteNotifier.value = _currentRoute;
        routeDistanceNotifier.value = _currentRouteDistance;

        // Beri tahu provider posisi tentang rute baru dari posisi saat ini
        _positionProvider.onRouteChanged(
          _currentRoute.map((n) => Offset(n.x, n.y)).toList(),
        );
      } else {
        _isNavigating = false;
        _targetSlot = null;
        _currentRoute = [];
        _currentRouteDistance = 0.0;
        currentRouteNotifier.value = [];
        routeDistanceNotifier.value = 0.0;
        _statusBanner = '❌ Semua slot parkir terisi penuh!';
        _positionProvider.stop();
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
        'y': 0.0,
        'z': node.y,
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
    _positionSubscription?.cancel();
    _positionProvider.dispose();
    _slotSubscription?.cancel();
    _repository.dispose();
    userPositionNotifier.dispose();
    userHeadingNotifier.dispose();
    currentRouteNotifier.dispose();
    routeDistanceNotifier.dispose();
    super.dispose();
  }
}
