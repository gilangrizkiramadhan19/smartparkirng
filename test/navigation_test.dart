import 'package:flutter_test/flutter_test.dart';
import 'package:smartparking/models/parking_models.dart';
import 'package:smartparking/services/a_star.dart';
import 'package:smartparking/services/navigation_controller.dart';
import 'package:smartparking/services/parking_repository.dart';

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
  });
}
