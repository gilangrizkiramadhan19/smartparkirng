import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartparking/models/map_data.dart';
import 'package:smartparking/models/parking_models.dart';
import 'package:smartparking/services/a_star.dart';
import 'package:smartparking/services/graph_snap.dart';
import 'package:smartparking/services/map_repository.dart';
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
      // Koordinat: (10.0, 20.0) dipindahkan dengan force: true
      controller.setManualPosition(const Offset(10.0, 20.0), force: true);
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
      // Posisi di x=4.0, y=15.0 dipindahkan dengan force: true
      controller.setManualPosition(const Offset(4.0, 15.0), force: true);
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

      // Simulasikan minimal 3 langkah dan progres >= 50%
      controller.recordStep();
      controller.recordStep();
      controller.recordStep();

      // Mobil bergerak mendekati target slot hingga jarak < 1.5m dengan force: true
      controller.setManualPosition(Offset(target.x, target.y + 0.8), force: true);
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

  group('Tahap 2, 3, 4: Indoor Map Navigation, Arrival Rules & Dari/Ke Tests', () {
    late MapData realMapData;

    setUpAll(() {
      final file = File('assets/maps/map.json');
      expect(file.existsSync(), isTrue);
      final jsonStr = file.readAsStringSync();
      realMapData = MapRepository().parseAndValidate(jsonStr);
    });

    test('Tahap 2: Memilih tujuan dekat 1.0m (Ruang tamu dari pintu masuk teras) TIDAK langsung set tiba', () async {
      final fakeProvider = FakePositionProvider();
      final controller = NavigationController(
        mapRepository: TestMapRepository(realMapData),
        positionProvider: fakeProvider,
      );

      await Future.delayed(const Duration(milliseconds: 100));

      // Atur titik awal ke n1 (pintu masuk teras: x: 23, y: 24.5)
      final n1 = controller.currentFloor!.findNodeById('n1')!;
      controller.setStartNode(n1);
      expect(controller.currentUserPosition!.x, 23.0);
      expect(controller.currentUserPosition!.y, 24.5);

      // Pilih tujuan ke n4 (Ruang tamu: x: 23, y: 23.5) - jarak rute 1.0 m
      final n4 = controller.currentFloor!.findNodeById('n4')!;
      controller.selectDestination(n4);

      // Navigasi BELUM berjalan
      expect(controller.isNavigating, isFalse);
      // Rute preview harus terbentuk dengan panjang 1.0 m
      expect(controller.currentRoute.isNotEmpty, isTrue);
      expect(controller.currentRouteDistance, 1.0);
      // Status banner HARUS rute preview, BUKAN 'tiba'
      expect(controller.statusBanner, contains('Rute ke "Ruang tamu" (1.0 m)'));
      expect(controller.statusBanner, isNot(contains('tiba')));
      expect(controller.statusBanner, isNot(contains('berada di lokasi ini')));
    });

    test('Tahap 2: startRouteNavigation pada rute dekat <= 2.0m menampilkan "Anda sudah dekat tujuan" dan tidak auto-selesai', () async {
      final fakeProvider = FakePositionProvider();
      final controller = NavigationController(
        mapRepository: TestMapRepository(realMapData),
        positionProvider: fakeProvider,
      );

      await Future.delayed(const Duration(milliseconds: 100));

      final n1 = controller.currentFloor!.findNodeById('n1')!;
      final n4 = controller.currentFloor!.findNodeById('n4')!;
      controller.setStartNode(n1);
      controller.selectDestination(n4);

      // Mulai navigasi rute (panjang 1.0 m <= ambang 2.0 m)
      final started = controller.startRouteNavigation();
      expect(started, isTrue);
      expect(controller.isNavigating, isTrue);
      // Status banner HARUS 'Anda sudah dekat tujuan' dan tidak auto-selesai
      expect(controller.statusBanner, contains('Anda sudah dekat tujuan'));

      // Posisi pengguna bergerak mendekati tujuan n4
      fakeProvider.emit(const Offset(23.0, 23.6));
      await Future.delayed(const Duration(milliseconds: 20));

      // Pengguna MASIH bernavigasi dan TIDAK auto-selesai
      expect(controller.isNavigating, isTrue);
      expect(controller.statusBanner, contains('Anda sudah dekat tujuan'));

      // Selesai saat user menekan selesai manual
      controller.completeArrival();
      expect(controller.isNavigating, isFalse);
      expect(controller.statusBanner, contains('Anda telah tiba di Ruang tamu'));
    });

    test('Tahap 2: Memilih tujuan yang sama persis dengan titik awal menampilkan info sesuai', () async {
      final fakeProvider = FakePositionProvider();
      final controller = NavigationController(
        mapRepository: TestMapRepository(realMapData),
        positionProvider: fakeProvider,
      );

      await Future.delayed(const Duration(milliseconds: 100));

      final n1 = controller.currentFloor!.findNodeById('n1')!;
      controller.setStartNode(n1);
      controller.selectDestination(n1);

      expect(controller.isNavigating, isFalse);
      // Banner sekarang berisi peringatan untuk pilih tujuan lain (karena start == dest, tujuan dipertahankan)
      expect(controller.statusBanner, contains('pilih tujuan lain'));
    });

    test('Tahap 3: swapStartAndDestination menukar posisi titik awal dan titik tujuan', () async {
      final fakeProvider = FakePositionProvider();
      final controller = NavigationController(
        mapRepository: TestMapRepository(realMapData),
        positionProvider: fakeProvider,
      );

      await Future.delayed(const Duration(milliseconds: 100));

      final n1 = controller.currentFloor!.findNodeById('n1')!;
      final n6 = controller.currentFloor!.findNodeById('n6')!; // Dapur
      controller.setStartNode(n1);
      controller.selectDestination(n6);

      expect(controller.startNode?.id, 'n1');
      expect(controller.targetDestination?.id, 'n6');

      controller.swapStartAndDestination();

      expect(controller.startNode?.id, 'n6');
      expect(controller.targetDestination?.id, 'n1');
      expect(controller.currentRoute.isNotEmpty, isTrue);
      expect(controller.currentRoute.first.id, 'n6');
      expect(controller.currentRoute.last.id, 'n1');
    });

    test('Tahap 4: Default positionMode adalah manual (tidak ada auto-simulasi pergerakan)', () async {
      final controller = NavigationController(
        mapRepository: TestMapRepository(realMapData),
        positionProvider: ManualPositionProvider(),
      );

      await Future.delayed(const Duration(milliseconds: 100));

      expect(controller.positionMode, NavigationPositionMode.manual);
    });
  });

  group('State Separation: startNode vs destinationNode', () {
    late MapData realMapData;

    setUpAll(() {
      final file = File('assets/maps/map.json');
      expect(file.existsSync(), isTrue);
      final jsonStr = file.readAsStringSync();
      realMapData = MapRepository().parseAndValidate(jsonStr);
    });

    test('setStartNode TIDAK mengubah destinationNode yang sudah dipilih', () async {
      final fakeProvider = FakePositionProvider();
      final controller = NavigationController(
        mapRepository: TestMapRepository(realMapData),
        positionProvider: fakeProvider,
      );
      await Future.delayed(const Duration(milliseconds: 100));

      final n1 = controller.currentFloor!.findNodeById('n1')!; // pintu masuk teras
      final n11 = controller.currentFloor!.findNodeById('n11')!; // ruang tengah

      // Pilih tujuan dulu
      controller.selectDestination(n11);
      expect(controller.targetDestination?.id, 'n11');

      // Set posisi awal ke n1 — TIDAK boleh mengubah tujuan n11
      controller.setStartNode(n1);
      expect(controller.targetDestination?.id, 'n11',
          reason: 'setStartNode harus mempertahankan destinationNode yang sudah ada');
      expect(controller.startNode?.id, 'n1');
    });

    test('resetUserPositionAndStartNode TIDAK menghapus destinationNode', () async {
      final fakeProvider = FakePositionProvider();
      final controller = NavigationController(
        mapRepository: TestMapRepository(realMapData),
        positionProvider: fakeProvider,
      );
      await Future.delayed(const Duration(milliseconds: 100));

      final n1 = controller.currentFloor!.findNodeById('n1')!;
      final n11 = controller.currentFloor!.findNodeById('n11')!;

      controller.setStartNode(n1);
      controller.selectDestination(n11);
      expect(controller.targetDestination?.id, 'n11');

      // Reset posisi awal (simulasi masuk halaman AR)
      controller.resetUserPositionAndStartNode();

      // destinationNode HARUS tetap ada
      expect(controller.targetDestination?.id, 'n11',
          reason: 'resetUserPositionAndStartNode harus mempertahankan destinationNode');
      expect(controller.startNode, isNull);
    });

    test('setStartNode mengembalikan false dan mempertahankan destinationNode saat start == dest', () async {
      final fakeProvider = FakePositionProvider();
      final controller = NavigationController(
        mapRepository: TestMapRepository(realMapData),
        positionProvider: fakeProvider,
      );
      await Future.delayed(const Duration(milliseconds: 100));

      final n11 = controller.currentFloor!.findNodeById('n11')!;

      // Pilih tujuan n11 (ruang tengah) dulu tanpa set start
      controller.selectDestination(n11);

      // Sekarang coba set start ke n11 juga (sama dengan tujuan)
      final ok = controller.setStartNode(n11);

      expect(ok, isFalse, reason: 'setStartNode harus return false saat start == dest');
      // destinationNode HARUS tetap n11 (tidak dihapus/ditimpa)
      expect(controller.targetDestination?.id, 'n11',
          reason: 'destinationNode harus tetap ada walau start == dest');
      // Banner harus berisi peringatan
      expect(controller.statusBanner, contains('pilih tujuan lain'));
    });

    test('selectDestination tidak mengubah destinationNode jika dest == startNode yang sudah ada', () async {
      final fakeProvider = FakePositionProvider();
      final controller = NavigationController(
        mapRepository: TestMapRepository(realMapData),
        positionProvider: fakeProvider,
      );
      await Future.delayed(const Duration(milliseconds: 100));

      final n1 = controller.currentFloor!.findNodeById('n1')!;
      final n11 = controller.currentFloor!.findNodeById('n11')!;

      controller.setStartNode(n1);
      controller.selectDestination(n11); // tujuan awal = n11
      expect(controller.targetDestination?.id, 'n11');

      // User coba pilih n1 (posisi mereka sendiri) sebagai tujuan
      controller.selectDestination(n1);

      // Tujuan TIDAK boleh berubah ke n1
      expect(controller.targetDestination?.id, 'n11',
          reason: 'selectDestination harus menolak jika dest == startNode, tujuan lama dipertahankan');
      expect(controller.statusBanner, contains('pilih tujuan lain'));
    });

    test('startNavigation pada denah indoor tanpa slot TIDAK menimpa destinationNode dengan availableDestinations.first', () async {
      final fakeProvider = FakePositionProvider();
      final controller = NavigationController(
        mapRepository: TestMapRepository(realMapData),
        positionProvider: fakeProvider,
      );
      await Future.delayed(const Duration(milliseconds: 100));

      final n11 = controller.currentFloor!.findNodeById('n11')!;

      // Set tujuan = n11 (ruang tengah)
      controller.selectDestination(n11);
      expect(controller.targetDestination?.id, 'n11');

      // startNavigation tanpa startNode (simulasi sebelum kalibrasi wizard)
      controller.startNavigation();

      // destinationNode TIDAK boleh berubah ke n1 atau apapun
      expect(controller.targetDestination?.id, 'n11',
          reason: 'startNavigation tidak boleh overwrite destinationNode dengan availableDestinations.first');
    });

    test('Rute dihitung ulang ke destinationNode setelah startNode diubah', () async {
      final fakeProvider = FakePositionProvider();
      final controller = NavigationController(
        mapRepository: TestMapRepository(realMapData),
        positionProvider: fakeProvider,
      );
      await Future.delayed(const Duration(milliseconds: 100));

      final n1 = controller.currentFloor!.findNodeById('n1')!;
      final n6 = controller.currentFloor!.findNodeById('n6')!; // Dapur
      final n11 = controller.currentFloor!.findNodeById('n11')!; // Ruang tengah

      // Pilih tujuan = ruang tengah
      controller.selectDestination(n11);

      // Set posisi awal ke n1 → rute harus ke n11
      controller.setStartNode(n1);
      expect(controller.targetDestination?.id, 'n11');
      final distFromN1 = controller.currentRouteDistance;
      expect(distFromN1, greaterThan(0.05));

      // Ganti posisi awal ke n6 (dapur) → rute harus ke n11 dari n6
      controller.setStartNode(n6);
      expect(controller.targetDestination?.id, 'n11',
          reason: 'destinationNode harus tetap n11 setelah ganti startNode');
      final distFromN6 = controller.currentRouteDistance;
      expect(distFromN6, greaterThan(0.05));

      // Jarak dari n6 ke n11 vs n1 ke n11 bisa sama atau berbeda tergantung denah.
      // Yang penting: rute dimulai dari node yang berbeda (n6 bukan n1).
      expect(controller.currentRoute.first.id, 'n6',
          reason: 'Rute harus dimulai dari n6 (Dapur) setelah ganti startNode');
    });
  });

  group('Route Progress & Arrival Detection Tests', () {
    late MapData realMapData;

    setUpAll(() {
      final file = File('assets/maps/map.json');
      expect(file.existsSync(), isTrue);
      final jsonStr = file.readAsStringSync();
      realMapData = MapRepository().parseAndValidate(jsonStr);
    });

    test('Arrival terpicu ketika sisa jarak sepanjang rute <= ambang, langkah >= 3, dan progres >= 50%', () async {
      final fakeProvider = FakePositionProvider();
      final controller = NavigationController(
        mapRepository: TestMapRepository(realMapData),
        positionProvider: fakeProvider,
      );
      await Future.delayed(const Duration(milliseconds: 100));

      final n1 = controller.currentFloor!.findNodeById('n1')!; // Pintu masuk teras
      final n11 = controller.currentFloor!.findNodeById('n11')!; // Ruang tengah (~5.0m)

      controller.selectDestination(n11);
      controller.setStartNode(n1);

      final started = controller.startRouteNavigation();
      expect(started, isTrue);
      expect(controller.isNavigating, isTrue);
      expect(controller.currentRouteDistance, greaterThan(3.0));

      // Catat 3 langkah
      controller.recordStep();
      controller.recordStep();
      controller.recordStep();
      expect(controller.stepsSinceStart, 3);

      // Simulasikan user bergerak mendekati tujuan (0.8 m sebelum n11, progres > 50%)
      final n11Pos = Offset(n11.x, n11.y);
      controller.setManualPosition(Offset(n11Pos.dx, n11Pos.dy + 0.8), force: true);

      // Sisa jarak <= ambang dan semua syarat terpenuhi -> tiba
      expect(controller.isNavigating, isFalse, reason: 'Navigasi harus selesai saat tiba');
      expect(controller.statusBanner, contains('Anda telah tiba di ${n11.name}'));
      expect(controller.currentRoute, isEmpty, reason: 'Rute harus dikosongkan setelah tiba');
      expect(controller.routeProgress, equals(1.0));
    });

    test('Arrival TIDAK terpicu jika sisa jarak masih > 2.0 m dan progres rute terhitung', () async {
      final fakeProvider = FakePositionProvider();
      final controller = NavigationController(
        mapRepository: TestMapRepository(realMapData),
        positionProvider: fakeProvider,
      );
      await Future.delayed(const Duration(milliseconds: 100));

      final n1 = controller.currentFloor!.findNodeById('n1')!;
      final n11 = controller.currentFloor!.findNodeById('n11')!;

      controller.selectDestination(n11);
      controller.setStartNode(n1);
      controller.startRouteNavigation();

      expect(controller.isNavigating, isTrue);

      // Gerakkan user sepanjang jalur ke arah n2 (y: 24.5 -> 24.1)
      final n1Pos = Offset(n1.x, n1.y);
      controller.setManualPosition(Offset(n1Pos.dx, n1Pos.dy - 0.4));

      expect(controller.isNavigating, isTrue, reason: 'Navigasi tetap berjalan jika sisa jarak > 2.0m');
      expect(controller.routeProgress, greaterThan(0.0));
      expect(controller.routeProgress, lessThan(1.0));
    });

    test('completeArrival ("Saya sudah sampai") menyelesaikan navigasi dan menghentikan rute', () async {
      final fakeProvider = FakePositionProvider();
      final controller = NavigationController(
        mapRepository: TestMapRepository(realMapData),
        positionProvider: fakeProvider,
      );
      await Future.delayed(const Duration(milliseconds: 100));

      final n1 = controller.currentFloor!.findNodeById('n1')!;
      final n11 = controller.currentFloor!.findNodeById('n11')!;

      controller.selectDestination(n11);
      controller.setStartNode(n1);
      controller.startRouteNavigation();

      expect(controller.isNavigating, isTrue);

      // User menekan "Saya sudah sampai"
      controller.completeArrival();

      expect(controller.isNavigating, isFalse);
      expect(controller.statusBanner, contains('Anda telah tiba di ${n11.name}'));
      expect(controller.currentRoute, isEmpty);
    });

    test('correctPositionToNode mengoreksi posisi dan menghitung ulang rute ke tujuan yang sama', () async {
      final fakeProvider = FakePositionProvider();
      final controller = NavigationController(
        mapRepository: TestMapRepository(realMapData),
        positionProvider: fakeProvider,
      );
      await Future.delayed(const Duration(milliseconds: 100));

      final n1 = controller.currentFloor!.findNodeById('n1')!;
      final n2 = controller.currentFloor!.findNodeById('n2')!; // Pintu masuk rumah (> 2.5m dari n11)
      final n11 = controller.currentFloor!.findNodeById('n11')!; // Ruang tengah

      controller.selectDestination(n11);
      controller.setStartNode(n1);
      controller.startRouteNavigation();

      expect(controller.isNavigating, isTrue);

      // Dead reckoning melenceng, user menekan koreksi posisi ke n2
      controller.correctPositionToNode(n2);

      expect(controller.isNavigating, isTrue);
      expect(controller.currentUserPosition?.x, closeTo(n2.x, 0.05));
      expect(controller.currentUserPosition?.y, closeTo(n2.y, 0.05));
      expect(controller.targetDestination?.id, 'n11', reason: 'Tujuan tetap ke Ruang tengah');
      expect(controller.currentRoute.isNotEmpty, isTrue);
    });
  });

  group('Requirement 6: Strict Arrival & Step Displacement Unit Tests', () {
    late MapData realMapData;

    setUpAll(() {
      final file = File('assets/maps/map.json');
      expect(file.existsSync(), isTrue);
      final jsonStr = file.readAsStringSync();
      realMapData = MapRepository().parseAndValidate(jsonStr);
    });

    test('Unit test 1: tidak tiba sebelum Mulai (isNavigating == false)', () async {
      final fakeProvider = FakePositionProvider();
      final controller = NavigationController(
        mapRepository: TestMapRepository(realMapData),
        positionProvider: fakeProvider,
      );
      await Future.delayed(const Duration(milliseconds: 100));

      final n1 = controller.currentFloor!.findNodeById('n1')!;
      final n11 = controller.currentFloor!.findNodeById('n11')!;

      controller.setStartNode(n1);
      controller.selectDestination(n11);

      // Sebelum Mulai Navigasi ditekan:
      expect(controller.isNavigating, isFalse);

      // Gerakkan posisi user persis di titik tujuan n11
      controller.setManualPosition(Offset(n11.x, n11.y), force: true);

      // Syarat tiba TIDAK boleh dievaluasi sebelum Mulai ditekan
      expect(controller.isNavigating, isFalse);
      expect(controller.statusBanner, isNot(contains('Anda telah tiba')));
    });

    test('Unit test 2: tidak tiba jika langkah < 3 atau progres < 50%', () async {
      final fakeProvider = FakePositionProvider();
      final controller = NavigationController(
        mapRepository: TestMapRepository(realMapData),
        positionProvider: fakeProvider,
      );
      await Future.delayed(const Duration(milliseconds: 100));

      final n1 = controller.currentFloor!.findNodeById('n1')!;
      final n11 = controller.currentFloor!.findNodeById('n11')!;

      controller.setStartNode(n1);
      controller.selectDestination(n11);
      controller.startRouteNavigation();
      expect(controller.isNavigating, isTrue);

      // Kasus A: Jarak sudah dekat tujuan (< 1.0 m), tetapi langkah baru 2 (< 3)
      controller.recordStep();
      controller.recordStep();
      expect(controller.stepsSinceStart, 2);

      controller.setManualPosition(Offset(n11.x, n11.y + 0.8), force: true);
      expect(controller.isNavigating, isTrue, reason: 'Tidak boleh tiba karena langkah < 3');
      expect(controller.statusBanner, isNot(contains('Anda telah tiba')));

      // Reset navigasi untuk Kasus B
      controller.startRouteNavigation();
      expect(controller.isNavigating, isTrue);

      // Kasus B: Langkah >= 3, tetapi posisi masih di titik awal (progres < 50%)
      controller.recordStep();
      controller.recordStep();
      controller.recordStep();
      expect(controller.stepsSinceStart, 3);

      controller.setManualPosition(Offset(n1.x, n1.y), force: true);
      expect(controller.isNavigating, isTrue, reason: 'Tidak boleh tiba karena progres < 50%');
      expect(controller.statusBanner, isNot(contains('Anda telah tiba')));
    });

    test('Unit test 3: tiba saat semua syarat terpenuhi (jarak <= ambang, langkah >= 3, progres >= 50%)', () async {
      final fakeProvider = FakePositionProvider();
      final controller = NavigationController(
        mapRepository: TestMapRepository(realMapData),
        positionProvider: fakeProvider,
      );
      await Future.delayed(const Duration(milliseconds: 100));

      final n1 = controller.currentFloor!.findNodeById('n1')!;
      final n11 = controller.currentFloor!.findNodeById('n11')!;

      controller.setStartNode(n1);
      controller.selectDestination(n11);
      controller.startRouteNavigation();
      expect(controller.isNavigating, isTrue);

      // Penuhi syarat: 3 langkah tercatat
      controller.recordStep();
      controller.recordStep();
      controller.recordStep();
      expect(controller.stepsSinceStart, 3);

      // Gerakkan user mendekati tujuan sehingga progres >= 50% dan sisa jarak <= ambang (<= 1.25m)
      controller.setManualPosition(Offset(n11.x, n11.y + 0.8), force: true);

      // Semua syarat terpenuhi -> tiba!
      expect(controller.isNavigating, isFalse);
      expect(controller.statusBanner, contains('Anda telah tiba di ${n11.name}'));
    });

    test('Unit test 4: posisi tidak meloncat lebih dari satu langkah per update (displacement <= 0.75m)', () async {
      final fakeProvider = FakePositionProvider();
      final controller = NavigationController(
        mapRepository: TestMapRepository(realMapData),
        positionProvider: fakeProvider,
      );
      await Future.delayed(const Duration(milliseconds: 100));

      final n1 = controller.currentFloor!.findNodeById('n1')!;
      controller.setStartNode(n1); // Posisi awal di (23.0, 24.5)

      final initialPos = Offset(controller.currentUserPosition!.x, controller.currentUserPosition!.y);
      expect(initialPos.dx, 23.0);
      expect(initialPos.dy, 24.5);

      // Kirim pembaruan posisi ekstrem yang melompat jauh (misal loncat 15 meter ke x: 38.0, y: 10.0)
      controller.setManualPosition(const Offset(38.0, 10.0));

      final updatedPos = Offset(controller.currentUserPosition!.x, controller.currentUserPosition!.y);
      final displacement = (updatedPos - initialPos).distance;

      // Pergeseran harus dibatasi maksimal panjang satu langkah (<= 0.75 meter)
      expect(displacement, lessThanOrEqualTo(0.75 + 1e-4),
          reason: 'Pergeseran posisi per update tidak boleh melebihi 0.75 m');
    });

    test('BUG 1 & BUG 2 fix: setelah tiba di tujuan X, reset, setStartNode(node lain), pilih tujuan X -> hasArrived false, isNavigating false, posisi persis koordinat node awal', () async {
      final controller = NavigationController(
        mapRepository: TestMapRepository(realMapData),
      );
      await Future.delayed(const Duration(milliseconds: 100));

      final n1 = controller.currentFloor!.findNodeById('n1')!;
      final n11 = controller.currentFloor!.findNodeById('n11')!; // Ruang tamu (tujuan X)
      final n4 = controller.currentFloor!.findNodeById('n4')!;   // Ruang server (node lain)

      // 1. Set titik awal ke n1 dan tujuan ke n11 (tujuan X), lalu mulai navigasi
      controller.setStartNode(n1);
      await Future.delayed(const Duration(milliseconds: 50));
      controller.selectDestination(n11);
      controller.startRouteNavigation();
      expect(controller.isNavigating, isTrue);

      // 2. Tiba di tujuan X
      controller.completeArrival();
      expect(controller.hasArrived, isTrue);
      expect(controller.isNavigating, isFalse);

      // 3. Panggil resetUserPositionAndStartNode
      controller.resetUserPositionAndStartNode();
      expect(controller.hasArrived, isFalse);
      expect(controller.isNavigating, isFalse);

      // 4. setStartNode(node lain, misal n4)
      controller.setStartNode(n4);
      // Biarkan stream provider manual memproses update posisi
      await Future.delayed(const Duration(milliseconds: 50));

      // 5. Pilih tujuan X lagi
      controller.selectDestination(n11);

      // 6. Verifikasi kondisi akhir:
      // - hasArrived false
      // - isNavigating false
      // - posisi user sama persis dengan koordinat node awal (n4)
      expect(controller.hasArrived, isFalse);
      expect(controller.isNavigating, isFalse);
      expect(controller.currentUserPosition, isNotNull);
      expect(controller.currentUserPosition!.x, n4.x);
      expect(controller.currentUserPosition!.y, n4.y);
    });
  });
}

/// Mock MapRepository yang menyuplai data peta instan untuk testing
class TestMapRepository extends MapRepository {
  final MapData testData;
  TestMapRepository(this.testData);

  @override
  Future<MapData> loadFromAsset([String assetPath = MapRepository.defaultMapAssetPath]) async {
    return testData;
  }
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
