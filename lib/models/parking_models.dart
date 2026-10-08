import 'dart:convert';
import 'dart:math' as math;

/// Status ketersediaan slot parkir.
enum SlotStatus {
  available,
  occupied,
  reserved;

  static SlotStatus fromString(String value) {
    switch (value.toLowerCase()) {
      case 'available':
        return SlotStatus.available;
      case 'occupied':
        return SlotStatus.occupied;
      case 'reserved':
        return SlotStatus.reserved;
      default:
        return SlotStatus.occupied;
    }
  }

  String toApiString() {
    switch (this) {
      case SlotStatus.available:
        return 'available';
      case SlotStatus.occupied:
        return 'occupied';
      case SlotStatus.reserved:
        return 'reserved';
    }
  }
}

/// Titik koordinat pada denah (dalam satuan meter).
class Node {
  final String id;
  final double x; // meter
  final double y; // meter

  const Node({
    required this.id,
    required this.x,
    required this.y,
  });

  factory Node.fromJson(Map<String, dynamic> json) {
    return Node(
      id: json['id'] as String,
      x: (json['x'] as num).toDouble(),
      y: (json['y'] as num).toDouble(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'x': x,
        'y': y,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Node && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;
}

/// Jalur lintasan antara dua Node.
class Edge {
  final String from;
  final String to;
  final double? weight; // Jarak dalam meter (opsional, jika null dihitung Euclidean)
  final bool bidirectional;

  const Edge({
    required this.from,
    required this.to,
    this.weight,
    this.bidirectional = true,
  });

  factory Edge.fromJson(Map<String, dynamic> json) {
    return Edge(
      from: json['from'] as String,
      to: json['to'] as String,
      weight: (json['weight'] as num?)?.toDouble(),
      bidirectional: json['bidirectional'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toJson() => {
        'from': from,
        'to': to,
        if (weight != null) 'weight': weight,
        'bidirectional': bidirectional,
      };
}

/// Slot parkir kendaraan.
class ParkingSlot {
  final String id;
  final String lobbyId;
  final double x; // Posisi tengah slot dalam meter
  final double y;
  final double width; // Lebar slot dalam meter (default ~2.4m)
  final double height; // Panjang slot dalam meter (default ~4.8m)
  final String entryNodeId; // Node di jalanan tempat mobil masuk ke slot
  final SlotStatus status;

  const ParkingSlot({
    required this.id,
    required this.lobbyId,
    required this.x,
    required this.y,
    this.width = 2.4,
    this.height = 4.8,
    required this.entryNodeId,
    this.status = SlotStatus.available,
  });

  bool get isAvailable => status == SlotStatus.available;
  bool get isOccupied => status == SlotStatus.occupied;

  ParkingSlot copyWith({
    String? id,
    String? lobbyId,
    double? x,
    double? y,
    double? width,
    double? height,
    String? entryNodeId,
    SlotStatus? status,
  }) {
    return ParkingSlot(
      id: id ?? this.id,
      lobbyId: lobbyId ?? this.lobbyId,
      x: x ?? this.x,
      y: y ?? this.y,
      width: width ?? this.width,
      height: height ?? this.height,
      entryNodeId: entryNodeId ?? this.entryNodeId,
      status: status ?? this.status,
    );
  }

  factory ParkingSlot.fromJson(Map<String, dynamic> json) {
    return ParkingSlot(
      id: json['id'] as String,
      lobbyId: json['lobbyId'] as String? ?? 'L1',
      x: (json['x'] as num).toDouble(),
      y: (json['y'] as num).toDouble(),
      width: (json['width'] as num?)?.toDouble() ?? 2.4,
      height: (json['height'] as num?)?.toDouble() ?? 4.8,
      entryNodeId: json['entryNodeId'] as String,
      status: SlotStatus.fromString(json['status'] as String? ?? 'available'),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'lobbyId': lobbyId,
        'x': x,
        'y': y,
        'width': width,
        'height': height,
        'entryNodeId': entryNodeId,
        'status': status.toApiString(),
      };
}

/// Lobby atau gerbang masuk kendaraan/pejalan kaki.
class Lobby {
  final String id;
  final String name;
  final String entryNodeId;
  final double x;
  final double y;

  const Lobby({
    required this.id,
    required this.name,
    required this.entryNodeId,
    required this.x,
    required this.y,
  });

  factory Lobby.fromJson(Map<String, dynamic> json) {
    return Lobby(
      id: json['id'] as String,
      name: json['name'] as String,
      entryNodeId: json['entryNodeId'] as String,
      x: (json['x'] as num).toDouble(),
      y: (json['y'] as num).toDouble(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'entryNodeId': entryNodeId,
        'x': x,
        'y': y,
      };
}

/// Keseluruhan layout denah parkir.
class ParkingLayout {
  final double width; // Lebar total denah dalam meter
  final double height; // Tinggi total denah dalam meter
  final List<Lobby> lobbies;
  final List<Node> nodes;
  final List<Edge> edges;
  final List<ParkingSlot> slots;

  const ParkingLayout({
    required this.width,
    required this.height,
    required this.lobbies,
    required this.nodes,
    required this.edges,
    required this.slots,
  });

  factory ParkingLayout.fromJson(Map<String, dynamic> json) {
    return ParkingLayout(
      width: (json['width'] as num).toDouble(),
      height: (json['height'] as num).toDouble(),
      lobbies: (json['lobbies'] as List<dynamic>?)
              ?.map((e) => Lobby.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      nodes: (json['nodes'] as List<dynamic>?)
              ?.map((e) => Node.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      edges: (json['edges'] as List<dynamic>?)
              ?.map((e) => Edge.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      slots: (json['slots'] as List<dynamic>?)
              ?.map((e) => ParkingSlot.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  Map<String, dynamic> toJson() => {
        'width': width,
        'height': height,
        'lobbies': lobbies.map((e) => e.toJson()).toList(),
        'nodes': nodes.map((e) => e.toJson()).toList(),
        'edges': edges.map((e) => e.toJson()).toList(),
        'slots': slots.map((e) => e.toJson()).toList(),
      };

  /// Memproses layout denah agar tiap slot memiliki node akses (`acc_<slotId>`) di lorong.
  ParkingLayout withSlotAccessNodes() => smartparkingWithSlotAccessNodes(this);

  static ParkingLayout processWithSlotAccessNodes(ParkingLayout layout) =>
      smartparkingWithSlotAccessNodes(layout);
}

/// Menambahkan node akses masuk ("pintu", id: `acc_<slotId>`) untuk tiap slot parkir
/// pada lorong jalan yang dihadapi slot, dengan x sama dengan slot, lalu membelah
/// edge lorong di titik tersebut.
///
/// Fungsi ini dapat dipanggil untuk denah mock maupun data denah dari backend asli.
ParkingLayout withSlotAccessNodes(ParkingLayout layout) =>
    smartparkingWithSlotAccessNodes(layout);

ParkingLayout smartparkingWithSlotAccessNodes(ParkingLayout layout) {
  // Cek idempotensi: jika semua slot sudah memiliki entryNodeId acc_ dan node-nya ada
  final nodeMap = {for (var n in layout.nodes) n.id: n};
  final allAlreadyProcessed = layout.slots.isNotEmpty &&
      layout.slots.every((s) => s.entryNodeId == 'acc_${s.id}' && nodeMap.containsKey('acc_${s.id}'));
  if (allAlreadyProcessed) {
    return layout;
  }

  final List<Node> createdAccessNodes = [];
  final List<ParkingSlot> updatedSlots = [];

  // Edge key helper (urutan konsisten untuk edge dua arah)
  String edgeKey(String from, String to) {
    return from.compareTo(to) < 0 ? '$from--$to' : '$to--$from';
  }

  // Peta edge yang akan dibelah: edgeKey -> daftar access node di edge tersebut
  final Map<String, List<Node>> edgeToAccessNodes = {};

  for (var slot in layout.slots) {
    // 1. Tentukan koordinat Y lorong yang dihadapi slot
    double? aisleY;
    if (nodeMap.containsKey(slot.entryNodeId)) {
      aisleY = nodeMap[slot.entryNodeId]!.y;
    }

    // 2. Cari edge horizontal di lorong tersebut yang mencakup rentang x slot
    Edge? targetEdge;
    if (aisleY != null) {
      for (var edge in layout.edges) {
        final u = nodeMap[edge.from];
        final v = nodeMap[edge.to];
        if (u != null && v != null) {
          // Horizontal edge pada y lorong
          if ((u.y - aisleY).abs() < 0.01 && (v.y - aisleY).abs() < 0.01) {
            final minX = math.min(u.x, v.x);
            final maxX = math.max(u.x, v.x);
            if (slot.x >= minX - 0.01 && slot.x <= maxX + 0.01) {
              targetEdge = edge;
              break;
            }
          }
        }
      }
    }

    // Fallback jika tidak ditemukan lewat entryNodeId: cari edge horizontal terdekat
    if (targetEdge == null) {
      double minPerpDist = double.infinity;
      for (var edge in layout.edges) {
        final u = nodeMap[edge.from];
        final v = nodeMap[edge.to];
        if (u != null && v != null && (u.y - v.y).abs() < 0.01) {
          final minX = math.min(u.x, v.x);
          final maxX = math.max(u.x, v.x);
          if (slot.x >= minX - 0.01 && slot.x <= maxX + 0.01) {
            final dist = (u.y - slot.y).abs();
            if (dist < minPerpDist) {
              minPerpDist = dist;
              targetEdge = edge;
              aisleY = u.y;
            }
          }
        }
      }
    }

    final effectiveY = aisleY ?? (targetEdge != null ? nodeMap[targetEdge.from]!.y : slot.y);
    final accNode = Node(
      id: 'acc_${slot.id}',
      x: slot.x,
      y: effectiveY,
    );

    createdAccessNodes.add(accNode);
    updatedSlots.add(slot.copyWith(entryNodeId: accNode.id));

    if (targetEdge != null) {
      final key = edgeKey(targetEdge.from, targetEdge.to);
      edgeToAccessNodes.putIfAbsent(key, () => []).add(accNode);
    }
  }

  // 3. Bangun edge baru dengan membelah edge yang memiliki access node
  final List<Edge> newEdges = [];

  for (var edge in layout.edges) {
    final key = edgeKey(edge.from, edge.to);
    final accessNodesOnEdge = edgeToAccessNodes[key];

    if (accessNodesOnEdge == null || accessNodesOnEdge.isEmpty) {
      newEdges.add(edge);
      continue;
    }

    final u = nodeMap[edge.from]!;
    final v = nodeMap[edge.to]!;

    // Hitung posisi relatif parameter t (0.0 di u, 1.0 di v)
    final dx = v.x - u.x;
    final dy = v.y - u.y;
    final lenSq = dx * dx + dy * dy;

    double getT(Node node) {
      if (lenSq == 0) return 0.0;
      return ((node.x - u.x) * dx + (node.y - u.y) * dy) / lenSq;
    }

    // Kelompokkan node berdasarkan posisi t yang sama
    final Map<int, List<Node>> tGroups = {};
    for (var accNode in accessNodesOnEdge) {
      final t = getT(accNode);
      final keyT = (t * 10000).round();
      tGroups.putIfAbsent(keyT, () => []).add(accNode);
    }

    final sortedTKeys = tGroups.keys.toList()..sort();

    // Bentuk urutan kelompok titik dari u (t=0) ke v (t=1)
    final List<List<Node>> sequenceOfGroups = [];
    sequenceOfGroups.add([u]);
    for (var k in sortedTKeys) {
      sequenceOfGroups.add(tGroups[k]!);
    }
    sequenceOfGroups.add([v]);

    // Hubungkan setiap kelompok ke kelompok berikutnya
    for (int i = 0; i < sequenceOfGroups.length - 1; i++) {
      final groupA = sequenceOfGroups[i];
      final groupB = sequenceOfGroups[i + 1];

      for (var nodeA in groupA) {
        for (var nodeB in groupB) {
          final dist = math.sqrt(
            math.pow(nodeA.x - nodeB.x, 2) + math.pow(nodeA.y - nodeB.y, 2),
          );
          newEdges.add(Edge(
            from: nodeA.id,
            to: nodeB.id,
            weight: dist,
            bidirectional: edge.bidirectional,
          ));
        }
      }
    }

    // Jika di satu titik t terdapat beberapa access node (misal B1 dan C1 di x=9)
    for (var k in sortedTKeys) {
      final nodesAtT = tGroups[k]!;
      if (nodesAtT.length > 1) {
        for (int i = 0; i < nodesAtT.length; i++) {
          for (int j = i + 1; j < nodesAtT.length; j++) {
            newEdges.add(Edge(
              from: nodesAtT[i].id,
              to: nodesAtT[j].id,
              weight: 0.0,
              bidirectional: true,
            ));
          }
        }
      }
    }
  }

  // Gabungkan nodes unik (node awal + access node yang dibuat)
  final Map<String, Node> mergedNodes = {for (var n in layout.nodes) n.id: n};
  for (var accNode in createdAccessNodes) {
    mergedNodes[accNode.id] = accNode;
  }

  return ParkingLayout(
    width: layout.width,
    height: layout.height,
    lobbies: layout.lobbies,
    nodes: mergedNodes.values.toList(),
    edges: newEdges,
    slots: updatedSlots,
  );
}

/// Pesan event update slot realtime (dari WebSocket/SSE).
class SlotUpdate {
  final String slotId;
  final SlotStatus status;
  final DateTime timestamp;

  SlotUpdate({
    required this.slotId,
    required this.status,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  factory SlotUpdate.fromJson(Map<String, dynamic> json) {
    return SlotUpdate(
      slotId: json['slotId'] as String,
      status: SlotStatus.fromString(json['status'] as String),
      timestamp: json['timestamp'] != null
          ? DateTime.tryParse(json['timestamp'] as String) ?? DateTime.now()
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
        'slotId': slotId,
        'status': status.toApiString(),
        'timestamp': timestamp.toIso8601String(),
      };

  @override
  String toString() => jsonEncode(toJson());
}
