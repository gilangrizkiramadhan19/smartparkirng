import 'dart:collection';
import 'parking_models.dart';

/// Enum tipe node denah dengan fallback ke [unknown].
enum NodeType {
  entrance,
  junction,
  room,
  slot,
  stairs,
  elevator,
  toilet,
  unknown;

  static NodeType fromString(String? value) {
    if (value == null) return NodeType.unknown;
    switch (value.trim().toLowerCase()) {
      case 'entrance':
        return NodeType.entrance;
      case 'junction':
        return NodeType.junction;
      case 'room':
        return NodeType.room;
      case 'slot':
        return NodeType.slot;
      case 'stairs':
        return NodeType.stairs;
      case 'elevator':
        return NodeType.elevator;
      case 'toilet':
        return NodeType.toilet;
      default:
        return NodeType.unknown;
    }
  }

  String toDisplayString() {
    switch (this) {
      case NodeType.entrance:
        return 'Pintu / Akses Masuk';
      case NodeType.junction:
        return 'Persimpangan';
      case NodeType.room:
        return 'Ruangan';
      case NodeType.slot:
        return 'Slot Parkir';
      case NodeType.stairs:
        return 'Tangga';
      case NodeType.elevator:
        return 'Lift';
      case NodeType.toilet:
        return 'Toilet';
      case NodeType.unknown: 
        return 'Lainnya';
    }
  }
}

/// Node titik denah dari Indoor AR Map Editor.
class MapNode extends Node {
  final String name;
  final NodeType type;

  const MapNode({
    required super.id,
    required this.name,
    required this.type,
    required super.x,
    required super.y,
  });

  factory MapNode.fromJson(Map<String, dynamic> json) {
    final rawId = json['id'];
    if (rawId == null || rawId.toString().trim().isEmpty) {
      throw const FormatException('Node wajib memiliki "id".');
    }
    final id = rawId.toString().trim();

    final rawName = json['name'];
    final name = (rawName != null && rawName.toString().trim().isNotEmpty)
        ? rawName.toString().trim()
        : id;

    final type = NodeType.fromString(json['type']?.toString());

    final rawX = json['x'];
    final rawY = json['y'];
    if (rawX == null || rawY == null || rawX is! num || rawY is! num) {
      throw FormatException('Koordinat node "$id" harus bernilai numerik (x: $rawX, y: $rawY).');
    }

    final x = rawX.toDouble();
    final y = rawY.toDouble();
    if (x.isNaN || x.isInfinite || y.isNaN || y.isInfinite) {
      throw FormatException('Koordinat node "$id" tidak valid (NaN atau Infinite).');
    }

    return MapNode(
      id: id,
      name: name,
      type: type,
      x: x,
      y: y,
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type.name,
        'x': x,
        'y': y,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MapNode && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'MapNode(id: $id, name: "$name", type: ${type.name}, x: $x, y: $y)';
}

/// Edge / koneksi antar node pada denah.
class MapEdge extends Edge {
  final String id;

  const MapEdge({
    required this.id,
    required super.from,
    required super.to,
    double? distance,
    super.bidirectional = true,
  }) : super(weight: distance);

  double? get distance => weight; 

  factory MapEdge.fromJson(Map<String, dynamic> json) {
    final rawId = json['id'];
    final rawFrom = json['from'];
    final rawTo = json['to'];
    if (rawFrom == null || rawTo == null) {
      throw const FormatException('Edge wajib memiliki field "from" dan "to".');
    }

    final fromStr = rawFrom.toString().trim();
    final toStr = rawTo.toString().trim();
    if (fromStr.isEmpty || toStr.isEmpty) {
      throw const FormatException('Field "from" dan "to" pada edge tidak boleh kosong.');
    }

    final rawDistance = json['distance'];
    double? distance;
    if (rawDistance != null) {
      if (rawDistance is! num) {
        throw FormatException('Field "distance" pada edge "${rawId ?? ''}" harus berupa angka.');
      }
      distance = rawDistance.toDouble();
      if (distance.isNaN || distance.isInfinite || distance < 0) {
        throw FormatException('Field "distance" pada edge "${rawId ?? ''}" tidak valid.');
      }
    }

    final id = rawId?.toString().trim().isNotEmpty == true
        ? rawId.toString().trim()
        : '${fromStr}_$toStr';

    return MapEdge(
      id: id,
      from: fromStr,
      to: toStr,
      distance: distance,
      bidirectional: json['bidirectional'] as bool? ?? true,
    );
  }

  @override
  Map<String, dynamic> toJson() => {
        'id': id,
        'from': from,
        'to': to,
        if (distance != null) 'distance': distance,
        'bidirectional': bidirectional,
      };

  @override
  String toString() => 'MapEdge(id: $id, $from -> $to, dist: $distance)';
}

/// Metadata sistem koordinat denah.
class CoordinateSystem {
  final String unit;
  final String origin;
  final String yAxis;

  const CoordinateSystem({
    this.unit = 'meter',
    this.origin = 'top-left',
    this.yAxis = 'down',
  });

  factory CoordinateSystem.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const CoordinateSystem();
    return CoordinateSystem(
      unit: json['unit']?.toString() ?? 'meter',
      origin: json['origin']?.toString() ?? 'top-left',
      yAxis: json['yAxis']?.toString() ?? 'down',
    );
  }

  Map<String, dynamic> toJson() => {
        'unit': unit,
        'origin': origin,
        'yAxis': yAxis,
      };
}

/// Model tembok arsitektur denah dari Indoor AR Map Editor.
class MapWall {
  final String id;
  final double x1;
  final double y1;
  final double x2;
  final double y2;

  const MapWall({
    required this.id,
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
  });

  factory MapWall.fromJson(Map<String, dynamic> json) {
    return MapWall(
      id: json['id']?.toString().trim() ?? '',
      x1: (json['x1'] as num?)?.toDouble() ?? 0.0,
      y1: (json['y1'] as num?)?.toDouble() ?? 0.0,
      x2: (json['x2'] as num?)?.toDouble() ?? 0.0,
      y2: (json['y2'] as num?)?.toDouble() ?? 0.0,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'x1': x1,
        'y1': y1,
        'x2': x2,
        'y2': y2,
      };

  @override
  String toString() => 'MapWall(id: $id, ($x1, $y1) -> ($x2, $y2))';
}

/// Data denah untuk satu lantai.
class FloorData {
  final String id;
  final String name;
  final double width;
  final double length;
  final double northOffset;
  final List<MapNode> nodes;
  final List<MapEdge> edges;
  final List<MapWall> walls;

  const FloorData({
    required this.id,
    required this.name,
    required this.width,
    required this.length,
    this.northOffset = 0.0,
    required this.nodes,
    required this.edges,
    this.walls = const [],
  });

  factory FloorData.fromJson(Map<String, dynamic> json) {
    final rawId = json['id']?.toString().trim() ?? 'L1';
    final name = json['name']?.toString().trim() ?? rawId;
    final width = (json['width'] as num?)?.toDouble() ?? 40.0;
    final length = (json['length'] as num?)?.toDouble() ?? 25.0;
    final northOffset = (json['northOffset'] as num?)?.toDouble() ?? 0.0;

    final rawNodes = json['nodes'] as List<dynamic>? ?? [];
    final nodes = rawNodes
        .map((n) => MapNode.fromJson(n as Map<String, dynamic>))
        .toList();

    final rawEdges = json['edges'] as List<dynamic>? ?? [];
    final edges = rawEdges
        .map((e) => MapEdge.fromJson(e as Map<String, dynamic>))
        .toList();

    final rawWalls = json['walls'] as List<dynamic>? ?? [];
    final walls = rawWalls
        .map((w) => MapWall.fromJson(w as Map<String, dynamic>))
        .toList();

    return FloorData(
      id: rawId,
      name: name,
      width: width,
      length: length,
      northOffset: northOffset,
      nodes: nodes,
      edges: edges,
      walls: walls,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'width': width,
        'length': length,
        'northOffset': northOffset,
        'nodes': nodes.map((n) => n.toJson()).toList(),
        'edges': edges.map((e) => e.toJson()).toList(),
        'walls': walls.map((w) => w.toJson()).toList(),
      };

  /// Mencari node berdasarkan ID (case-insensitive).
  MapNode? findNodeById(String id) {
    final query = id.trim().toLowerCase();
    for (final node in nodes) {
      if (node.id.toLowerCase() == query) return node;
    }
    return null;
  }
}

/// Root data peta hasil ekspor Indoor AR Map Editor.
class MapData {
  final int version;
  final CoordinateSystem coordinateSystem;
  final List<FloorData> floors;

  const MapData({
    required this.version,
    required this.coordinateSystem,
    required this.floors,
  });

  factory MapData.fromJson(Map<String, dynamic> json) {
    final version = (json['version'] as num?)?.toInt() ?? 1;
    final coordinateSystem = CoordinateSystem.fromJson(
      json['coordinateSystem'] as Map<String, dynamic>?,
    );
    final rawFloors = json['floors'] as List<dynamic>? ?? [];
    final floors = rawFloors
        .map((f) => FloorData.fromJson(f as Map<String, dynamic>))
        .toList();

    return MapData(
      version: version,
      coordinateSystem: coordinateSystem,
      floors: floors,
    );
  }

  Map<String, dynamic> toJson() => {
        'version': version,
        'coordinateSystem': coordinateSystem.toJson(),
        'floors': floors.map((f) => f.toJson()).toList(),
      };

  /// Mencari node di seluruh lantai berdasarkan ID.
  MapNode? findNodeById(String id) {
    for (final floor in floors) {
      final node = floor.findNodeById(id);
      if (node != null) return node;
    }
    return null;
  }

  /// Memvalidasi integritas data peta sesuai TUGAS 3:

  /// - ID node unik
  /// - Edge menunjuk node yang ada
  /// - Koordinat numerik
  /// - Graf tersambung per lantai
  void validate() {
    if (floors.isEmpty) {
      throw const MapValidationException('Data peta tidak memiliki lantai.');
    }

    final Set<String> globalNodeIds = {};

    for (final floor in floors) {
      final Set<String> floorNodeIds = {};
      final Map<String, MapNode> nodeMap = {};

      for (final node in floor.nodes) {
        // Cek ID unik dalam lantai
        if (floorNodeIds.contains(node.id)) {
          throw MapValidationException(
            'Duplikasi ID node terdeteksi: "${node.id}" di lantai "${floor.name}".',
          );
        }
        // Cek ID unik secara global
        if (globalNodeIds.contains(node.id)) {
          throw MapValidationException(
            'Duplikasi ID node terdeteksi di beberapa lantai: "${node.id}".',
          );
        }

        // Koordinat numerik valid
        if (node.x.isNaN || node.x.isInfinite || node.y.isNaN || node.y.isInfinite) {
          throw MapValidationException(
            'Koordinat node "${node.id}" tidak valid (NaN atau Infinite).',
          );
        }

        floorNodeIds.add(node.id);
        globalNodeIds.add(node.id);
        nodeMap[node.id] = node;
      }

      // Cek setiap edge menunjuk node yang ada di lantai ini
      for (final edge in floor.edges) {
        if (!nodeMap.containsKey(edge.from)) {
          throw MapValidationException(
            'Edge "${edge.id}" di lantai "${floor.name}" menunjuk ke node asal yang tidak ada: "${edge.from}".',
          );
        }
        if (!nodeMap.containsKey(edge.to)) {
          throw MapValidationException(
            'Edge "${edge.id}" di lantai "${floor.name}" menunjuk ke node tujuan yang tidak ada: "${edge.to}".',
          );
        }
      }

      // Cek graf tersambung per lantai (menggunakan BFS)
      if (floor.nodes.length > 1) {
        final Map<String, List<String>> adj = {
          for (final n in floor.nodes) n.id: <String>[],
        };

        for (final edge in floor.edges) {
          adj[edge.from]?.add(edge.to);
          adj[edge.to]?.add(edge.from);
        }

        final Set<String> visited = {};
        final Queue<String> queue = Queue<String>()..add(floor.nodes.first.id);
        visited.add(floor.nodes.first.id);

        while (queue.isNotEmpty) {
          final curr = queue.removeFirst();
          final neighbors = adj[curr] ?? const [];
          for (final neighbor in neighbors) {
            if (!visited.contains(neighbor)) {
              visited.add(neighbor);
              queue.add(neighbor);
            }
          }
        }

        if (visited.length < floor.nodes.length) {
          final unvisited = floor.nodes
              .where((n) => !visited.contains(n.id))
              .map((n) => n.id)
              .toList();
          throw MapValidationException(
            'Graf pada lantai "${floor.name}" tidak tersambung penuh. Terdapat node yang terisolasi: ${unvisited.join(", ")}.',
          );
        }
      }
    }
  }
}

/// Exception spesifik untuk kegagalan validasi peta.
class MapValidationException implements Exception {
  final String message;
  const MapValidationException(this.message);

  @override
  String toString() => 'MapValidationException: $message';
}

/// Helper extension untuk mengonversi FloorData ke ParkingLayout untuk kompatibilitas.
extension FloorDataParkingLayout on FloorData {
  ParkingLayout toParkingLayout() {
    final slots = <ParkingSlot>[];
    for (final node in nodes) {
      if (node.type == NodeType.slot) {
        slots.add(ParkingSlot(
          id: node.id,
          lobbyId: id,
          x: node.x,
          y: node.y,
          entryNodeId: node.id,
        ));
      }
    }

    final lobbies = <Lobby>[];
    for (final node in nodes) {
      if (node.type == NodeType.entrance) {
        lobbies.add(Lobby(
          id: node.id,
          name: node.name,
          entryNodeId: node.id,
          x: node.x,
          y: node.y,
        ));
      }
    }

    return ParkingLayout(
      width: width,
      height: length,
      lobbies: lobbies,
      nodes: nodes,
      edges: edges,
      slots: slots,
    );
  }
}

