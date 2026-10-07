import 'dart:math' as math;
import '../models/parking_models.dart';

class _Neighbor {
  final Node node;
  final double weight;

  _Neighbor({required this.node, required this.weight});
}

/// Implementasi algoritma A* (A-Star) untuk pencarian rute terpendek pada denah.
class AStar {
  /// Menghitung jarak Euclidean antara dua node (dalam meter).
  static double calculateDistance(Node a, Node b) {
    final dx = a.x - b.x;
    final dy = a.y - b.y;
    return math.sqrt(dx * dx + dy * dy);
  }

  /// Menghitung total panjang rute dari daftar node (dalam meter).
  static double calculatePathLength(List<Node> path) {
    if (path.length < 2) return 0.0;
    double total = 0.0;
    for (int i = 0; i < path.length - 1; i++) {
      total += calculateDistance(path[i], path[i + 1]);
    }
    return total;
  }

  /// Menemukan jalur terpendek dari [startNodeId] ke [targetNodeId].
  ///
  /// Mengembalikan daftar [Node] berurutan dari titik awal hingga tujuan.
  /// Jika tidak ada jalur yang menghubungkan keduanya, mengembalikan `null`.
  static List<Node>? findPath({
    required List<Node> nodes,
    required List<Edge> edges,
    required String startNodeId,
    required String targetNodeId,
  }) {
    if (startNodeId == targetNodeId) {
      final single = nodes.cast<Node?>().firstWhere(
            (n) => n?.id == startNodeId,
            orElse: () => null,
          );
      return single != null ? [single] : null;
    }

    // Index node berdasarkan ID
    final Map<String, Node> nodeMap = {for (var n in nodes) n.id: n};
    final startNode = nodeMap[startNodeId];
    final targetNode = nodeMap[targetNodeId];

    if (startNode == null || targetNode == null) {
      return null;
    }

    // Bangun adjacency list
    final Map<String, List<_Neighbor>> adj = {};
    for (var n in nodes) {
      adj[n.id] = [];
    }

    for (var edge in edges) {
      final u = nodeMap[edge.from];
      final v = nodeMap[edge.to];
      if (u == null || v == null) continue;

      final weight = edge.weight ?? calculateDistance(u, v);
      adj[u.id]?.add(_Neighbor(node: v, weight: weight));

      if (edge.bidirectional) {
        adj[v.id]?.add(_Neighbor(node: u, weight: weight));
      }
    }

    // Open set (node yang belum dievaluasi)
    final Set<String> openSet = {startNodeId};
    // Came from (pelacak jalur)
    final Map<String, String> cameFrom = {};

    // gScore: biaya dari titik awal ke node saat ini
    final Map<String, double> gScore = {
      for (var n in nodes) n.id: double.infinity,
    };
    gScore[startNodeId] = 0.0;

    // fScore: estimasi total biaya (gScore + heuristik ke tujuan)
    final Map<String, double> fScore = {
      for (var n in nodes) n.id: double.infinity,
    };
    fScore[startNodeId] = calculateDistance(startNode, targetNode);

    while (openSet.isNotEmpty) {
      // Pilih node di openSet dengan fScore terendah
      String currentId = openSet.first;
      double lowestF = fScore[currentId] ?? double.infinity;

      for (var id in openSet) {
        final f = fScore[id] ?? double.infinity;
        if (f < lowestF) {
          lowestF = f;
          currentId = id;
        }
      }

      // Jika sudah mencapai target, rekonstruksi jalur
      if (currentId == targetNodeId) {
        final List<Node> path = [];
        String? curr = currentId;
        while (curr != null) {
          final n = nodeMap[curr];
          if (n != null) path.insert(0, n);
          curr = cameFrom[curr];
        }
        return path;
      }

      openSet.remove(currentId);
      final currentNeighbors = adj[currentId] ?? [];

      for (var neighbor in currentNeighbors) {
        final neighborId = neighbor.node.id;
        final tentativeGScore =
            (gScore[currentId] ?? double.infinity) + neighbor.weight;

        if (tentativeGScore < (gScore[neighborId] ?? double.infinity)) {
          cameFrom[neighborId] = currentId;
          gScore[neighborId] = tentativeGScore;
          fScore[neighborId] =
              tentativeGScore + calculateDistance(neighbor.node, targetNode);

          if (!openSet.contains(neighborId)) {
            openSet.add(neighborId);
          }
        }
      }
    }

    // Tidak ada rute yang ditemukan
    return null;
  }
}
