import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartparking/models/parking_models.dart';
import 'package:smartparking/services/a_star.dart';
import 'package:smartparking/services/graph_snap.dart';
import 'package:smartparking/services/navigation_controller.dart';
import 'package:smartparking/services/parking_repository.dart';
import 'package:smartparking/services/position_provider.dart';

void main() {
  group('A* Algorithm Tests', () {
    test('Menemukan rute terpendek di graf sederhana', () {
      final nodes = [
        const Node(id: 'A', x: 0, y: 0),
        const Node(id: 'B', x: 10, y: 0),
        const Node(id: 'C', x: 20, y: 0),
      ];

      final edges = [
        const Edge(from: 'A', to: 'B'),
        const Edge(from: 'B', to: 'C'),
      ];

      final path = AStar.findPath(
        nodes: nodes,
        edges: edges,
        startNodeId: 'A',
        targetNodeId: 'C',
      );

      expect(path, isNotNull);
      expect(path!.map((n) => n.id).toList(), ['A', 'B', 'C']);
      expect(AStar.calculatePathLength(path), 20.0);
    });
  });

  group('NavigationController & Dynamic Rerouting Tests', () {
    test('Inisialisasi memuat layout dan memilih lobby default', () async {
      final repo = MockParkingRepository();
      final controller = NavigationController(repository: repo);

      await Future.delayed(const Duration(milliseconds: 350));

      expect(controller.layout, isNotNull);
      expect(controller.selectedLobby, isNotNull);
      expect(controller.availableSlotsCount, greaterThan(0));
    });

    test('Memilih slot kosong terdekat otomatis dengan A*', () async {
      final repo = MockParkingRepository();
      final controller = NavigationController(repository: repo);

      await Future.delayed(const Duration(milliseconds: 350));

      controller.startNavigation();

      expect(controller.isNavigating, isTrue);
      expect(controller.targetSlot, isNotNull);
      expect(controller.targetSlot!.isAvailable, isTrue);
      expect(controller.currentRoute.isNotEmpty, isTrue);
      expect(controller.currentRouteDistance, greaterThan(0));
    });

    test('Dynamic rerouting terpicu ketika slot tujuan menjadi occupied', () async {
      final repo = MockParkingRepository();
      final controller = NavigationController(repository: repo);

      await Future.delayed(const Duration(milliseconds: 350));

      controller.startNavigation();
      final initialSlotId = controller.targetSlot!.id;

      // Simulasi slot tujuan terisi oleh kendaraan lain
      await controller.simulateTargetOccupied();

      // Tunggu timer rerouting 500ms
      await Future.delayed(const Duration(milliseconds: 700));

      // Harus dialihkan ke slot baru yang berbeda dan masih kosong
      expect(controller.targetSlot, isNotNull);
      expect(controller.targetSlot!.id, isNot(equals(initialSlotId)));
      expect(controller.targetSlot!.isAvailable, isTrue);
    });

    test('Tahap A: withSlotAccessNodes membuat node acc_<slotId> dan membelah lorong', () async {
      final repo = MockParkingRepository();
      final layout = await repo.getLayout();

      // Pastikan node akses untuk C1 dan A1 terbentuk di lorong
      final accC1 = layout.nodes.cast<Node?>().firstWhere((n) => n?.id == 'acc_C1', orElse: () => null);
      final accA1 = layout.nodes.cast<Node?>().firstWhere((n) => n?.id == 'acc_A1', orElse: () => null);

      expect(accC1, isNotNull);
      expect(accC1!.x, 9.0);
      expect(accC1.y, 12.0); // Lorong tengah

      expect(accA1, isNotNull);
      expect(accA1!.x, 8.0);
      expect(accA1.y, 5.0); // Lorong atas

      // Pastikan entryNodeId slot diperbarui
      final slotC1 = layout.slots.firstWhere((s) => s.id == 'C1');
      final slotA1 = layout.slots.firstWhere((s) => s.id == 'A1');
      expect(slotC1.entryNodeId, 'acc_C1');
      expect(slotA1.entryNodeId, 'acc_A1');
    });

    test('Tahap A: Dari Lobby 1, C1 harus menang atas A1 (~16.5m vs ~22.2m)', () async {
      final repo = MockParkingRepository();
      final controller = NavigationController(repository: repo);

      await Future.delayed(const Duration(milliseconds: 350));

      // Pastikan posisi di Lobby 1
      expect(controller.selectedLobby?.id, 'L1');

      // Evaluasi slot terbaik
      final bestSlot = controller.findBestAvailableSlot();

      // C1 harus menang atas A1
      expect(bestSlot, isNotNull);
      expect(bestSlot!.id, 'C1');
      expect(controller.targetSlot!.id, 'C1');

      // Jarak C1 harus sekitar 16.5 m (toleransi 0.2 m)
      expect(controller.currentRouteDistance, closeTo(16.5, 0.2));

      // Verifikasi rute C1 melalui [c_l1, m0, acc_C1, slot_C1]
      final routeIds = controller.currentRoute.map((n) => n.id).toList();
      expect(routeIds, ['c_l1', 'm0', 'acc_C1', 'slot_C1']);

      // Sekarang verifikasi jarak ke A1 jika dihitung secara manual
      final layout = controller.layout!;
      final pathA1 = AStar.findPath(
        nodes: layout.nodes,
        edges: layout.edges,
        startNodeId: 'c_l1',
        targetNodeId: 'acc_A1',
      );
      expect(pathA1, isNotNull);
      final fullRouteA1 = [...pathA1!, const Node(id: 'slot_A1', x: 8.0, y: 1.8)];
      final distA1 = AStar.calculatePathLength(fullRouteA1);

      // Jarak A1 harus sekitar 22.2 m (toleransi 0.2 m)
      expect(distA1, closeTo(22.2, 0.2));
      expect(controller.currentRouteDistance, lessThan(distA1));
    });

    test('Tahap A: startNavigation tidak memakai target lama jika sudah occupied', () async {
      final repo = MockParkingRepository();
      final controller = NavigationController(repository: repo);

      await Future.delayed(const Duration(milliseconds: 350));

      // Pilih C1 manual terlebih dahulu
      final slotC1 = controller.layout!.slots.firstWhere((s) => s.id == 'C1');
      controller.selectTargetSlot(slotC1);
      expect(controller.targetSlot?.id, 'C1');

      // Simulasikan C1 menjadi occupied sebelum startNavigation dipanggil
      await repo.updateSlotStatus('C1', SlotStatus.occupied);
      await Future.delayed(const Duration(milliseconds: 50));

      // Panggil startNavigation tanpa parameter (harus tolak C1 dan pilih ulang)
      controller.startNavigation();

      expect(controller.isNavigating, isTrue);
      expect(controller.targetSlot, isNotNull);
      // Target tidak boleh C1 lagi karena sudah occupied
      expect(controller.targetSlot!.id, isNot('C1'));
      expect(controller.targetSlot!.isAvailable, isTrue);
      // Target berikutnya yang menang harus A1 (22.2m)
      expect(controller.targetSlot!.id, 'A1');
    });

    test('Tahap B: Rute dari posisi di tengah lorong memiliki titik awal sama dengan titik snap', () async {
      final repo = MockParkingRepository();
      final fakeProvider = FakePositionProvider();
      final controller = NavigationController(
        repository: repo,
        positionProvider: fakeProvider,
      );

      await Future.delayed(const Duration(milliseconds: 350));

      // Pengguna berada di tengah lorong bawah antara c_l1 (x=4, y=20) dan c1 (x=14, y=20)
      // Koordinat: (10.0, 20.0)
      fakeProvider.emit(const Offset(10.0, 20.0));
      await Future.delayed(const Duration(milliseconds: 20));

      expect(controller.currentUserPosition, isNotNull);
      expect(controller.currentUserPosition!.x, closeTo(10.0, 0.01));
      expect(controller.currentUserPosition!.y, closeTo(20.0, 0.01));

      // Evaluasi rute slot terbaik
      final bestSlot = controller.findBestAvailableSlot();
      expect(bestSlot, isNotNull);
      expect(controller.currentRoute.isNotEmpty, isTrue);

      // Titik pertama rute HARUS sama dengan titik snap posisi pengguna
      final firstPoint = controller.currentRoute.first;
      expect(firstPoint.x, closeTo(10.0, 0.01));
      expect(firstPoint.y, closeTo(20.0, 0.01));
      expect(firstPoint.id, 'user_virtual');
    });

    test('Tahap B: Rerouting dari tengah jalur memulai rute baru dari posisi pengguna, bukan c_l1', () async {
      final repo = MockParkingRepository();
      final fakeProvider = FakePositionProvider();
      final controller = NavigationController(
        repository: repo,
        positionProvider: fakeProvider,
      );

      await Future.delayed(const Duration(milliseconds: 350));

      // Mulai navigasi (awalnya dari lobby c_l1)
      controller.startNavigation();
      expect(controller.isNavigating, isTrue);
      expect(controller.targetSlot?.id, 'C1');

      // Pengguna bergerak ke tengah lorong vertikal antara c_l1 (y=20) dan m0 (y=12)
      // Posisi di x=4.0, y=15.0
      fakeProvider.emit(const Offset(4.0, 15.0));
      await Future.delayed(const Duration(milliseconds: 20));

      expect(controller.currentUserPosition?.x, closeTo(4.0, 0.01));
      expect(controller.currentUserPosition?.y, closeTo(15.0, 0.01));

      // Simulasikan slot tujuan saat ini (C1) terisi oleh kendaraan lain
      await controller.simulateTargetOccupied();

      // Tunggu timer dynamic rerouting (500ms)
      await Future.delayed(const Duration(milliseconds: 700));

      // Navigasi dialihkan ke slot baru yang tersedia
      expect(controller.targetSlot, isNotNull);
      expect(controller.targetSlot!.id, isNot('C1'));
      expect(controller.currentRoute.isNotEmpty, isTrue);

      // Titik pertama rute baru HARUS dimulai dari posisi pengguna saat ini (y=15.0), BUKAN c_l1 (y=20.0)
      final firstNode = controller.currentRoute.first;
      expect(firstNode.id, isNot('c_l1'));
      expect(firstNode.x, closeTo(4.0, 0.01));
      expect(firstNode.y, closeTo(15.0, 0.01));
    });

    test('Tahap B: Deteksi tiba di slot (< 1.5m) menghentikan navigasi dan provider', () async {
      final repo = MockParkingRepository();
      final fakeProvider = FakePositionProvider();
      final controller = NavigationController(
        repository: repo,
        positionProvider: fakeProvider,
      );

      await Future.delayed(const Duration(milliseconds: 350));

      controller.startNavigation();
      expect(controller.isNavigating, isTrue);
      final target = controller.targetSlot!;

      // Mobil bergerak mendekati target slot hingga jarak < 1.5m
      fakeProvider.emit(Offset(target.x, target.y + 0.8));
      await Future.delayed(const Duration(milliseconds: 20));

      expect(controller.isNavigating, isFalse);
      expect(controller.statusBanner, contains('Anda sudah tiba di slot ${target.id}'));
      expect(fakeProvider.isStopped, isTrue);
    });
  });

  group('snapToGraph Tests', () {
    final nodes = [
      const Node(id: 'A', x: 0, y: 0),
      const Node(id: 'B', x: 10, y: 0),
      const Node(id: 'Z1', x: 20, y: 20),
      const Node(id: 'Z2', x: 20, y: 20),
    ];
    final edges = [
      const Edge(from: 'A', to: 'B'),
      const Edge(from: 'Z1', to: 'Z2'), // Edge panjang nol
    ];

    test('titik di tengah edge', () {
      final result = snapToGraph(const Offset(5.0, 2.0), nodes, edges);
      expect(result, isNotNull);
      expect(result!.snappedPosition.dx, 5.0);
      expect(result.snappedPosition.dy, 0.0);
      expect(result.t, closeTo(0.5, 0.001));
      expect(result.distance, closeTo(2.0, 0.001));
      expect(result.isOffGraph, isFalse);
      expect(result.edge.from, 'A');
      expect(result.edge.to, 'B');
    });

    test('titik dekat ujung edge', () {
      final result = snapToGraph(const Offset(12.0, 0.0), nodes, edges);
      expect(result, isNotNull);
      expect(result!.snappedPosition.dx, 10.0);
      expect(result.snappedPosition.dy, 0.0);
      expect(result.t, 1.0);
      expect(result.distance, closeTo(2.0, 0.001));
      expect(result.isOffGraph, isFalse);
    });

    test('titik jauh (off-graph)', () {
      final result = snapToGraph(const Offset(5.0, 10.0), nodes, edges);
      expect(result, isNotNull);
      expect(result!.isOffGraph, isTrue);
      expect(result.distance, closeTo(10.0, 0.001));
    });

    test('edge panjang nol ditangani dengan aman tanpa divide-by-zero', () {
      final zeroNodes = [
        const Node(id: 'Z1', x: 20, y: 20),
        const Node(id: 'Z2', x: 20, y: 20),
      ];
      final zeroEdges = [const Edge(from: 'Z1', to: 'Z2')];
      final result = snapToGraph(const Offset(23.0, 20.0), zeroNodes, zeroEdges);
      expect(result, isNotNull);
      expect(result!.snappedPosition.dx, 20.0);
      expect(result.snappedPosition.dy, 20.0);
      expect(result.t, 0.0);
      expect(result.distance, closeTo(3.0, 0.001));
    });
  });

  group('PositionProvider Tests', () {
    test('SimulatedPositionProvider berjalan sepanjang rute dan mendukung pause/resume', () async {
      final provider = SimulatedPositionProvider(initialSpeed: 10.0);
      final emitted = <UserPosition>[];
      final sub = provider.positions.listen(emitted.add);

      provider.start();
      provider.onRouteChanged([
        const Offset(0, 0),
        const Offset(10, 0),
      ]);

      await Future.delayed(const Duration(milliseconds: 250));

      expect(emitted.isNotEmpty, isTrue);
      expect(emitted.first.position.dx, greaterThanOrEqualTo(0));
      expect(provider.isRunning, isTrue);

      provider.pause();
      expect(provider.isPaused, isTrue);

      provider.resume();
      expect(provider.isPaused, isFalse);

      provider.stop();
      expect(provider.isRunning, isFalse);

      await sub.cancel();
      provider.dispose();
    });

    test('ManualPositionProvider memancarkan posisi saat setPosition dipanggil', () async {
      final provider = ManualPositionProvider();
      final emitted = <UserPosition>[];
      final sub = provider.positions.listen(emitted.add);

      provider.start();
      provider.setPosition(const Offset(15.0, 12.0), headingDeg: 90.0);

      await Future.delayed(const Duration(milliseconds: 20));

      expect(emitted.length, 1);
      expect(emitted.first.position.dx, 15.0);
      expect(emitted.first.position.dy, 12.0);
      expect(emitted.first.headingDeg, 90.0);

      await sub.cancel();
      provider.dispose();
    });
  });
}

/// Fake PositionProvider untuk pengujian deterministik berbasis stream controller
class FakePositionProvider implements PositionProvider {
  final _controller = StreamController<UserPosition>.broadcast();
  List<Offset>? lastRoute;
  bool isStarted = false;
  bool isStopped = false;

  @override
  Stream<UserPosition> get positions => _controller.stream;

  void emit(Offset position, {double? headingDeg}) {
    _controller.add(UserPosition(
      position: position,
      headingDeg: headingDeg,
      timestamp: DateTime.now(),
    ));
  }

  @override
  void start() {
    isStarted = true;
    isStopped = false;
  }

  @override
  void stop() {
    isStopped = true;
    isStarted = false;
  }

  @override
  void dispose() {
    _controller.close();
  }

  @override
  void onRouteChanged(List<Offset> route) {
    lastRoute = route;
  }
}
