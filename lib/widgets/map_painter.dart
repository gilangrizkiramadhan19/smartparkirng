import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../models/map_data.dart';
import '../models/parking_models.dart';

/// CustomPainter untuk menggambar denah 2D, ruangan, toilet, pintu, slot, rute A*, dan posisi pengguna
/// dengan ukuran teks dan pin tetap (tidak membesar berlebihan saat di-zoom) serta anti-tabrakan label.
class MapPainter extends CustomPainter {
  final ParkingLayout layout;
  final FloorData? floor;
  final List<Node> route;
  final ParkingSlot? targetSlot;
  final MapNode? targetDestination;
  final Node? userPosition;
  final double? headingDeg;
  final Lobby? selectedLobby;
  final double scale; // Faktor pengali meter ke canvas (misal 18.0)
  final double zoomScale; // Skala zoom saat ini dari InteractiveViewer (misal 0.5x - 6.0x)

  MapPainter({
    required this.layout,
    this.floor,
    required this.route,
    this.targetSlot,
    this.targetDestination,
    this.userPosition,
    this.headingDeg,
    this.selectedLobby,
    this.scale = 16.0,
    this.zoomScale = 1.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // 1. Gambar latar belakang denah
    _drawFloor(canvas, size);

    // 2. Gambar koridor / lintasan edge
    _drawDrivewaysAndEdges(canvas);

    // 3. Gambar rute navigasi A* (jika ada)
    if (route.isNotEmpty) {
      _drawRoute(canvas);
    }

    // 4. Gambar slot-slot parkir jika ada
    if (layout.slots.isNotEmpty) {
      _drawParkingSlots(canvas);
    }

    // 5. Gambar node ruangan, toilet, entrance, dan tujuan
    _drawNodes(canvas);

    // 6. Gambar Lobby jika ada
    if (layout.lobbies.isNotEmpty) {
      _drawLobbies(canvas);
    }

    // 7. Gambar Posisi Pengguna
    if (userPosition != null) {
      _drawUserPosition(canvas);
    }
  }

  Offset _toOffset(double meterX, double meterY) {
    return Offset(meterX * scale, meterY * scale);
  }

  double get _safeZoom => zoomScale <= 0 ? 1.0 : zoomScale;

  void _drawFloor(Canvas canvas, Size size) {
    final floorPaint = Paint()..color = const Color(0xFF161922);
    final width = floor?.width ?? layout.width;
    final height = floor?.length ?? layout.height;
    final rect = Rect.fromLTWH(0, 0, width * scale, height * scale);
    canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(16)), floorPaint);

    // Grid garis halus per 5 meter
    final gridPaint = Paint()
      ..color = const Color(0xFF232733)
      ..strokeWidth = 1.0 / _safeZoom;

    for (double x = 0; x <= width; x += 5.0) {
      canvas.drawLine(_toOffset(x, 0), _toOffset(x, height), gridPaint);
    }
    for (double y = 0; y <= height; y += 5.0) {
      canvas.drawLine(_toOffset(0, y), _toOffset(width, y), gridPaint);
    }

    // Border luar denah
    final borderPaint = Paint()
      ..color = const Color(0xFF33394B)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0 / _safeZoom;
    canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(16)), borderPaint);
  }

  void _drawDrivewaysAndEdges(Canvas canvas) {
    final edgePaint = Paint()
      ..color = const Color(0xFF252B3B)
      ..strokeWidth = 26.0
      ..strokeCap = StrokeCap.round;

    final edges = floor?.edges ?? layout.edges;
    final nodes = floor?.nodes ?? layout.nodes;
    final nodeMap = {for (var n in nodes) n.id: n};

    // Gambar koridor
    for (var edge in edges) {
      final u = nodeMap[edge.from];
      final v = nodeMap[edge.to];
      if (u != null && v != null) {
        canvas.drawLine(_toOffset(u.x, u.y), _toOffset(v.x, v.y), edgePaint);
      }
    }

    // Garis pandu putus-putus tengah koridor
    final laneDividerPaint = Paint()
      ..color = const Color(0xFF394158)
      ..strokeWidth = 1.5 / _safeZoom;

    for (var edge in edges) {
      final u = nodeMap[edge.from];
      final v = nodeMap[edge.to];
      if (u != null && v != null) {
        _drawDashedLine(canvas, _toOffset(u.x, u.y), _toOffset(v.x, v.y), laneDividerPaint);
      }
    }
  }

  void _drawDashedLine(Canvas canvas, Offset p1, Offset p2, Paint paint) {
    final dashWidth = 5.0 / _safeZoom;
    final dashSpace = 5.0 / _safeZoom;
    final dx = p2.dx - p1.dx;
    final dy = p2.dy - p1.dy;
    final distance = math.sqrt(dx * dx + dy * dy);
    if (distance == 0) return;

    final unitX = dx / distance;
    final unitY = dy / distance;

    double currentDist = 0.0;
    while (currentDist < distance) {
      final start = Offset(p1.dx + unitX * currentDist, p1.dy + unitY * currentDist);
      final nextDist = math.min(currentDist + dashWidth, distance);
      final end = Offset(p1.dx + unitX * nextDist, p1.dy + unitY * nextDist);
      canvas.drawLine(start, end, paint);
      currentDist += dashWidth + dashSpace;
    }
  }

  void _drawRoute(Canvas canvas) {
    if (route.length < 2) return;

    final zoom = _safeZoom;

    // 1. Glow effect rute di latar belakang
    final glowPaint = Paint()
      ..color = const Color(0x6600E5FF)
      ..strokeWidth = 10.0 / zoom
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    final path = Path();
    path.moveTo(route.first.x * scale, route.first.y * scale);
    for (int i = 1; i < route.length; i++) {
      path.lineTo(route[i].x * scale, route[i].y * scale);
    }
    canvas.drawPath(path, glowPaint);

    // 2. Garis inti rute utama (neon cyan)
    final routePaint = Paint()
      ..color = const Color(0xFF00E5FF)
      ..strokeWidth = 3.5 / zoom
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    canvas.drawPath(path, routePaint);

    // 3. Titik persimpangan rute
    final dotPaint = Paint()..color = Colors.white;
    for (int i = 0; i < route.length; i++) {
      final pos = _toOffset(route[i].x, route[i].y);
      canvas.drawCircle(pos, 3.0 / zoom, dotPaint);
    }

    // 4. Panah navigasi di setiap segmen
    for (int i = 0; i < route.length - 1; i++) {
      final p1 = _toOffset(route[i].x, route[i].y);
      final p2 = _toOffset(route[i + 1].x, route[i + 1].y);
      _drawDirectionArrow(canvas, p1, p2, zoom);
    }
  }

  void _drawDirectionArrow(Canvas canvas, Offset p1, Offset p2, double zoom) {
    final mid = Offset((p1.dx + p2.dx) / 2, (p1.dy + p2.dy) / 2);
    final angle = math.atan2(p2.dy - p1.dy, p2.dx - p1.dx);
    final arrowSize = 6.0 / zoom;

    final arrowPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;

    canvas.save();
    canvas.translate(mid.dx, mid.dy);
    canvas.rotate(angle);

    final arrowPath = Path()
      ..moveTo(arrowSize, 0)
      ..lineTo(-arrowSize, -arrowSize * 0.7)
      ..lineTo(-arrowSize * 0.5, 0)
      ..lineTo(-arrowSize, arrowSize * 0.7)
      ..close();

    canvas.drawPath(arrowPath, arrowPaint);
    canvas.restore();
  }

  void _drawNodes(Canvas canvas) {
    final rawNodes = floor?.nodes ?? [];
    if (rawNodes.isEmpty) return;

    final zoom = _safeZoom;
    final List<Rect> occupiedLabelRects = [];

    // Prioritaskan node target agar labelnya SELALU tampil pertama
    final sortedNodes = List<MapNode>.from(rawNodes);
    sortedNodes.sort((a, b) {
      final aIsTarget = targetDestination?.id == a.id ? 1 : 0;
      final bIsTarget = targetDestination?.id == b.id ? 1 : 0;
      if (aIsTarget != bIsTarget) return bIsTarget.compareTo(aIsTarget);

      // Prioritas berikutnya: toilet, room/slot, entrance, junction
      int typePriority(NodeType t) {
        switch (t) {
          case NodeType.toilet:
            return 4;
          case NodeType.room:
          case NodeType.slot:
            return 3;
          case NodeType.stairs:
          case NodeType.elevator:
            return 3;
          case NodeType.entrance:
            return 2;
          case NodeType.junction:
            return 1;
          default:
            return 0;
        }
      }

      return typePriority(b.type).compareTo(typePriority(a.type));
    });

    for (final node in sortedNodes) {
      if (node.type == NodeType.slot) continue; // slot parkir digambar di _drawParkingSlots

      final pos = _toOffset(node.x, node.y);
      final isTarget = targetDestination?.id == node.id;

      // 1. Gambar junction
      if (node.type == NodeType.junction && !isTarget) {
        final juncPaint = Paint()..color = const Color(0xFF4A5568);
        canvas.drawCircle(pos, 3.0 / zoom, juncPaint);
        continue;
      }

      // 2. Tentukan warna berdasarkan tipe node
      Color baseColor;
      switch (node.type) {
        case NodeType.room:
          baseColor = const Color(0xFF38BDF8); // Sky blue
          break;
        case NodeType.toilet:
          baseColor = const Color(0xFFA855F7); // Purple
          break;
        case NodeType.entrance:
          baseColor = const Color(0xFF10B981); // Emerald green
          break;
        case NodeType.stairs:
        case NodeType.elevator:
          baseColor = const Color(0xFFF59E0B); // Amber
          break;
        default:
          baseColor = const Color(0xFF94A3B8);
      }

      if (isTarget) {
        baseColor = const Color(0xFFFFD600); // Emas terang untuk target
      }

      // Outer glow jika target
      if (isTarget) {
        final glowPaint = Paint()
          ..color = const Color(0x66FFD600)
          ..style = PaintingStyle.fill;
        canvas.drawCircle(pos, 16.0 / zoom, glowPaint);
      }

      // Node pin circle (ukuran konstan di layar: ~6-8 dp)
      final pinRadius = (isTarget ? 7.5 : 5.5) / zoom;
      final innerRadius = (isTarget ? 3.5 : 2.0) / zoom;

      final pinPaint = Paint()
        ..color = baseColor
        ..style = PaintingStyle.fill;
      canvas.drawCircle(pos, pinRadius, pinPaint);

      final innerPaint = Paint()
        ..color = Colors.black87
        ..style = PaintingStyle.fill;
      canvas.drawCircle(pos, innerRadius, innerPaint);

      // 3. Kebijakan penampilan label teks:
      // - Node target: SELALU tampil
      // - Entrance: hanya tampil jika zoom >= 1.8x
      // - Junction: TIDAK diberi label
      // - Room, toilet, slot, stairs: tampil dengan collision check
      final shouldConsiderLabel = isTarget ||
          (node.type != NodeType.junction &&
              (node.type != NodeType.entrance || zoom >= 1.8));

      if (!shouldConsiderLabel) continue;

      final fontSize = (isTarget ? 11.5 : 10.0) / zoom;
      final textSpan = TextSpan(
        text: node.name,
        style: TextStyle(
          color: isTarget ? const Color(0xFFFFD600) : Colors.white,
          fontSize: fontSize,
          fontWeight: isTarget ? FontWeight.bold : FontWeight.w600,
        ),
      );

      final textPainter = TextPainter(
        text: textSpan,
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: 150.0 / zoom);

      // Ukuran background pill label
      final padH = 5.0 / zoom;
      final padV = 2.5 / zoom;
      final labelW = textPainter.width + padH * 2;
      final labelH = textPainter.height + padV * 2;
      final labelLeft = pos.dx - labelW / 2;
      final labelTop = pos.dy + pinRadius + (3.0 / zoom);
      final labelRect = Rect.fromLTWH(labelLeft, labelTop, labelW, labelH);

      // Collision Check: jika menimpa label yang sudah ada, lewati (kecuali jika node target)
      if (!isTarget) {
        final buffer = 2.0 / zoom;
        final expandedRect = labelRect.inflate(buffer);
        final collides = occupiedLabelRects.any((r) => r.overlaps(expandedRect));
        if (collides) {
          continue; // Lewati label ini agar tidak bertumpukan
        }
      }

      occupiedLabelRects.add(labelRect);

      // Gambar background pill semi transparan
      final bgPaint = Paint()
        ..color = isTarget
            ? const Color(0xEE1E222D)
            : const Color(0xCC121620)
        ..style = PaintingStyle.fill;

      final borderPaint = Paint()
        ..color = isTarget
            ? const Color(0xFFFFD600)
            : baseColor.withValues(alpha: 0.6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0 / zoom;

      final rrect = RRect.fromRectAndRadius(labelRect, Radius.circular(4.0 / zoom));
      canvas.drawRRect(rrect, bgPaint);
      canvas.drawRRect(rrect, borderPaint);

      // Gambar teks label di dalam pill
      textPainter.paint(
        canvas,
        Offset(labelLeft + padH, labelTop + padV),
      );
    }
  }

  void _drawParkingSlots(Canvas canvas) {
    final zoom = _safeZoom;

    for (var slot in layout.slots) {
      final isTarget = targetSlot?.id == slot.id || targetDestination?.id == slot.id;
      final slotWidthPx = slot.width * scale;
      final slotHeightPx = slot.height * scale;
      final center = _toOffset(slot.x, slot.y);

      final rect = Rect.fromCenter(
        center: center,
        width: slotWidthPx,
        height: slotHeightPx,
      );

      Color fillColor;
      Color borderColor;

      if (isTarget) {
        fillColor = const Color(0x66FFAB00);
        borderColor = const Color(0xFFFFD600);
      } else if (slot.isAvailable) {
        fillColor = const Color(0x3300E676);
        borderColor = const Color(0xFF00E676);
      } else {
        fillColor = const Color(0x33FF1744);
        borderColor = const Color(0xFFFF5252);
      }

      final fillPaint = Paint()
        ..color = fillColor
        ..style = PaintingStyle.fill;
      canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(4)), fillPaint);

      final borderPaint = Paint()
        ..color = borderColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = (isTarget ? 2.5 : 1.2) / zoom;
      canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(4)), borderPaint);

      // Teks slot tetap berukuran ~10 sp di layar
      final fontSize = 10.0 / zoom;
      final textSpan = TextSpan(
        text: slot.id,
        style: TextStyle(
          color: isTarget ? const Color(0xFFFFD600) : Colors.white,
          fontSize: fontSize,
          fontWeight: FontWeight.bold,
        ),
      );
      final textPainter = TextPainter(
        text: textSpan,
        textDirection: TextDirection.ltr,
      )..layout();

      textPainter.paint(
        canvas,
        Offset(center.dx - textPainter.width / 2, center.dy - textPainter.height / 2),
      );
    }
  }

  void _drawLobbies(Canvas canvas) {
    final zoom = _safeZoom;
    for (var lobby in layout.lobbies) {
      final pos = _toOffset(lobby.x, lobby.y);
      final isSelected = selectedLobby?.id == lobby.id;

      final outerPaint = Paint()
        ..color = isSelected ? const Color(0x447C4DFF) : const Color(0x229E9E9E)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(pos, 14.0 / zoom, outerPaint);

      final innerPaint = Paint()
        ..color = isSelected ? const Color(0xFF7C4DFF) : const Color(0xFF757575)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(pos, 7.0 / zoom, innerPaint);
    }
  }

  void _drawUserPosition(Canvas canvas) {
    final zoom = _safeZoom;
    final pos = _toOffset(userPosition!.x, userPosition!.y);

    // Aura pendaran posisi pengguna (~14 dp di layar)
    final glowPaint = Paint()
      ..color = const Color(0x332979FF)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(pos, 14.0 / zoom, glowPaint);

    // Ring putih (~7 dp di layar)
    final ringPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0 / zoom;
    canvas.drawCircle(pos, 7.0 / zoom, ringPaint);

    // Titik biru di tengah (~5 dp di layar)
    final corePaint = Paint()
      ..color = const Color(0xFF2979FF)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(pos, 5.0 / zoom, corePaint);

    // Indikator arah hadap (heading) jika tersedia
    if (headingDeg != null) {
      final rad = headingDeg! * math.pi / 180.0;
      final headingPaint = Paint()
        ..color = const Color(0xFF00E5FF)
        ..style = PaintingStyle.fill;

      canvas.save();
      canvas.translate(pos.dx, pos.dy);
      canvas.rotate(rad);

      final pointerLength = 11.0 / zoom;
      final pointerBase = 5.0 / zoom;
      final pointerWing = 3.5 / zoom;
      final pointerIndent = 6.5 / zoom;

      final pointerPath = Path()
        ..moveTo(pointerLength, 0)
        ..lineTo(pointerBase, -pointerWing)
        ..lineTo(pointerIndent, 0)
        ..lineTo(pointerBase, pointerWing)
        ..close();

      canvas.drawPath(pointerPath, headingPaint);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant MapPainter oldDelegate) {
    final userMoved = (oldDelegate.userPosition == null && userPosition != null) ||
        (oldDelegate.userPosition != null && userPosition == null) ||
        (oldDelegate.userPosition != null &&
            userPosition != null &&
            (oldDelegate.userPosition!.x != userPosition!.x ||
                oldDelegate.userPosition!.y != userPosition!.y));

    final headingChanged = (oldDelegate.headingDeg == null && headingDeg != null) ||
        (oldDelegate.headingDeg != null && headingDeg == null) ||
        (oldDelegate.headingDeg != null &&
            headingDeg != null &&
            (oldDelegate.headingDeg! - headingDeg!).abs() > 0.5);

    return oldDelegate.layout != layout ||
        oldDelegate.floor != floor ||
        oldDelegate.route != route ||
        oldDelegate.targetSlot != targetSlot ||
        oldDelegate.targetDestination != targetDestination ||
        userMoved ||
        headingChanged ||
        oldDelegate.selectedLobby != selectedLobby ||
        (oldDelegate.zoomScale - zoomScale).abs() > 0.05;
  }
}
