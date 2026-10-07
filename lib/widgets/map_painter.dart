import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../models/parking_models.dart';

/// CustomPainter untuk menggambar denah parkir 2D, slot, rute A*, dan posisi pengguna.
class MapPainter extends CustomPainter {
  final ParkingLayout layout;
  final List<Node> route;
  final ParkingSlot? targetSlot;
  final Node? userPosition;
  final Lobby? selectedLobby;
  final double scale; // Faktor pengali meter ke pixel

  MapPainter({
    required this.layout,
    required this.route,
    this.targetSlot,
    this.userPosition,
    this.selectedLobby,
    this.scale = 16.0, // 1 meter = 16 logical pixels
  });

  @override
  void paint(Canvas canvas, Size size) {
    // 1. Gambar latar belakang lantai parkir
    _drawFloor(canvas, size);

    // 2. Gambar marka jalan / edges graf
    _drawDrivewaysAndEdges(canvas);

    // 3. Gambar rute navigasi A* (jika ada)
    if (route.isNotEmpty) {
      _drawRoute(canvas);
    }

    // 4. Gambar slot-slot parkir
    _drawParkingSlots(canvas);

    // 5. Gambar Lobby (Pintu Masuk)
    _drawLobbies(canvas);

    // 6. Gambar Posisi Pengguna
    if (userPosition != null) {
      _drawUserPosition(canvas);
    }
  }

  Offset _toOffset(double meterX, double meterY) {
    return Offset(meterX * scale, meterY * scale);
  }

  void _drawFloor(Canvas canvas, Size size) {
    // Background lantai beton gelap modern
    final floorPaint = Paint()..color = const Color(0xFF161922);
    final rect = Rect.fromLTWH(0, 0, layout.width * scale, layout.height * scale);
    canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(16)), floorPaint);

    // Grid garis halus per 5 meter
    final gridPaint = Paint()
      ..color = const Color(0xFF232733)
      ..strokeWidth = 1.0;

    for (double x = 0; x <= layout.width; x += 5.0) {
      canvas.drawLine(_toOffset(x, 0), _toOffset(x, layout.height), gridPaint);
    }
    for (double y = 0; y <= layout.height; y += 5.0) {
      canvas.drawLine(_toOffset(0, y), _toOffset(layout.width, y), gridPaint);
    }

    // Border luar denah
    final borderPaint = Paint()
      ..color = const Color(0xFF33394B)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(16)), borderPaint);
  }

  void _drawDrivewaysAndEdges(Canvas canvas) {
    final edgePaint = Paint()
      ..color = const Color(0xFF2A3042)
      ..strokeWidth = 32.0 // Lebar lorong jalan berkendara (~2 meter)
      ..strokeCap = StrokeCap.round;

    final nodeMap = {for (var n in layout.nodes) n.id: n};

    // Gambar lorong aspal
    for (var edge in layout.edges) {
      final u = nodeMap[edge.from];
      final v = nodeMap[edge.to];
      if (u != null && v != null) {
        canvas.drawLine(_toOffset(u.x, u.y), _toOffset(v.x, v.y), edgePaint);
      }
    }

    // Marka jalan garis putus-putus di tengah
    final laneDividerPaint = Paint()
      ..color = const Color(0xFF40475E)
      ..strokeWidth = 1.5;

    for (var edge in layout.edges) {
      final u = nodeMap[edge.from];
      final v = nodeMap[edge.to];
      if (u != null && v != null) {
        _drawDashedLine(canvas, _toOffset(u.x, u.y), _toOffset(v.x, v.y), laneDividerPaint);
      }
    }
  }

  void _drawDashedLine(Canvas canvas, Offset p1, Offset p2, Paint paint) {
    const dashWidth = 6.0;
    const dashSpace = 6.0;
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

    // 1. Glow effect rute di latar belakang
    final glowPaint = Paint()
      ..color = const Color(0x6600E5FF)
      ..strokeWidth = 10.0
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
      ..strokeWidth = 4.0
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    canvas.drawPath(path, routePaint);

    // 3. Titik persimpangan rute
    final dotPaint = Paint()..color = Colors.white;
    for (int i = 0; i < route.length; i++) {
      final pos = _toOffset(route[i].x, route[i].y);
      canvas.drawCircle(pos, 3.0, dotPaint);
    }

    // 4. Gambar panah navigasi di setiap segmen
    for (int i = 0; i < route.length - 1; i++) {
      final p1 = _toOffset(route[i].x, route[i].y);
      final p2 = _toOffset(route[i + 1].x, route[i + 1].y);
      _drawDirectionArrow(canvas, p1, p2);
    }
  }

  void _drawDirectionArrow(Canvas canvas, Offset p1, Offset p2) {
    final mid = Offset((p1.dx + p2.dx) / 2, (p1.dy + p2.dy) / 2);
    final angle = math.atan2(p2.dy - p1.dy, p2.dx - p1.dx);
    const arrowSize = 6.0;

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

  void _drawParkingSlots(Canvas canvas) {
    for (var slot in layout.slots) {
      final isTarget = targetSlot?.id == slot.id;
      final slotWidthPx = slot.width * scale;
      final slotHeightPx = slot.height * scale;
      final center = _toOffset(slot.x, slot.y);

      final rect = Rect.fromCenter(
        center: center,
        width: slotWidthPx,
        height: slotHeightPx,
      );

      // Warna slot: Tersedia = Hijau, Terisi = Merah, Target = Aksen Emas/Neon
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

      // Fill slot
      final fillPaint = Paint()
        ..color = fillColor
        ..style = PaintingStyle.fill;
      canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(4)), fillPaint);

      // Border slot
      final borderPaint = Paint()
        ..color = borderColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = isTarget ? 2.5 : 1.2;
      canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(4)), borderPaint);

      // Teks ID slot (misal "A1")
      final textSpan = TextSpan(
        text: slot.id,
        style: TextStyle(
          color: isTarget ? const Color(0xFFFFD600) : Colors.white,
          fontSize: 10.0,
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

      // Status indicator icon/badge kecil di pojok slot
      final statusDotPaint = Paint()
        ..color = isTarget
            ? const Color(0xFFFFD600)
            : (slot.isAvailable ? const Color(0xFF00E676) : const Color(0xFFFF5252));
      canvas.drawCircle(
        Offset(rect.right - 4, rect.top + 4),
        2.5,
        statusDotPaint,
      );
    }
  }

  void _drawLobbies(Canvas canvas) {
    for (var lobby in layout.lobbies) {
      final pos = _toOffset(lobby.x, lobby.y);
      final isSelected = selectedLobby?.id == lobby.id;

      // Lingkaran luar berdenyut/glow
      final outerPaint = Paint()
        ..color = isSelected ? const Color(0x447C4DFF) : const Color(0x229E9E9E)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(pos, 16.0, outerPaint);

      // Lingkaran dalam Lobby
      final innerPaint = Paint()
        ..color = isSelected ? const Color(0xFF7C4DFF) : const Color(0xFF757575)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(pos, 8.0, innerPaint);

      // Icon titik putih di tengah
      final centerDotPaint = Paint()..color = Colors.white;
      canvas.drawCircle(pos, 3.0, centerDotPaint);

      // Label Nama Lobby
      final textSpan = TextSpan(
        text: lobby.name,
        style: TextStyle(
          color: isSelected ? const Color(0xFFB388FF) : Colors.white70,
          fontSize: 9.0,
          fontWeight: FontWeight.w600,
        ),
      );
      final textPainter = TextPainter(
        text: textSpan,
        textDirection: TextDirection.ltr,
      )..layout();

      textPainter.paint(
        canvas,
        Offset(pos.dx - textPainter.width / 2, pos.dy + 12),
      );
    }
  }

  void _drawUserPosition(Canvas canvas) {
    final pos = _toOffset(userPosition!.x, userPosition!.y);

    // Aura pendaran posisi pengguna
    final glowPaint = Paint()
      ..color = const Color(0x332979FF)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(pos, 14.0, glowPaint);

    // Ring putih
    final ringPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    canvas.drawCircle(pos, 7.0, ringPaint);

    // Titik biru di tengah
    final corePaint = Paint()
      ..color = const Color(0xFF2979FF)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(pos, 5.0, corePaint);
  }

  @override
  bool shouldRepaint(covariant MapPainter oldDelegate) {
    return oldDelegate.layout != layout ||
        oldDelegate.route != route ||
        oldDelegate.targetSlot != targetSlot ||
        oldDelegate.userPosition != userPosition ||
        oldDelegate.selectedLobby != selectedLobby;
  }
}
