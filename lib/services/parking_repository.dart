import 'dart:async';
import '../models/parking_models.dart';

/// Kontrak repositori data parkir ke backend / server.
abstract class ParkingRepository {
  /// Mengambil denah parkir lengkap (layout, node, edge, slot, lobby).
  Future<ParkingLayout> getLayout();

  /// Stream update status slot realtime (WebSocket/SSE).
  Stream<SlotUpdate> getSlotUpdates();

  /// Memperbarui status slot (berguna untuk simulasi / request).
  Future<void> updateSlotStatus(String slotId, SlotStatus status);

  /// Membersihkan resource / koneksi stream.
  void dispose();
}

/// Implementasi tiruan (Mock) dari [ParkingRepository] untuk pengujian lokal
/// tanpa perlu server backend fisik.
class MockParkingRepository implements ParkingRepository {
  final _updateController = StreamController<SlotUpdate>.broadcast();

  // Cache layout internal untuk menyimpan perubahan state secara realtime
  late ParkingLayout _currentLayout;

  MockParkingRepository() {
    _currentLayout = _createInitialMockLayout();
  }

  @override
  Future<ParkingLayout> getLayout() async {
    // Simulasi latency jaringan 300ms
    await Future.delayed(const Duration(milliseconds: 300));
    return _currentLayout;
  }

  @override
  Stream<SlotUpdate> getSlotUpdates() {
    return _updateController.stream;
  }

  @override
  Future<void> updateSlotStatus(String slotId, SlotStatus status) async {
    final updatedSlots = _currentLayout.slots.map((slot) {
      if (slot.id == slotId) {
        return slot.copyWith(status: status);
      }
      return slot;
    }).toList();

    _currentLayout = ParkingLayout(
      width: _currentLayout.width,
      height: _currentLayout.height,
      lobbies: _currentLayout.lobbies,
      nodes: _currentLayout.nodes,
      edges: _currentLayout.edges,
      slots: updatedSlots,
    );

    _updateController.add(SlotUpdate(
      slotId: slotId,
      status: status,
      timestamp: DateTime.now(),
    ));
  }

  @override
  void dispose() {
    _updateController.close();
  }

  /// Membuat layout parkir tiruan (50m x 26m) yang realistis.
  static ParkingLayout _createInitialMockLayout() {
    // 1. Lobby titik masuk
    final lobbies = [
      const Lobby(
        id: 'L1',
        name: 'Lobby 1 (Utama / Barat)',
        entryNodeId: 'c_l1',
        x: 4.0,
        y: 23.0,
      ),
      const Lobby(
        id: 'L2',
        name: 'Lobby 2 (Lift Timur)',
        entryNodeId: 'c_l2',
        x: 46.0,
        y: 23.0,
      ),
    ];

    // 2. Nodes (titik persimpangan lorong berkendara dalam meter)
    // Lorong Bawah (y = 20.0m)
    // Lorong Tengah (y = 12.0m)
    // Lorong Atas (y = 5.0m)
    final nodes = [
      // Lorong Bawah (Masuk dari Lobby)
      const Node(id: 'c_l1', x: 4.0, y: 20.0),
      const Node(id: 'c1', x: 14.0, y: 20.0),
      const Node(id: 'c2', x: 25.0, y: 20.0),
      const Node(id: 'c3', x: 36.0, y: 20.0),
      const Node(id: 'c_l2', x: 46.0, y: 20.0),

      // Lorong Tengah
      const Node(id: 'm0', x: 4.0, y: 12.0),
      const Node(id: 'm1', x: 14.0, y: 12.0),
      const Node(id: 'm2', x: 25.0, y: 12.0),
      const Node(id: 'm3', x: 36.0, y: 12.0),
      const Node(id: 'm4', x: 46.0, y: 12.0),

      // Lorong Atas
      const Node(id: 't0', x: 4.0, y: 5.0),
      const Node(id: 't1', x: 14.0, y: 5.0),
      const Node(id: 't2', x: 25.0, y: 5.0),
      const Node(id: 't3', x: 36.0, y: 5.0),
      const Node(id: 't4', x: 46.0, y: 5.0),
    ];

    // 3. Edges (lintasan jalan antar node, dua arah)
    final edges = [
      // Jalur horizontal lorong bawah
      const Edge(from: 'c_l1', to: 'c1'),
      const Edge(from: 'c1', to: 'c2'),
      const Edge(from: 'c2', to: 'c3'),
      const Edge(from: 'c3', to: 'c_l2'),

      // Jalur horizontal lorong tengah
      const Edge(from: 'm0', to: 'm1'),
      const Edge(from: 'm1', to: 'm2'),
      const Edge(from: 'm2', to: 'm3'),
      const Edge(from: 'm3', to: 'm4'),

      // Jalur horizontal lorong atas
      const Edge(from: 't0', to: 't1'),
      const Edge(from: 't1', to: 't2'),
      const Edge(from: 't2', to: 't3'),
      const Edge(from: 't3', to: 't4'),

      // Jalur vertikal (kiri, tengah-kiri, tengah-kanan, kanan)
      const Edge(from: 'c_l1', to: 'm0'),
      const Edge(from: 'm0', to: 't0'),

      const Edge(from: 'c1', to: 'm1'),
      const Edge(from: 'm1', to: 't1'),

      const Edge(from: 'c2', to: 'm2'),
      const Edge(from: 'm2', to: 't2'),

      const Edge(from: 'c3', to: 'm3'),
      const Edge(from: 'm3', to: 't3'),

      const Edge(from: 'c_l2', to: 'm4'),
      const Edge(from: 'm4', to: 't4'),
    ];

    // 4. Slots (slot parkir)
    // Dimensi standar: lebar 2.6m, panjang 4.8m
    final slots = [
      // Blok Atas (menghadap ke Lorong Atas y=5.0m, slot di y=1.8m)
      const ParkingSlot(
        id: 'A1',
        lobbyId: 'L1',
        x: 8.0,
        y: 1.8,
        entryNodeId: 't0',
        status: SlotStatus.available,
      ),
      const ParkingSlot(
        id: 'A2',
        lobbyId: 'L1',
        x: 12.0,
        y: 1.8,
        entryNodeId: 't1',
        status: SlotStatus.available,
      ),
      const ParkingSlot(
        id: 'A3',
        lobbyId: 'L1',
        x: 18.0,
        y: 1.8,
        entryNodeId: 't1',
        status: SlotStatus.occupied,
      ),
      const ParkingSlot(
        id: 'A4',
        lobbyId: 'L2',
        x: 23.0,
        y: 1.8,
        entryNodeId: 't2',
        status: SlotStatus.available,
      ),
      const ParkingSlot(
        id: 'A5',
        lobbyId: 'L2',
        x: 29.0,
        y: 1.8,
        entryNodeId: 't2',
        status: SlotStatus.occupied,
      ),
      const ParkingSlot(
        id: 'A6',
        lobbyId: 'L2',
        x: 35.0,
        y: 1.8,
        entryNodeId: 't3',
        status: SlotStatus.available,
      ),
      const ParkingSlot(
        id: 'A7',
        lobbyId: 'L2',
        x: 41.0,
        y: 1.8,
        entryNodeId: 't4',
        status: SlotStatus.occupied,
      ),

      // Blok Tengah Atas (antara lorong atas dan lorong tengah, menghadap lorong tengah y=12m, slot di y=9m)
      const ParkingSlot(
        id: 'B1',
        lobbyId: 'L1',
        x: 9.0,
        y: 8.5,
        entryNodeId: 'm1',
        status: SlotStatus.occupied,
      ),
      const ParkingSlot(
        id: 'B2',
        lobbyId: 'L1',
        x: 19.0,
        y: 8.5,
        entryNodeId: 'm1',
        status: SlotStatus.available,
      ),
      const ParkingSlot(
        id: 'B3',
        lobbyId: 'L2',
        x: 30.0,
        y: 8.5,
        entryNodeId: 'm3',
        status: SlotStatus.available,
      ),
      const ParkingSlot(
        id: 'B4',
        lobbyId: 'L2',
        x: 41.0,
        y: 8.5,
        entryNodeId: 'm4',
        status: SlotStatus.occupied,
      ),

      // Blok Tengah Bawah (antara lorong tengah dan lorong bawah, menghadap lorong tengah y=12m, slot di y=15.5m)
      const ParkingSlot(
        id: 'C1',
        lobbyId: 'L1',
        x: 9.0,
        y: 15.5,
        entryNodeId: 'm1',
        status: SlotStatus.available,
      ),
      const ParkingSlot(
        id: 'C2',
        lobbyId: 'L1',
        x: 19.0,
        y: 15.5,
        entryNodeId: 'm2',
        status: SlotStatus.occupied,
      ),
      const ParkingSlot(
        id: 'C3',
        lobbyId: 'L2',
        x: 30.0,
        y: 15.5,
        entryNodeId: 'm3',
        status: SlotStatus.available,
      ),
      const ParkingSlot(
        id: 'C4',
        lobbyId: 'L2',
        x: 41.0,
        y: 15.5,
        entryNodeId: 'm4',
        status: SlotStatus.available,
      ),
    ];

    return ParkingLayout(
      width: 50.0,
      height: 25.0,
      lobbies: lobbies,
      nodes: nodes,
      edges: edges,
      slots: slots,
    );
  }
}
