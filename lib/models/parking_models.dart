import 'dart:convert';

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
