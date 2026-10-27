import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:smartparking/models/map_data.dart';
import 'package:smartparking/services/a_star.dart';
import 'package:smartparking/services/map_repository.dart';

void main() {
  group('MapData Parser & Validator Tests', () {
    late String realMapJsonString;
    late MapRepository repository;

    setUpAll(() {
      final file = File('assets/maps/map.json');
      expect(file.existsSync(), isTrue, reason: 'assets/maps/map.json harus ada');
      realMapJsonString = file.readAsStringSync();
    });

    setUp(() {
      repository = MapRepository();
    });

    test('Mem-parse dan memvalidasi JSON asli peta tanpa error', () {
      final mapData = repository.parseAndValidate(realMapJsonString);
      expect(mapData.version, equals(1));
      expect(mapData.coordinateSystem.unit, equals('meter'));
      expect(mapData.coordinateSystem.origin, equals('top-left'));
      expect(mapData.coordinateSystem.yAxis, equals('down'));
      expect(mapData.floors.length, equals(1));

      final floor = mapData.floors.first;
      expect(floor.id, equals('L1'));
      expect(floor.name, equals('Lantai 1'));
      expect(floor.nodes.length, equals(17));
      expect(floor.edges.length, equals(16));

      // Cek beberapa node kunci
      final n1 = floor.findNodeById('n1');
      expect(n1, isNotNull);
      expect(n1!.name, equals('pintu masuk teras'));
      expect(n1.type, equals(NodeType.entrance));
      expect(n1.x, equals(23.0));
      expect(n1.y, equals(24.5));

      final n9 = floor.findNodeById('n9');
      expect(n9, isNotNull);
      expect(n9!.type, isIn([NodeType.room, NodeType.toilet]));
    });

    test('Enum NodeType fallback ke unknown untuk tipe tidak dikenal', () {
      expect(NodeType.fromString('entrance'), equals(NodeType.entrance));
      expect(NodeType.fromString('junction'), equals(NodeType.junction));
      expect(NodeType.fromString('room'), equals(NodeType.room));
      expect(NodeType.fromString('slot'), equals(NodeType.slot));
      expect(NodeType.fromString('stairs'), equals(NodeType.stairs));
      expect(NodeType.fromString('elevator'), equals(NodeType.elevator));
      expect(NodeType.fromString('toilet'), equals(NodeType.toilet));
      expect(NodeType.fromString('unknown_type_xyz'), equals(NodeType.unknown));
      expect(NodeType.fromString(null), equals(NodeType.unknown));
    });

    test('Validasi gagal jika ID node duplikat', () {
      const jsonWithDuplicate = '''
      {
        "version": 1,
        "floors": [
          {
            "id": "L1",
            "name": "Lantai 1",
            "nodes": [
              {"id": "n1", "name": "Node 1", "type": "entrance", "x": 0.0, "y": 0.0},
              {"id": "n1", "name": "Node Duplikat", "type": "room", "x": 1.0, "y": 1.0}
            ],
            "edges": []
          }
        ]
      }
      ''';

      expect(
        () => repository.parseAndValidate(jsonWithDuplicate),
        throwsA(isA<MapValidationException>().having(
          (e) => e.message,
          'message',
          contains('Duplikasi ID node terdeteksi'),
        )),
      );
    });

    test('Validasi gagal jika edge menunjuk ke node yang tidak ada', () {
      const jsonWithInvalidEdge = '''
      {
        "version": 1,
        "floors": [
          {
            "id": "L1",
            "name": "Lantai 1",
            "nodes": [
              {"id": "n1", "name": "Node 1", "type": "entrance", "x": 0.0, "y": 0.0},
              {"id": "n2", "name": "Node 2", "type": "room", "x": 1.0, "y": 1.0}
            ],
            "edges": [
              {"id": "e1", "from": "n1", "to": "node_hantu", "distance": 1.0}
            ]
          }
        ]
      }
      ''';

      expect(
        () => repository.parseAndValidate(jsonWithInvalidEdge),
        throwsA(isA<MapValidationException>().having(
          (e) => e.message,
          'message',
          contains('menunjuk ke node tujuan yang tidak ada'),
        )),
      );
    });

    test('Validasi gagal jika koordinat node bukan angka', () {
      const jsonWithInvalidCoords = '''
      {
        "version": 1,
        "floors": [
          {
            "id": "L1",
            "name": "Lantai 1",
            "nodes": [
              {"id": "n1", "name": "Node 1", "type": "entrance", "x": "dua puluh tiga", "y": 24.5}
            ],
            "edges": []
          }
        ]
      }
      ''';

      expect(
        () => repository.parseAndValidate(jsonWithInvalidCoords),
        throwsA(isA<MapValidationException>().having(
          (e) => e.message,
          'message',
          contains('harus bernilai numerik'),
        )),
      );
    });

    test('Validasi gagal jika graf tidak tersambung penuh pada satu lantai', () {
      const jsonDisconnected = '''
      {
        "version": 1,
        "floors": [
          {
            "id": "L1",
            "name": "Lantai 1",
            "nodes": [
              {"id": "n1", "name": "Node 1", "type": "entrance", "x": 0.0, "y": 0.0},
              {"id": "n2", "name": "Node 2", "type": "room", "x": 1.0, "y": 1.0},
              {"id": "n_terpencil", "name": "Node Terpencil", "type": "room", "x": 10.0, "y": 10.0}
            ],
            "edges": [
              {"id": "e1", "from": "n1", "to": "n2", "distance": 1.414}
            ]
          }
        ]
      }
      ''';

      expect(
        () => repository.parseAndValidate(jsonDisconnected),
        throwsA(isA<MapValidationException>().having(
          (e) => e.message,
          'message',
          contains('tidak tersambung penuh'),
        )),
      );
    });
  });

  group('A* Route Finding pada Graf JSON Asli', () {
    late MapData mapData;
    late FloorData floor;

    setUpAll(() {
      final file = File('assets/maps/map.json');
      final repo = MapRepository();
      mapData = repo.parseAndValidate(file.readAsStringSync());
      floor = mapData.floors.first;
    });

    test('A* menemukan rute dari pintu masuk teras (n1) ke ruang meeting (n17)', () {
      final path = AStar.findPath(
        nodes: floor.nodes,
        edges: floor.edges,
        startNodeId: 'n1',
        targetNodeId: 'n17',
      );

      expect(path, isNotNull);
      expect(path!.first.id, equals('n1'));
      expect(path.last.id, equals('n17'));

      // Jalur yang diharapkan: n1 -> n2 -> n4 -> n5 -> n10 -> n16 -> n15 -> n17
      final nodeIds = path.map((n) => n.id).toList();
      expect(nodeIds, equals(['n1', 'n2', 'n4', 'n5', 'n10', 'n16', 'n15', 'n17']));

      // Hitung total jarak rute menggunakan bobot edge
      final length = AStar.calculatePathLength(path);
      expect(length, closeTo(3.5, 0.5));
    });

    test('A* menemukan rute dari pintu masuk teras (n1) ke n9 (toilet/kamar mandi)', () {
      final path = AStar.findPath(
        nodes: floor.nodes,
        edges: floor.edges,
        startNodeId: 'n1',
        targetNodeId: 'n9',
      );

      expect(path, isNotNull);
      expect(path!.first.id, equals('n1'));
      expect(path.last.id, equals('n9'));

      final nodeIds = path.map((n) => n.id).toList();
      expect(nodeIds, equals(['n1', 'n2', 'n4', 'n5', 'n6', 'n7', 'n8', 'n9']));
    });

    test('A* start == target mengembalikan single node path', () {
      final path = AStar.findPath(
        nodes: floor.nodes,
        edges: floor.edges,
        startNodeId: 'n5',
        targetNodeId: 'n5',
      );

      expect(path, isNotNull);
      expect(path!.length, equals(1));
      expect(path.first.id, equals('n5'));
    });
  });
}
