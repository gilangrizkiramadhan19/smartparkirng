import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/map_data.dart';
import '../models/parking_models.dart';
import 'a_star.dart';
import 'graph_snap.dart';
import 'map_repository.dart';
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

/// Controller state management untuk navigasi denah, pemilihan tujuan (room, toilet, slot),
/// kalibrasi QR, multi-lantai, dan dynamic rerouting.
class NavigationController extends ChangeNotifier {
  final MapRepository? _mapRepository;
  final ParkingRepository? _repository;
  StreamSubscription<SlotUpdate>? _slotSubscription;
  StreamSubscription<UserPosition>? _positionSubscription;

  // Position Provider & Mode
  PositionProvider _positionProvider;
  SimulatedPositionProvider? _simulatedProvider;
  ManualPositionProvider? _manualProvider;
  NavigationPositionMode _positionMode = NavigationPositionMode.manual;

  // State denah (MapData dari map.json & FloorData per lantai)
  MapData? _mapData;
  FloorData? _currentFloor;
  int _selectedFloorIndex = 0;
  ParkingLayout? _layout;
  bool _isLoading = true;
  String? _errorMessage;

  // State navigasi: titik awal & tujuan
  MapNode? _startNode;
  MapNode? _targetDestination;
  Lobby? _selectedLobby;
  ParkingSlot? _targetSlot;
  List<Node> _currentRoute = [];
  double _currentRouteDistance = 0.0;
  double _initialRouteDistance = 0.0;
  bool _isNavigating = false;
  Node? _currentUserPosition;
  double? _currentUserHeading;
  String? _statusBanner;
  bool _isRerouting = false;
  String _currentInstruction = '';
  double _routeProgress = 0.0;
  int _stepsSinceStart = 0;
  Offset? _lastRawPosition;
  bool _hasArrived = false;
  bool _forceNextPositionUpdate = false;

  // Notifiers terpisah untuk frekuensi tinggi (~10 Hz) agar tidak merebuild seluruh UI
  final ValueNotifier<Node?> userPositionNotifier = ValueNotifier<Node?>(null);
  final ValueNotifier<double?> userHeadingNotifier = ValueNotifier<double?>(null);
  final ValueNotifier<List<Node>> currentRouteNotifier = ValueNotifier<List<Node>>([]);
  final ValueNotifier<double> routeDistanceNotifier = ValueNotifier<double>(0.0);
  final ValueNotifier<String> turnInstructionNotifier = ValueNotifier<String>('');

  NavigationController({
    MapRepository? mapRepository,
    ParkingRepository? repository,
    PositionProvider? positionProvider,
  })  : _mapRepository = mapRepository ?? (repository == null ? MapRepository() : null),
        _repository = repository,
        _positionProvider = positionProvider ?? ManualPositionProvider() {
    _initPositionProvider();
    initialize();
  }

  // Getters
  MapData? get mapData => _mapData;
  FloorData? get currentFloor => _currentFloor;
  int get selectedFloorIndex => _selectedFloorIndex;
  ParkingLayout? get layout => _currentFloor?.toParkingLayout() ?? _layout;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  MapNode? get startNode => _startNode;
  MapNode? get targetDestination => _targetDestination;

  /// Alias untuk [targetDestination] — memudahkan pembacaan di konteks AR.
  MapNode? get destinationNode => _targetDestination;
  Lobby? get selectedLobby => _selectedLobby;
  ParkingSlot? get targetSlot => _targetSlot;
  List<Node> get currentRoute => _currentRoute;
  double get currentRouteDistance => _currentRouteDistance;
  double get initialRouteDistance => _initialRouteDistance;
  double get routeProgress => _routeProgress;
  int get stepsSinceStart => _stepsSinceStart;
  Offset? get lastRawPosition => _lastRawPosition;
  bool get hasArrived => _hasArrived;

  /// Sudut arah target rute di denah (mapBearing) dalam rentang [0, 360) derajat.
  /// Dihitung berdasarkan urutan node di dalam activeRoute (A*) dari currentNode -> nextNode,
  /// BUKAN dari orientasi statis edge (edge.from -> edge.to) yang bisa berlawanan arah.
  double? get mapBearing {
    if (_currentRoute.length < 2) return null;
    final currentNode = _currentRoute[0];
    final nextNode = _currentRoute[1];
    final dx = nextNode.x - currentNode.x;
    final dy = nextNode.y - currentNode.y;
    final rad = math.atan2(dy, dx);
    final deg = rad * 180.0 / math.pi;
    return (deg % 360.0 + 360.0) % 360.0;
  }

  /// Mereset flag tiba dan membersihkan status banner/instruction yang berisi teks tiba.
  void _clearArrivalState() {
    _hasArrived = false;
    if (_statusBanner != null &&
        (_statusBanner!.contains('tiba') ||
         _statusBanner!.startsWith('Anda telah tiba') ||
         _statusBanner!.startsWith('Anda sudah tiba'))) {
      _statusBanner = null;
    }
    if (_currentInstruction.contains('tiba') ||
        _currentInstruction.startsWith('Anda telah tiba') ||
        _currentInstruction.startsWith('Anda sudah tiba')) {
      _currentInstruction = '';
      turnInstructionNotifier.value = '';
    }
  }

  /// Jarak yang sudah ditempuh pengguna sejak navigasi dimulai (meter).
  double get distanceTraveled => _initialRouteDistance > 0
      ? (_initialRouteDistance - _currentRouteDistance).clamp(0.0, _initialRouteDistance)
      : 0.0;

  /// Mencatat penambahan langkah kaki pengguna sejak tombol Mulai Navigasi ditekan.
  void recordStep() {
    if (_isNavigating) {
      _stepsSinceStart++;
      notifyListeners();
    }
  }

  bool get isNavigating => _isNavigating;
  Node? get currentUserPosition => _currentUserPosition;
  double? get currentUserHeading => _currentUserHeading;
  String? get statusBanner => _statusBanner;
  bool get isRerouting => _isRerouting;
  String get currentInstruction => _currentInstruction;
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

  bool get hasSlots {
    if (_currentFloor != null) {
      return _currentFloor!.nodes.any((n) => n.type == NodeType.slot);
    }
    return (_layout?.slots.isNotEmpty ?? false);
  }

  bool get hasToilets {
    if (_currentFloor != null) {
      return _currentFloor!.nodes.any((n) => n.type == NodeType.toilet);
    }
    return false;
  }

  bool get isMultiFloor => (_mapData?.floors.length ?? 0) > 1;

  int get availableSlotsCount =>
      _layout?.slots.where((s) => s.isAvailable).length ?? 0;
  int get totalSlotsCount => _layout?.slots.length ?? 0;

  /// Daftar semua node tujuan yang valid untuk dipilih pengguna (bukan junction).
  List<MapNode> get availableDestinations {
    if (_currentFloor != null) {
      return _currentFloor!.nodes
          .where((n) => n.type != NodeType.junction)
          .toList();
    }
    if (_layout != null) {
      return _layout!.nodes
          .map((n) => MapNode(
                id: n.id,
                name: n.id,
                type: NodeType.unknown,
                x: n.x,
                y: n.y,
              ))
          .toList();
    }
    return [];
  }

  void _initPositionProvider() {
    if (_positionProvider is SimulatedPositionProvider) {
      _simulatedProvider = _positionProvider as SimulatedPositionProvider;
      _positionMode = NavigationPositionMode.simulation;
    } else if (_positionProvider is ManualPositionProvider) {
      _manualProvider = _positionProvider as ManualPositionProvider;
      _positionMode = NavigationPositionMode.manual;
      _manualProvider!.start();
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
      _manualProvider!.start();
    }

    _subscribeToPositionProvider();
    notifyListeners();
  }

  /// Mengatur posisi pengguna secara manual (misal klik di denah pada mode manual atau langkah kaki sensor).
  void setManualPosition(
    Offset position, {
    double? headingDeg,
    bool isStep = false,
    bool force = false,
  }) {
    if (isStep && _isNavigating) {
      _stepsSinceStart++;
    }

    if (_manualProvider != null) {
      _manualProvider!.start();
      _manualProvider!.setPosition(position, headingDeg: headingDeg);
    }
    // Langsung proses pembaruan posisi secara sinkron agar notifier dan listener terupdate segera
    _handlePositionUpdate(
      UserPosition(
        position: position,
        headingDeg: headingDeg ?? _currentUserHeading,
        timestamp: DateTime.now(),
      ),
      force: force,
    );
  }

  /// Pause/Resume simulasi pergerakan.
  void toggleSimulationPause() {
    if (_positionProvider is SimulatedPositionProvider) {
      final sim = _positionProvider as SimulatedPositionProvider;
      if (sim.isPaused) {
        sim.resume();
      } else {
        sim.pause();
      }
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

  /// Inisialisasi awal: mengambil data denah dari MapRepository (assets/maps/map.json)
  /// atau fallback ke ParkingRepository.
  Future<void> initialize() async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      if (_mapRepository != null) {
        _mapData = await _mapRepository.loadFromAsset();
        if (_mapData!.floors.isNotEmpty) {
          _selectedFloorIndex = 0;
          _currentFloor = _mapData!.floors.first;
          _layout = _currentFloor!.toParkingLayout();
        }
      } else if (_repository != null) {
        _layout = await _repository.getLayout();
      }

      // Hanya set lobby default jika menggunakan repository parking lama
      if (_repository != null && _layout != null && _layout!.lobbies.isNotEmpty) {
        _selectedLobby = _layout!.lobbies.first;
        _setUserPositionToLobby(_selectedLobby!);
      }

      // Berlangganan stream realtime update slot jika ada repository
      if (_repository != null) {
        await _slotSubscription?.cancel();
        _slotSubscription = _repository.getSlotUpdates().listen(
          _handleSlotUpdate,
          onError: (err) {
            _statusBanner = 'Koneksi realtime bermasalah: $err';
            notifyListeners();
          },
        );
      }
    } catch (e) {
      _errorMessage = 'Gagal memuat denah: $e';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Memilih lantai untuk navigasi multi-lantai.
  void selectFloor(int index) {
    if (_mapData == null || index < 0 || index >= _mapData!.floors.length) return;
    if (_selectedFloorIndex == index) return;

    _selectedFloorIndex = index;
    _currentFloor = _mapData!.floors[index];
    _layout = _currentFloor!.toParkingLayout();

    _currentRoute = [];
    _currentRouteDistance = 0.0;
    currentRouteNotifier.value = [];
    routeDistanceNotifier.value = 0.0;
    _isNavigating = false;
    _targetDestination = null;
    _targetSlot = null;
    _currentUserPosition = null;
    _currentUserHeading = null;
    userPositionNotifier.value = null;
    userHeadingNotifier.value = null;
    _statusBanner = 'Lantai diubah ke "${_currentFloor!.name}"';
    notifyListeners();
  }

  /// Memilih lobby masuk pengguna (backward-compat).
  void selectLobby(Lobby lobby) {
    if (_isNavigating) return;
    _selectedLobby = lobby;
    _setUserPositionToLobby(lobby);
    _currentRoute = [];
    _currentRouteDistance = 0.0;
    currentRouteNotifier.value = [];
    routeDistanceNotifier.value = 0.0;
    _targetSlot = null;
    _targetDestination = null;
    _statusBanner = null;
    notifyListeners();
  }

  void _setUserPositionToLobby(Lobby lobby) {
    final effectiveLayout = layout;
    if (effectiveLayout == null) return;
    final entryNode = effectiveLayout.nodes.cast<Node?>().firstWhere(
          (n) => n?.id == lobby.entryNodeId,
          orElse: () => null,
        );
    _currentUserPosition = entryNode ?? Node(id: lobby.entryNodeId, x: lobby.x, y: lobby.y);
    _currentUserHeading = null;
    userPositionNotifier.value = _currentUserPosition;
    userHeadingNotifier.value = null;
  }

  /// Menghitung sisa jarak sepanjang polyline rute [route] dari titik [userPos]
  /// berdasarkan proyeksi ke segmen terdekat dan akumulasi sisa segmen.
  double calculateRemainingRouteDistance(Offset userPos, List<Node> route) {
    if (route.isEmpty) return 0.0;
    if (route.length == 1) {
      return (userPos - Offset(route.first.x, route.first.y)).distance;
    }

    int bestSegmentIndex = 0;
    double minDistance = double.infinity;
    Offset bestProj = userPos;

    for (int i = 0; i < route.length - 1; i++) {
      final a = Offset(route[i].x, route[i].y);
      final b = Offset(route[i + 1].x, route[i + 1].y);
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

    // Jarak dari proyeksi ke akhir segmen saat ini
    final nextNode = Offset(route[bestSegmentIndex + 1].x, route[bestSegmentIndex + 1].y);
    double remaining = (nextNode - bestProj).distance;

    // Tambahkan panjang semua segmen setelahnya sampai tujuan
    for (int j = bestSegmentIndex + 1; j < route.length - 1; j++) {
      final p1 = Offset(route[j].x, route[j].y);
      final p2 = Offset(route[j + 1].x, route[j + 1].y);
      remaining += (p2 - p1).distance;
    }

    return remaining;
  }

  /// Menyelesaikan navigasi saat pengguna tiba di tujuan.
  void completeArrival() {
    _hasArrived = true;
    _isNavigating = false;
    final targetName = _targetDestination != null
        ? _targetDestination!.name
        : (_targetSlot != null ? 'slot ${_targetSlot!.id}' : 'tujuan');
    _statusBanner = _targetDestination != null
        ? 'Anda telah tiba di $targetName'
        : 'Anda sudah tiba di slot ${_targetSlot!.id}';
    _currentInstruction = 'Anda telah tiba di $targetName';
    turnInstructionNotifier.value = _currentInstruction;

    _positionProvider.stop();
    _currentRoute = [];
    _currentRouteDistance = 0.0;
    _routeProgress = 1.0;
    currentRouteNotifier.value = [];
    routeDistanceNotifier.value = 0.0;
    notifyListeners();
  }

  /// Koreksi posisi pengguna secara manual ke [node] tempat berdiri saat navigasi berlangsung.
  void correctPositionToNode(MapNode node) {
    _clearArrivalState();
    setManualPosition(Offset(node.x, node.y), force: true);
    if (_isNavigating && (_targetDestination != null || _targetSlot != null)) {
      _recalculateRouteFromCurrentPosition();
      _statusBanner = 'Posisi dikoreksi ke "${node.name}"';
    } else {
      _statusBanner = 'Posisi disetel ke "${node.name}"';
    }
    notifyListeners();
  }

  /// Snap posisi [pt] ke segmen rute aktif saja (dalam radius wajar).
  Offset _snapToActiveRoute(Offset pt, List<Node> route) {
    if (route.length < 2) return pt;
    double minDistance = double.infinity;
    Offset bestProj = pt;

    for (int i = 0; i < route.length - 1; i++) {
      final a = Offset(route[i].x, route[i].y);
      final b = Offset(route[i + 1].x, route[i + 1].y);
      final dx = b.dx - a.dx;
      final dy = b.dy - a.dy;
      final lenSq = dx * dx + dy * dy;

      Offset proj;
      if (lenSq == 0) {
        proj = a;
      } else {
        final t = (((pt.dx - a.dx) * dx + (pt.dy - a.dy) * dy) / lenSq).clamp(0.0, 1.0);
        proj = Offset(a.dx + t * dx, a.dy + t * dy);
      }

      final dist = (pt - proj).distance;
      if (dist < minDistance) {
        minDistance = dist;
        bestProj = proj;
      }
    }

    // Jika dalam radius 2.0 m dari rute aktif, gunakan proyeksi rute
    if (minDistance <= 2.0) {
      return bestProj;
    }
    return pt;
  }

  /// Snap posisi [pt] ke edge denah dalam radius kecil (<= 2.0 m) dari posisi sebelumnya [prevPos].
  /// Mencegah posisi melompat ke koridor lain yang terpisah dinding.
  Offset _snapNearPreviousPosition(Offset pt, Offset prevPos, ParkingLayout layout) {
    final candidateEdges = <Edge>[];
    for (final edge in layout.edges) {
      final u = layout.nodes.cast<Node?>().firstWhere((n) => n?.id == edge.from, orElse: () => null);
      final v = layout.nodes.cast<Node?>().firstWhere((n) => n?.id == edge.to, orElse: () => null);
      if (u != null && v != null) {
        final dU = (Offset(u.x, u.y) - prevPos).distance;
        final dV = (Offset(v.x, v.y) - prevPos).distance;
        if (dU <= 2.5 || dV <= 2.5) {
          candidateEdges.add(edge);
        }
      }
    }

    if (candidateEdges.isEmpty) return pt;
    final snap = snapToGraph(pt, layout.nodes, candidateEdges, maxSnapDistance: 1.5);
    return snap?.snappedPosition ?? pt;
  }

  /// Handler pembaruan posisi pengguna dari [PositionProvider].
  void _handlePositionUpdate(UserPosition update, {bool force = false}) {
    final effectiveLayout = layout;
    if (effectiveLayout == null) return;

    final effectiveForce = force || _forceNextPositionUpdate;
    _forceNextPositionUpdate = false;

    _lastRawPosition = update.position;

    final targetOffset = _targetDestination != null
        ? Offset(_targetDestination!.x, _targetDestination!.y)
        : (_targetSlot != null ? Offset(_targetSlot!.x, _targetSlot!.y) : null);

    final prevPos = _currentUserPosition != null
        ? Offset(_currentUserPosition!.x, _currentUserPosition!.y)
        : null;

    Offset finalOffset;
    if (effectiveForce) {
      // Lewati displacement clamping dan smoothing
      final isExactNode = effectiveLayout.nodes.any(
        (n) => (Offset(n.x, n.y) - update.position).distance < 0.001,
      );
      if (isExactNode) {
        finalOffset = update.position;
      } else {
        final snap = snapToGraph(update.position, effectiveLayout.nodes, effectiveLayout.edges);
        finalOffset = snap?.snappedPosition ?? update.position;
      }
    } else {
      // 1. Batasi lompatan posisi: setiap update posisi maksimal bergeser sejauh panjang satu langkah (<= 0.75 m)
      Offset targetRawPos = update.position;
      const maxStepDisplacement = 0.75;
      if (prevPos != null) {
        final displacement = (targetRawPos - prevPos).distance;
        if (displacement > maxStepDisplacement && displacement > 0) {
          targetRawPos = prevPos + (targetRawPos - prevPos) * (maxStepDisplacement / displacement);
        }
      }

      // 2. Snap ke graf:
      // Saat navigasi aktif, HANYA snap ke segmen rute aktif (tidak boleh meloncat ke koridor lain).
      // Saat standby/idle, snap hanya ke edge di sekitar posisi sebelumnya (radius <= 2.0 m).
      Offset snappedOffset;
      if (_isNavigating && _currentRoute.length >= 2) {
        snappedOffset = _snapToActiveRoute(targetRawPos, _currentRoute);
      } else if (prevPos != null) {
        snappedOffset = _snapNearPreviousPosition(targetRawPos, prevPos, effectiveLayout);
      } else {
        final snap = snapToGraph(targetRawPos, effectiveLayout.nodes, effectiveLayout.edges);
        snappedOffset = snap?.snappedPosition ?? targetRawPos;
      }

      // 3. Tambah smoothing sederhana (EMA: 0.65 posisi baru, 0.35 posisi lama)
      finalOffset = snappedOffset;
      if (prevPos != null) {
        finalOffset = Offset(
          prevPos.dx * 0.35 + snappedOffset.dx * 0.65,
          prevPos.dy * 0.35 + snappedOffset.dy * 0.65,
        );

        // Pastikan pergeseran akhir setelah smoothing tetap tidak melebihi panjang satu langkah (0.75 m)
        final finalDisplacement = (finalOffset - prevPos).distance;
        if (finalDisplacement > maxStepDisplacement && finalDisplacement > 0) {
          finalOffset = prevPos + (finalOffset - prevPos) * (maxStepDisplacement / finalDisplacement);
        }
      }
    }

    final snappedNode = Node(
      id: (_startNode != null &&
              (_startNode!.x - finalOffset.dx).abs() < 0.001 &&
              (_startNode!.y - finalOffset.dy).abs() < 0.001)
          ? _startNode!.id
          : 'user_pos_${finalOffset.dx.toStringAsFixed(3)}_${finalOffset.dy.toStringAsFixed(3)}',
      x: finalOffset.dx,
      y: finalOffset.dy,
    );

    _currentUserPosition = snappedNode;
    _currentUserHeading = update.headingDeg;
    userPositionNotifier.value = snappedNode;
    userHeadingNotifier.value = update.headingDeg;

    // Hitung jarak sisa sepanjang rute dan progres rute (0.0 sampai 1.0)
    final remainingRouteDist = _currentRoute.isNotEmpty
        ? calculateRemainingRouteDistance(finalOffset, _currentRoute)
        : (targetOffset != null ? (finalOffset - targetOffset).distance : 0.0);

    _currentRouteDistance = remainingRouteDist;
    routeDistanceNotifier.value = _currentRouteDistance;

    if (_initialRouteDistance > 0) {
      _routeProgress = (1.0 - (remainingRouteDist / _initialRouteDistance)).clamp(0.0, 1.0);
    } else {
      _routeProgress = 1.0;
    }

    // 4. Deteksi tiba di tujuan:
    // HANYA dievaluasi saat navigasi benar-benar berjalan (tombol Mulai sudah ditekan).
    // Syarat tiba:
    // - sisa jarak sepanjang rute <= ambang
    // - DAN user sudah menempuh minimal 80% panjang rute (indoor) / 50% (slot parkir)
    // - DAN minimal 3 langkah terdeteksi sejak Mulai.
    // Ambang ketat indoor:
    // Untuk target destination (ruangan indoor): ambang maksimal 0.85 m (tidak tiba prematur saat masih 1.6m / 5 langkah lagi).
    // Untuk slot parkir: ambang hingga 1.5 m.
    if (_isNavigating && targetOffset != null) {
      final maxThreshold = _targetSlot != null ? 1.5 : 0.85;
      final arrivalThreshold = math.min(maxThreshold, math.max(0.4, _initialRouteDistance * 0.12));

      if (_initialRouteDistance <= 1.0) {
        _statusBanner = 'Anda sudah dekat tujuan';
      } else {
        final snapDist = (finalOffset - targetOffset).distance;
        final rawDist = (update.position - targetOffset).distance;
        final directDist = math.min(snapDist, rawDist);

        final isSameAsStart = _startNode != null &&
            _targetDestination != null &&
            _startNode!.id == _targetDestination!.id;

        final isWithinThreshold = remainingRouteDist <= arrivalThreshold || directDist <= arrivalThreshold;
        final minProgressReq = _targetSlot != null ? 0.50 : 0.80;
        final hasMinProgress = _routeProgress >= minProgressReq;
        final hasMinSteps = (_positionMode == NavigationPositionMode.simulation || _targetSlot != null)
            ? true
            : (_stepsSinceStart >= 3);

        if (!isSameAsStart && isWithinThreshold && hasMinProgress && hasMinSteps) {
          completeArrival();
          return;
        }
      }
    }

    // 5. Deteksi simpangan rute (> 3 m dari rute): hitung ulang rute otomatis
    if (_isNavigating && _currentRoute.length >= 2) {
      final offRouteDist = _distanceToRoute(finalOffset, _currentRoute);
      if (offRouteDist > 3.0) {
        _isRerouting = true;
        _statusBanner = 'Rute dihitung ulang';
        _recalculateRouteFromCurrentPosition();
        notifyListeners();
        return;
      }
    }

    // 6. Pangkas rute sehingga hanya sisa rute di depan pengguna yang tersisa
    if (_isNavigating && _currentRoute.isNotEmpty) {
      _trimRoute(finalOffset);
      _updateTurnInstruction();
    }

    notifyListeners();
  }

  double _distanceToRoute(Offset pt, List<Node> route) {
    double minD = double.infinity;
    for (int i = 0; i < route.length - 1; i++) {
      final p1 = Offset(route[i].x, route[i].y);
      final p2 = Offset(route[i + 1].x, route[i + 1].y);
      final d = _pointToSegmentDistance(pt, p1, p2);
      if (d < minD) minD = d;
    }
    return minD;
  }

  double _pointToSegmentDistance(Offset p, Offset a, Offset b) {
    final dx = b.dx - a.dx;
    final dy = b.dy - a.dy;
    final lenSq = dx * dx + dy * dy;
    if (lenSq == 0) return (p - a).distance;
    final t = (((p.dx - a.dx) * dx + (p.dy - a.dy) * dy) / lenSq).clamp(0.0, 1.0);
    final proj = Offset(a.dx + t * dx, a.dy + t * dy);
    return (p - proj).distance;
  }

  void _recalculateRouteFromCurrentPosition() {
    if (_currentUserPosition == null) return;
    if (_targetDestination != null) {
      final searchGraph = _buildEffectiveSearchGraph();
      final path = AStar.findPath(
        nodes: searchGraph.layout.nodes,
        edges: searchGraph.layout.edges,
        startNodeId: searchGraph.startNodeId,
        targetNodeId: _targetDestination!.id,
      );
      if (path != null && path.isNotEmpty) {
        _currentRoute = path;
        _currentRouteDistance = AStar.calculatePathLength(path);
        currentRouteNotifier.value = _currentRoute;
        routeDistanceNotifier.value = _currentRouteDistance;
        _isRerouting = false;
        _statusBanner = 'Rute dihitung ulang (${_currentRouteDistance.toStringAsFixed(1)} m)';
        if (_positionMode == NavigationPositionMode.simulation) {
          _positionProvider.onRouteChanged(
            _currentRoute.map((n) => Offset(n.x, n.y)).toList(),
          );
        }
        _updateTurnInstruction();
      }
    } else if (_targetSlot != null) {
      _calculateRouteToSlot(_targetSlot!);
    }
  }

  void _updateTurnInstruction() {
    if (!_isNavigating || _currentRoute.length < 2) {
      if (_currentRoute.isEmpty && !_isNavigating) {
        _currentInstruction = '';
      } else if (_targetDestination != null) {
        _currentInstruction = 'Lurus ke ${_targetDestination!.name}';
      }
      turnInstructionNotifier.value = _currentInstruction;
      return;
    }

    final n0 = _currentRoute[0];
    final n1 = _currentRoute[1];
    final distToNext = (Offset(n1.x, n1.y) - Offset(n0.x, n0.y)).distance;

    final landmark = _currentFloor?.findNodeById(n1.id);
    final landmarkName = landmark?.name ?? n1.id;

    if (_currentRoute.length < 3) {
      if (distToNext > 1.5) {
        _currentInstruction = 'Lurus ${distToNext.toStringAsFixed(0)} m ke arah $landmarkName';
      } else {
        _currentInstruction = 'Mendekati $landmarkName';
      }
      turnInstructionNotifier.value = _currentInstruction;
      return;
    }

    final n2 = _currentRoute[2];
    final angle1 = math.atan2(n1.y - n0.y, n1.x - n0.x) * 180 / math.pi;
    final angle2 = math.atan2(n2.y - n1.y, n2.x - n1.x) * 180 / math.pi;
    var turnAngle = (angle2 - angle1) % 360;
    if (turnAngle > 180) turnAngle -= 360;
    if (turnAngle < -180) turnAngle += 360;

    String turnAction;
    if (turnAngle.abs() < 30) {
      turnAction = 'Lurus';
    } else if (turnAngle > 30 && turnAngle <= 135) {
      turnAction = 'Belok kanan';
    } else if (turnAngle < -30 && turnAngle >= -135) {
      turnAction = 'Belok kiri';
    } else {
      turnAction = 'Putar balik';
    }

    if (distToNext > 3.0) {
      _currentInstruction = 'Lurus ${distToNext.toStringAsFixed(0)} m, lalu $turnAction di $landmarkName';
    } else if (turnAction != 'Lurus') {
      _currentInstruction = '$turnAction di $landmarkName';
    } else {
      _currentInstruction = 'Lurus ${distToNext.toStringAsFixed(0)} m ke $landmarkName';
    }

    turnInstructionNotifier.value = _currentInstruction;
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

  /// Membangun graf pencarian rute yang menghubungkan posisi pengguna saat ini
  /// ke segmen edge denah terdekat dengan node virtual 'user_virtual'.
  _SearchGraph _buildEffectiveSearchGraph() {
    final effectiveLayout = layout;
    if (effectiveLayout == null) {
      throw StateError('Layout belum dimuat.');
    }

    if (_currentUserPosition == null) {
      throw StateError('Posisi pengguna belum ditentukan.');
    }

    final userOffset = Offset(_currentUserPosition!.x, _currentUserPosition!.y);

    // Cek apakah posisi pengguna sudah bertepatan tepat dengan salah satu node yang ada
    for (var node in effectiveLayout.nodes) {
      final dx = (node.x - userOffset.dx).abs();
      final dy = (node.y - userOffset.dy).abs();
      if (dx < 0.05 && dy < 0.05) {
        return _SearchGraph(effectiveLayout, node.id);
      }
    }

    // Jika berada di antara segmen edge, proyeksikan dengan snapToGraph
    final snap = snapToGraph(userOffset, effectiveLayout.nodes, effectiveLayout.edges);
    if (snap == null) {
      return _SearchGraph(effectiveLayout, effectiveLayout.nodes.first.id);
    }

    final virtualNode = Node(
      id: 'user_virtual',
      x: snap.snappedPosition.dx,
      y: snap.snappedPosition.dy,
    );

    final virtualNodes = List<Node>.from(effectiveLayout.nodes)..add(virtualNode);
    final virtualEdges = List<Edge>.from(effectiveLayout.edges);

    final u = effectiveLayout.nodes.firstWhere((n) => n.id == snap.edge.from);
    final v = effectiveLayout.nodes.firstWhere((n) => n.id == snap.edge.to);

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
      width: effectiveLayout.width,
      height: effectiveLayout.height,
      lobbies: effectiveLayout.lobbies,
      nodes: virtualNodes,
      edges: virtualEdges,
      slots: effectiveLayout.slots,
    );

    return _SearchGraph(graphCopy, 'user_virtual');
  }

  /// Mereset titik awal dan posisi pengguna (misal saat masuk halaman AR yang belum dikalibrasi).
  /// PENTING: TIDAK mengubah [_targetDestination] — tujuan yang sudah dipilih tetap dipertahankan.
  void resetUserPositionAndStartNode() {
    _clearArrivalState();
    _forceNextPositionUpdate = false;
    _startNode = null;
    _currentUserPosition = null;
    _lastRawPosition = null;
    _stepsSinceStart = 0;
    _currentUserHeading = null;
    userPositionNotifier.value = null;
    userHeadingNotifier.value = null;
    _currentRoute = [];
    _currentRouteDistance = 0.0;
    currentRouteNotifier.value = [];
    routeDistanceNotifier.value = 0.0;
    _isNavigating = false;
    // _targetDestination sengaja TIDAK direset agar tujuan yang sudah dipilih user tetap ada.
    notifyListeners();
  }

  /// Mengatur titik awal secara manual atau dari scan QR.
  /// TIDAK mengubah [_targetDestination] dalam kondisi apapun.
  /// Jika posisi awal == tujuan, tampilkan pesan peringatan (tujuan tetap dipertahankan).
  /// Mengembalikan [true] jika berhasil, [false] jika node awal == tujuan (perlu pilih tujuan lain).
  bool setStartNode(MapNode node) {
    _clearArrivalState();
    _forceNextPositionUpdate = true;
    _startNode = node;
    _currentUserPosition = Node(id: node.id, x: node.x, y: node.y);
    _lastRawPosition = Offset(node.x, node.y);
    _stepsSinceStart = 0;
    userPositionNotifier.value = _currentUserPosition;

    // Bersihkan buffer stream lama agar tidak ada event posisi usang dari sesi sebelumnya
    _subscribeToPositionProvider();

    if (_manualProvider != null) {
      _manualProvider!.setPosition(
        Offset(node.x, node.y),
        headingDeg: _currentUserHeading,
      );
      _manualProvider!.start();
    }

    if (_targetDestination != null) {
      final isSame = _targetDestination!.id == node.id;
      if (isSame) {
        // Posisi awal == tujuan: JANGAN hapus/timpa _targetDestination.
        // Pertahankan tujuan lama, beri pesan peringatan, biarkan user pilih tujuan lain.
        _isNavigating = false;
        _currentRoute = [];
        _currentRouteDistance = 0.0;
        currentRouteNotifier.value = _currentRoute;
        routeDistanceNotifier.value = 0.0;
        _statusBanner = 'Anda sudah di "${node.name}", pilih tujuan lain.';
        _currentInstruction = 'Anda sudah di "${node.name}", pilih tujuan lain.';
        turnInstructionNotifier.value = _currentInstruction;
        notifyListeners();
        return false; // sinyal ke caller agar membuka pemilih tujuan
      } else {
        _previewRouteToDestination(_targetDestination!);
      }
    } else {
      _statusBanner = 'Titik awal: "${node.name}". Silakan pilih tujuan.';
    }
    notifyListeners();
    return true;
  }

  /// Menukar titik awal dan titik tujuan ("Dari" <-> "Ke").
  void swapStartAndDestination() {
    _clearArrivalState();
    _forceNextPositionUpdate = true;
    if (_startNode == null || _targetDestination == null) return;
    final oldStart = _startNode!;
    final oldTarget = _targetDestination!;

    _startNode = oldTarget;
    _currentUserPosition = Node(id: oldTarget.id, x: oldTarget.x, y: oldTarget.y);
    userPositionNotifier.value = _currentUserPosition;
    if (_manualProvider != null) {
      _manualProvider!.setPosition(Offset(oldTarget.x, oldTarget.y));
      _manualProvider!.start();
    }

    _targetDestination = oldStart;
    _targetSlot = oldStart.type == NodeType.slot
        ? ParkingSlot(
            id: oldStart.id,
            lobbyId: _currentFloor?.id ?? 'L1',
            x: oldStart.x,
            y: oldStart.y,
            entryNodeId: oldStart.id,
          )
        : null;

    _previewRouteToDestination(oldStart);
    notifyListeners();
  }

  /// Memilih node tujuan navigasi apa pun (room, toilet, entrance, slot, dll).
  void selectDestination(MapNode destination) {
    _clearArrivalState();
    // Cek dulu: jangan pilih tujuan yang sama dengan posisi awal.
    final isSameAsStart = (_startNode != null && _startNode!.id == destination.id) ||
        (_currentUserPosition != null &&
            _currentUserPosition!.id == destination.id &&
            _startNode != null);

    if (isSameAsStart) {
      // JANGAN timpa _targetDestination dengan pilihan ini.
      // Pertahankan tujuan lama (jika ada), atau biarkan null.
      _isNavigating = false;
      _currentRoute = [];
      _currentRouteDistance = 0.0;
      currentRouteNotifier.value = _currentRoute;
      routeDistanceNotifier.value = 0.0;
      _statusBanner = 'Anda sudah di "${destination.name}", pilih tujuan lain.';
      _currentInstruction = 'Anda sudah di "${destination.name}", pilih tujuan lain.';
      turnInstructionNotifier.value = _currentInstruction;
      notifyListeners();
      return;
    }

    _targetDestination = destination;
    _targetSlot = destination.type == NodeType.slot
        ? ParkingSlot(
            id: destination.id,
            lobbyId: _currentFloor?.id ?? 'L1',
            x: destination.x,
            y: destination.y,
            entryNodeId: destination.id,
          )
        : null;

    if (_currentUserPosition == null && _startNode == null) {
      _currentRoute = [];
      _currentRouteDistance = 0.0;
      currentRouteNotifier.value = [];
      routeDistanceNotifier.value = 0.0;
      _isNavigating = false;
      _statusBanner = 'Tujuan dipilih: "${destination.name}". Pilih posisi awal Anda dulu.';
      _currentInstruction = 'Pilih posisi awal Anda dulu';
      turnInstructionNotifier.value = _currentInstruction;
      notifyListeners();
      return;
    }

    _previewRouteToDestination(destination);
    notifyListeners();
  }

  /// Menghitung pratinjau rute A* ke node tujuan umum (tanpa langsung memulai navigasi).
  bool _previewRouteToDestination(MapNode destination) {
    final effectiveLayout = layout;
    if (effectiveLayout == null || (_currentUserPosition == null && _startNode == null)) {
      return false;
    }

    if (_currentUserPosition == null && _startNode != null) {
      _currentUserPosition = Node(id: _startNode!.id, x: _startNode!.x, y: _startNode!.y);
      userPositionNotifier.value = _currentUserPosition;
    }

    final searchGraph = _buildEffectiveSearchGraph();
    final startId = searchGraph.startNodeId;

    final path = AStar.findPath(
      nodes: searchGraph.layout.nodes,
      edges: searchGraph.layout.edges,
      startNodeId: startId,
      targetNodeId: destination.id,
    );

    if (path != null && path.isNotEmpty) {
      _currentRoute = path;
      _currentRouteDistance = AStar.calculatePathLength(path);
      currentRouteNotifier.value = _currentRoute;
      routeDistanceNotifier.value = _currentRouteDistance;
      _isNavigating = false;
      _statusBanner = 'Rute ke "${destination.name}" (${_currentRouteDistance.toStringAsFixed(1)} m). Tekan Mulai Navigasi.';
      _updateTurnInstruction();
      return true;
    } else {
      _currentRoute = [];
      _currentRouteDistance = 0.0;
      currentRouteNotifier.value = [];
      routeDistanceNotifier.value = 0.0;
      _statusBanner = 'Tidak ada jalur ke "${destination.name}"';
      _currentInstruction = 'Tidak ada jalur';
      turnInstructionNotifier.value = _currentInstruction;
      return false;
    }
  }

  /// Memulai navigasi aktif rute Dari -> Ke setelah user menekan tombol Mulai Navigasi.
  bool startRouteNavigation() {
    _clearArrivalState();
    if (_currentUserPosition == null && _startNode == null) {
      _statusBanner = 'Pindai QR lokasi awal Anda dulu.';
      notifyListeners();
      return false;
    }

    if (_targetDestination == null && _targetSlot == null) {
      _statusBanner = 'Pilih tujuan terlebih dahulu.';
      notifyListeners();
      return false;
    }

    final dest = _targetDestination;
    if (dest != null) {
      final isSame = (_startNode != null && _startNode!.id == dest.id) ||
          (_currentUserPosition != null && _currentUserPosition!.id == dest.id);

      if (isSame) {
        _isNavigating = false;
        _statusBanner = 'Titik awal dan tujuan sama';
        _currentInstruction = 'Titik awal dan tujuan sama';
        turnInstructionNotifier.value = _currentInstruction;
        notifyListeners();
        return false;
      }
    }

    if (_currentRoute.isEmpty) {
      if (dest != null) {
        final ok = _previewRouteToDestination(dest);
        if (!ok) return false;
      } else if (_targetSlot != null) {
        final ok = _calculateRouteToSlot(_targetSlot!);
        if (!ok) return false;
      }
    }

    if (_currentRouteDistance <= 0.05) {
      _isNavigating = false;
      _statusBanner = 'Titik awal dan tujuan sama';
      _currentInstruction = 'Titik awal dan tujuan sama';
      turnInstructionNotifier.value = _currentInstruction;
      notifyListeners();
      return false;
    }

    _stepsSinceStart = 0;
    _initialRouteDistance = _currentRouteDistance;
    _isNavigating = true;

    final isAlreadyWithinThreshold = _initialRouteDistance <= 2.0;
    if (isAlreadyWithinThreshold) {
      _statusBanner = 'Anda sudah dekat tujuan';
      _currentInstruction = 'Anda sudah dekat tujuan';
      turnInstructionNotifier.value = _currentInstruction;
    } else {
      final destName = _targetDestination?.name ?? (_targetSlot != null ? 'Slot ${_targetSlot!.id}' : 'tujuan');
      _statusBanner = 'Navigasi aktif ke "$destName" (${_currentRouteDistance.toStringAsFixed(1)} m)';
      _updateTurnInstruction();
    }

    _positionProvider.start();
    if (_positionMode == NavigationPositionMode.simulation) {
      _positionProvider.onRouteChanged(
        _currentRoute.map((n) => Offset(n.x, n.y)).toList(),
      );
    }

    notifyListeners();
    return true;
  }

  /// Mencari toilet terdekat dari posisi saat ini menggunakan algoritma A*.
  bool findNearestToilet() {
    final floor = _currentFloor;
    if (floor == null) return false;

    final toilets = floor.nodes.where((n) => n.type == NodeType.toilet).toList();
    if (toilets.isEmpty) {
      _statusBanner = 'Tidak ada toilet pada lantai ini.';
      notifyListeners();
      return false;
    }

    if (_currentUserPosition == null) {
      selectDestination(toilets.first);
      return true;
    }

    final searchGraph = _buildEffectiveSearchGraph();
    final startId = searchGraph.startNodeId;

    MapNode? bestToilet;
    double minDistance = double.infinity;

    for (final toilet in toilets) {
      final path = AStar.findPath(
        nodes: searchGraph.layout.nodes,
        edges: searchGraph.layout.edges,
        startNodeId: startId,
        targetNodeId: toilet.id,
      );
      if (path != null && path.isNotEmpty) {
        final dist = AStar.calculatePathLength(path);
        if (dist < minDistance) {
          minDistance = dist;
          bestToilet = toilet;
        }
      }
    }

    if (bestToilet != null) {
      selectDestination(bestToilet);
      return true;
    } else {
      selectDestination(toilets.first);
      return true;
    }
  }

  /// Kalibrasi posisi awal dan orientasi melalui ID node dari kode QR.
  /// Menerima [nodeId] (mis. "n1" atau "n5") dan opsional [heading].
  bool calibrateWithNodeId(String nodeId, {double? heading}) {
    final effectiveLayout = layout;
    if (_mapData == null && effectiveLayout == null) return false;

    final cleanId = nodeId.trim().toLowerCase();

    // 1. Cari node di lantai saat ini
    MapNode? foundNode;
    if (_currentFloor != null) {
      foundNode = _currentFloor!.findNodeById(cleanId);
    }

    // 2. Jika tidak ada di lantai saat ini, cari di semua lantai
    if (foundNode == null && _mapData != null) {
      for (int i = 0; i < _mapData!.floors.length; i++) {
        final candidate = _mapData!.floors[i].findNodeById(cleanId);
        if (candidate != null) {
          selectFloor(i);
          foundNode = candidate;
          break;
        }
      }
    }

    // 3. Fallback jika masih null, cari di nodes layout lama
    if (foundNode == null && effectiveLayout != null) {
      final fallback = effectiveLayout.nodes.cast<Node?>().firstWhere(
            (n) => n?.id.toLowerCase() == cleanId,
            orElse: () => null,
          );
      if (fallback != null) {
        foundNode = MapNode(
          id: fallback.id,
          name: fallback.id,
          type: NodeType.unknown,
          x: fallback.x,
          y: fallback.y,
        );
      }
    }

    if (foundNode == null) {
      return false;
    }

    _clearArrivalState();
    _forceNextPositionUpdate = true;
    _startNode = foundNode;
    _currentUserPosition = Node(
      id: foundNode.id,
      x: foundNode.x,
      y: foundNode.y,
    );
    _currentUserHeading = heading;
    userPositionNotifier.value = _currentUserPosition;
    userHeadingNotifier.value = heading;

    // Sinkronkan ke provider manual bila ada
    if (_manualProvider != null) {
      _manualProvider!.setPosition(
        Offset(foundNode.x, foundNode.y),
        headingDeg: heading,
      );
      _manualProvider!.start();
    }

    _statusBanner = 'Posisi awal berhasil dikalibrasi ke "${foundNode.name}"';

    if (_isNavigating && (_targetDestination != null || _targetSlot != null)) {
      _recalculateRouteFromCurrentPosition();
    } else if (_targetDestination != null) {
      _previewRouteToDestination(_targetDestination!);
    } else if (_targetSlot != null) {
      _calculateRouteToSlot(_targetSlot!);
    }

    notifyListeners();
    return true;
  }

  /// Memilih slot tujuan secara manual dari klik peta (backward-compat).
  void selectTargetSlot(ParkingSlot slot) {
    _clearArrivalState();
    if (_isNavigating) return;
    _targetSlot = slot;
    _targetDestination = MapNode(
      id: slot.id,
      name: 'Slot ${slot.id}',
      type: NodeType.slot,
      x: slot.x,
      y: slot.y,
    );
    _calculateRouteToSlot(slot);
    notifyListeners();
  }

  /// Menghitung rute A* ke slot tertentu.
  bool _calculateRouteToSlot(ParkingSlot slot) {
    final effectiveLayout = layout;
    if (effectiveLayout == null || _currentUserPosition == null) return false;

    final searchGraph = _buildEffectiveSearchGraph();
    final startId = searchGraph.startNodeId;

    final path = AStar.findPath(
      nodes: searchGraph.layout.nodes,
      edges: searchGraph.layout.edges,
      startNodeId: startId,
      targetNodeId: slot.entryNodeId,
    );

    if (path != null && path.isNotEmpty) {
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
    final effectiveLayout = layout;
    if (effectiveLayout == null || _currentUserPosition == null) return null;

    final availableSlots = effectiveLayout.slots.where((s) => s.isAvailable).toList();
    if (availableSlots.isEmpty) return null;

    final searchGraph = _buildEffectiveSearchGraph();
    final startId = searchGraph.startNodeId;

    ParkingSlot? bestSlot;
    double shortestDistance = double.infinity;
    List<Node>? bestRoute;

    for (var slot in availableSlots) {
      final path = AStar.findPath(
        nodes: searchGraph.layout.nodes,
        edges: searchGraph.layout.edges,
        startNodeId: startId,
        targetNodeId: slot.entryNodeId,
      );

      if (path != null && path.isNotEmpty) {
        final slotNode = Node(id: 'slot_${slot.id}', x: slot.x, y: slot.y);
        final fullRoute = [...path, slotNode];
        final totalDist = AStar.calculatePathLength(fullRoute);

        if (totalDist < shortestDistance) {
          shortestDistance = totalDist;
          bestSlot = slot;
          bestRoute = fullRoute;
        }
      }
    }

    if (bestSlot != null && bestRoute != null) {
      _currentRoute = bestRoute;
      _currentRouteDistance = shortestDistance;
      _targetSlot = bestSlot;
      currentRouteNotifier.value = _currentRoute;
      routeDistanceNotifier.value = _currentRouteDistance;
      return bestSlot;
    }

    return null;
  }

  /// Memulai navigasi.
  void startNavigation({ParkingSlot? destination}) {
    final effectiveLayout = layout;
    if (effectiveLayout == null) return;

    if (_targetDestination != null) {
      final isOccupiedSlot = _targetDestination!.type == NodeType.slot &&
          effectiveLayout.slots.any((s) => s.id == _targetDestination!.id && !s.isAvailable);
      if (!isOccupiedSlot) {
        final ok = startRouteNavigation();
        if (ok) return;
      } else {
        _targetDestination = null;
        _targetSlot = null;
      }
    }

    if (!hasSlots) {
      // Denah indoor (tanpa slot): JANGAN otomatis pilih tujuan pertama.
      // Biarkan user memilih tujuan sendiri melalui DestinationPickerSheet.
      if (_targetDestination == null) {
        _statusBanner = 'Silakan pilih tujuan navigasi terlebih dahulu.';
        notifyListeners();
      } else {
        // _targetDestination sudah ada tapi startRouteNavigation gagal (mis. posisi awal belum di-set)
        _statusBanner = 'Pilih posisi awal Anda terlebih dahulu.';
        notifyListeners();
      }
      return;
    }

    ParkingSlot? target;
    if (destination != null) {
      final freshDest = effectiveLayout.slots.cast<ParkingSlot?>().firstWhere(
            (s) => s?.id == destination.id,
            orElse: () => null,
          );
      if (freshDest != null && freshDest.isAvailable) {
        target = freshDest;
      }
    }

    if (target == null && _targetSlot != null) {
      final freshTarget = effectiveLayout.slots.cast<ParkingSlot?>().firstWhere(
            (s) => s?.id == _targetSlot!.id,
            orElse: () => null,
          );
      if (freshTarget != null && freshTarget.isAvailable) {
        target = freshTarget;
      }
    }

    target ??= findBestAvailableSlot();

    if (target == null) {
      _statusBanner = 'Tidak ada slot parkir kosong yang tersedia!';
      notifyListeners();
      return;
    }

    _targetSlot = target;
    final success = _calculateRouteToSlot(target);

    if (success) {
      _stepsSinceStart = 0;
      _initialRouteDistance = _currentRouteDistance;
      _isNavigating = true;
      _statusBanner =
          'Navigasi aktif ke slot ${target.id} (${_currentRouteDistance.toStringAsFixed(1)}m)';
      currentRouteNotifier.value = _currentRoute;
      routeDistanceNotifier.value = _currentRouteDistance;

      _positionProvider.start();
      _positionProvider.onRouteChanged(
        _currentRoute.map((n) => Offset(n.x, n.y)).toList(),
      );
    } else {
      _statusBanner = 'Gagal menemukan jalur ke slot ${target.id}';
    }

    notifyListeners();
  }

  /// Membatalkan atau menyelesaikan navigasi.
  void stopNavigation() {
    _clearArrivalState();
    _isNavigating = false;
    _positionProvider.stop();
    _currentRoute = [];
    _currentRouteDistance = 0.0;
    _targetDestination = null;
    _targetSlot = null;
    _statusBanner = 'Navigasi dihentikan';
    currentRouteNotifier.value = [];
    routeDistanceNotifier.value = 0.0;
    notifyListeners();
  }

  /// Handler pembaruan realtime status slot (Dynamic Rerouting).
  void _handleSlotUpdate(SlotUpdate update) {
    final effectiveLayout = layout;
    if (effectiveLayout == null) return;

    final updatedSlots = effectiveLayout.slots.map((s) {
      if (s.id == update.slotId) {
        return s.copyWith(status: update.status);
      }
      return s;
    }).toList();

    _layout = ParkingLayout(
      width: effectiveLayout.width,
      height: effectiveLayout.height,
      lobbies: effectiveLayout.lobbies,
      nodes: effectiveLayout.nodes,
      edges: effectiveLayout.edges,
      slots: updatedSlots,
    );

    if (_isNavigating &&
        _targetSlot != null &&
        _targetSlot!.id == update.slotId &&
        update.status != SlotStatus.available) {
      _triggerDynamicRerouting(update.slotId);
    } else {
      notifyListeners();
    }
  }

  /// Dynamic Rerouting otomatis ketika target menjadi terisi/dipesan.
  void _triggerDynamicRerouting(String occupiedSlotId) {
    _isRerouting = true;
    _statusBanner = 'Slot $occupiedSlotId baru saja terisi! Mencari rute alternatif...';
    notifyListeners();

    final newSlot = findBestAvailableSlot();

    if (newSlot != null) {
      _isRerouting = false;
      _targetSlot = newSlot;
      _isNavigating = true;
      _statusBanner =
          'Rute dialihkan ke Slot ${newSlot.id} (${_currentRouteDistance.toStringAsFixed(1)}m)';

      _positionProvider.onRouteChanged(
        _currentRoute.map((n) => Offset(n.x, n.y)).toList(),
      );
    } else {
      _isRerouting = false;
      _isNavigating = false;
      _positionProvider.stop();
      _currentRoute = [];
      _currentRouteDistance = 0.0;
      currentRouteNotifier.value = [];
      routeDistanceNotifier.value = 0.0;
      _statusBanner = 'Maaf, semua slot parkir saat ini sudah penuh!';
    }

    notifyListeners();
  }

  /// Simulasi: Jadikan slot saat ini terisi oleh kendaraan lain.
  Future<void> simulateCurrentSlotOccupied() async {
    if (_targetSlot == null || _repository == null) return;
    await _repository.updateSlotStatus(_targetSlot!.id, SlotStatus.occupied);
  }

  /// Alias untuk compatibility test.
  Future<void> simulateTargetOccupied() => simulateCurrentSlotOccupied();


  /// Simulasi: Toggle status ketersediaan slot tertentu.
  Future<void> simulateToggleSlot(String slotId) async {
    if (_repository == null) return;
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
    if (_currentRoute.isEmpty) {
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
      'target': _targetDestination?.name ?? _targetSlot?.id ?? '',
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

  // ---- SharedPreferences: Persistensi Posisi Navigasi Terakhir ----

  static const _kLastX = 'nav_last_x';
  static const _kLastY = 'nav_last_y';
  static const _kLastNodeId = 'nav_last_node_id';
  static const _kHeadingOffset = 'nav_heading_offset';

  /// Menyimpan posisi dan heading offset terakhir ke SharedPreferences.
  /// [useDestination] = true  → simpan koordinat node TUJUAN (completeArrival).
  /// [useDestination] = false → simpan koordinat USER saat ini (stopNavigation di tengah jalan).
  Future<void> saveLastPosition({
    double headingOffsetDeg = 0.0,
    bool useDestination = false,
  }) async {
    double? saveX;
    double? saveY;
    String? saveNodeId;

    if (useDestination) {
      // Prioritas: targetDestination (room/toilet) > targetSlot (parkir)
      if (_targetDestination != null) {
        saveX = _targetDestination!.x;
        saveY = _targetDestination!.y;
        saveNodeId = _targetDestination!.id;
      } else if (_targetSlot != null) {
        saveX = _targetSlot!.x;
        saveY = _targetSlot!.y;
        saveNodeId = _targetSlot!.id;
      }
    }

    // Fallback ke posisi user jika tujuan tidak tersedia
    if (saveX == null || saveNodeId == null) {
      final pos = _currentUserPosition;
      if (pos == null) return;
      saveX = pos.x;
      saveY = pos.y;
      saveNodeId = _startNode?.id ?? pos.id;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kLastX, saveX);
    await prefs.setDouble(_kLastY, saveY!);
    await prefs.setString(_kLastNodeId, saveNodeId);
    await prefs.setDouble(_kHeadingOffset, headingOffsetDeg);
    if (kDebugMode) {
      final src = useDestination ? 'destination' : 'userPos';
      debugPrint('[NavController] saveLastPosition ($src): x=$saveX, y=$saveY, node=$saveNodeId, offset=$headingOffsetDeg');
    }
  }

  /// Membaca posisi navigasi terakhir dari SharedPreferences.
  /// Mengembalikan map {x, y, nodeId, headingOffset} jika ada, null jika belum ada.
  Future<Map<String, dynamic>?> loadLastPosition() async {
    final prefs = await SharedPreferences.getInstance();
    final x = prefs.getDouble(_kLastX);
    final y = prefs.getDouble(_kLastY);
    final nodeId = prefs.getString(_kLastNodeId);
    final offset = prefs.getDouble(_kHeadingOffset) ?? 0.0;
    if (x == null || y == null || nodeId == null) return null;
    return {'x': x, 'y': y, 'nodeId': nodeId, 'headingOffset': offset};
  }

  /// Menghapus data posisi terakhir yang tersimpan.
  Future<void> clearSavedPosition() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kLastX);
    await prefs.remove(_kLastY);
    await prefs.remove(_kLastNodeId);
    await prefs.remove(_kHeadingOffset);
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
    _positionProvider.dispose();
    _slotSubscription?.cancel();
    _repository?.dispose();
    userPositionNotifier.dispose();
    userHeadingNotifier.dispose();
    currentRouteNotifier.dispose();
    routeDistanceNotifier.dispose();
    super.dispose();
  }
}
