import 'dart:math' as math;
import 'dart:ui';
import '../models/parking_models.dart';

/// Hasil proyeksi snap suatu koordinat ke segmen edge denah graf.
class SnapResult {
  /// Titik hasil proyeksi tegak lurus pada segmen edge (dalam satuan meter).
  final Offset snappedPosition;

  /// Edge graf tempat titik diproyeksikan.
  final Edge edge;

  /// Nilai parameter interpolasi t (rentang 0.0 sampai 1.0) dari node `from` ke node `to`.
  final double t;

  /// Jarak tegak lurus dari titik asal ke titik hasil proyeksi (dalam satuan meter).
  final double distance;

  /// Menandakan apakah titik berada di luar batas toleransi graf (jarak snap terlalu jauh).
  final bool isOffGraph;

  const SnapResult({
    required this.snappedPosition,
    required this.edge,
    required this.t,
    required this.distance,
    this.isOffGraph = false,
  });

  @override
  String toString() =>
      'SnapResult(pos: (${snappedPosition.dx.toStringAsFixed(2)}, ${snappedPosition.dy.toStringAsFixed(2)}), edge: ${edge.from}->${edge.to}, t: ${t.toStringAsFixed(3)}, dist: ${distance.toStringAsFixed(2)}m, offGraph: $isOffGraph)';
}

/// Fungsi murni untuk memproyeksikan titik koordinat [point] ke segmen [Edge] terdekat
/// pada graf jalan denah.
///
/// Mengembalikan [SnapResult] yang berisi:
/// - `snappedPosition`: titik hasil proyeksi
/// - `edge`: segmen edge terdekat
/// - `t`: parameter posisi sepanjang segmen (0.0 pada ujung `from`, 1.0 pada ujung `to`)
/// - `distance`: jarak tegak lurus proyeksi
/// - `isOffGraph`: `true` jika jarak proyeksi melebihi [maxSnapDistance] (default 5.0m).
SnapResult? snapToGraph(
  Offset point,
  List<Node> nodes,
  List<Edge> edges, {
  double maxSnapDistance = 5.0,
}) {
  if (nodes.isEmpty || edges.isEmpty) {
    return null;
  }

  final nodeMap = {for (var n in nodes) n.id: n};

  Edge? bestEdge;
  Offset? bestSnapped;
  double bestT = 0.0;
  double minDistance = double.infinity;

  for (var edge in edges) {
    final u = nodeMap[edge.from];
    final v = nodeMap[edge.to];
    if (u == null || v == null) continue;

    final dx = v.x - u.x;
    final dy = v.y - u.y;
    final lenSq = dx * dx + dy * dy;

    double t;
    Offset proj;

    if (lenSq == 0.0) {
      // Edge panjang nol (kedua ujung berada di titik yang sama)
      t = 0.0;
      proj = Offset(u.x, u.y);
    } else {
      // Proyeksi titik P ke vektor UV:
      // t = ((P - U) . (V - U)) / |V - U|^2
      final rawT = ((point.dx - u.x) * dx + (point.dy - u.y) * dy) / lenSq;
      t = rawT.clamp(0.0, 1.0);
      proj = Offset(u.x + t * dx, u.y + t * dy);
    }

    final dist = math.sqrt(
      math.pow(point.dx - proj.dx, 2) + math.pow(point.dy - proj.dy, 2),
    );

    if (dist < minDistance) {
      minDistance = dist;
      bestEdge = edge;
      bestSnapped = proj;
      bestT = t;
    }
  }

  if (bestEdge == null || bestSnapped == null) {
    return null;
  }

  final isOffGraph = minDistance > maxSnapDistance;

  return SnapResult(
    snappedPosition: bestSnapped,
    edge: bestEdge,
    t: bestT,
    distance: minDistance,
    isOffGraph: isOffGraph,
  );
}
