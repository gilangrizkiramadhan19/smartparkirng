import 'package:flutter/material.dart';
import '../models/map_data.dart';
import '../services/navigation_controller.dart';

/// Modal bottom sheet untuk memilih tujuan atau titik awal navigasi (ruangan, toilet, entrance, slot, dll).
class DestinationPickerSheet extends StatefulWidget {
  final NavigationController controller;
  final bool isSelectingStart;

  const DestinationPickerSheet({
    super.key,
    required this.controller,
    this.isSelectingStart = false,
  });

  static Future<MapNode?> show(
    BuildContext context,
    NavigationController controller, {
    bool isSelectingStart = false,
  }) {
    return showModalBottomSheet<MapNode>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E222D),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => DestinationPickerSheet(
        controller: controller,
        isSelectingStart: isSelectingStart,
      ),
    );
  }

  @override
  State<DestinationPickerSheet> createState() => _DestinationPickerSheetState();
}

class _DestinationPickerSheetState extends State<DestinationPickerSheet> {
  final TextEditingController _searchController = TextEditingController();
  NodeType? _selectedTypeFilter; // null = Semua
  String _searchQuery = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  IconData _getIconForType(NodeType type) {
    switch (type) {
      case NodeType.room:
        return Icons.meeting_room;
      case NodeType.toilet:
        return Icons.wc;
      case NodeType.entrance:
        return Icons.door_front_door;
      case NodeType.slot:
        return Icons.local_parking;
      case NodeType.stairs:
        return Icons.stairs;
      case NodeType.elevator:
        return Icons.elevator;
      default:
        return Icons.place;
    }
  }

  Color _getColorForType(NodeType type) {
    switch (type) {
      case NodeType.room:
        return const Color(0xFF38BDF8);
      case NodeType.toilet:
        return const Color(0xFFA855F7);
      case NodeType.entrance:
        return const Color(0xFF10B981);
      case NodeType.slot:
        return const Color(0xFF00E676);
      case NodeType.stairs:
      case NodeType.elevator:
        return const Color(0xFFF59E0B);
      default:
        return const Color(0xFF94A3B8);
    }
  }

  @override
  Widget build(BuildContext context) {
    final destinations = widget.controller.availableDestinations;

    // Kumpulkan tipe node yang tersedia pada denah saat ini (kecuali junction)
    final availableTypes = destinations.map((d) => d.type).toSet().toList();

    // Filter daftar tujuan berdasarkan teks pencarian dan filter tipe
    final filtered = destinations.where((d) {
      final matchesSearch = _searchQuery.isEmpty ||
          d.name.toLowerCase().contains(_searchQuery.toLowerCase()) ||
          d.id.toLowerCase().contains(_searchQuery.toLowerCase());
      final matchesType = _selectedTypeFilter == null || d.type == _selectedTypeFilter;
      return matchesSearch && matchesType;
    }).toList();

    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      expand: false,
      builder: (context, scrollController) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Handle drag bar
              Center(
                child: Container(
                  margin: const EdgeInsets.symmetric(vertical: 12),
                  width: 44,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),

              // Judul Modal
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    widget.isSelectingStart ? 'Pilih Lokasi Awal' : 'Pilih Tujuan Navigasi',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white70),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),

              const SizedBox(height: 8),

              // Kolom Pencarian Nama Tujuan
              TextField(
                controller: _searchController,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                decoration: InputDecoration(
                  hintText: 'Cari nama ruangan, toilet, pintu...',
                  hintStyle: const TextStyle(color: Colors.white38),
                  prefixIcon: const Icon(Icons.search, color: Color(0xFF00E5FF)),
                  suffixIcon: _searchQuery.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, color: Colors.white54),
                          onPressed: () {
                            _searchController.clear();
                            setState(() {
                              _searchQuery = '';
                            });
                          },
                        )
                      : null,
                  filled: true,
                  fillColor: const Color(0xFF161922),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                ),
                onChanged: (val) {
                  setState(() {
                    _searchQuery = val.trim();
                  });
                },
              ),

              const SizedBox(height: 12),

              // Chip Filter per Tipe Node
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    FilterChip(
                      selected: _selectedTypeFilter == null,
                      label: const Text('Semua'),
                      selectedColor: const Color(0xFF00E5FF),
                      labelStyle: TextStyle(
                        color: _selectedTypeFilter == null ? Colors.black : Colors.white70,
                        fontWeight: _selectedTypeFilter == null ? FontWeight.bold : FontWeight.normal,
                      ),
                      backgroundColor: const Color(0xFF161922),
                      checkmarkColor: Colors.black,
                      onSelected: (_) {
                        setState(() {
                          _selectedTypeFilter = null;
                        });
                      },
                    ),
                    const SizedBox(width: 8),
                    ...availableTypes.map((type) {
                      final isSelected = _selectedTypeFilter == type;
                      return Padding(
                        padding: const EdgeInsets.only(right: 8.0),
                        child: FilterChip(
                          selected: isSelected,
                          label: Text(type.toDisplayString()),
                          selectedColor: _getColorForType(type),
                          labelStyle: TextStyle(
                            color: isSelected ? Colors.black : Colors.white70,
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                          ),
                          backgroundColor: const Color(0xFF161922),
                          checkmarkColor: Colors.black,
                          onSelected: (_) {
                            setState(() {
                              _selectedTypeFilter = isSelected ? null : type;
                            });
                          },
                        ),
                      );
                    }),
                  ],
                ),
              ),

              const SizedBox(height: 12),

              // Daftar Tujuan
              Expanded(
                child: filtered.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.search_off, size: 48, color: Colors.white24),
                            const SizedBox(height: 8),
                            Text(
                              _searchQuery.isNotEmpty
                                  ? 'Tidak ditemukan tujuan dengan nama "$_searchQuery"'
                                  : 'Tidak ada tujuan pada filter ini',
                              style: const TextStyle(color: Colors.white54),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      )
                    : ListView.separated(
                        controller: scrollController,
                        itemCount: filtered.length,
                        separatorBuilder: (context, index) => const Divider(color: Colors.white10, height: 1),
                        itemBuilder: (ctx, index) {
                          final node = filtered[index];
                          final color = _getColorForType(node.type);
                          final isSelected = widget.isSelectingStart
                              ? widget.controller.startNode?.id == node.id
                              : widget.controller.targetDestination?.id == node.id;

                          return ListTile(
                            contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            leading: Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: color.withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: color.withValues(alpha: 0.4)),
                              ),
                              child: Icon(_getIconForType(node.type), color: color, size: 22),
                            ),
                            title: Text(
                              node.name,
                              style: TextStyle(
                                color: isSelected ? const Color(0xFFFFD600) : Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 15,
                              ),
                            ),
                            subtitle: Text(
                              '${node.type.toDisplayString()} • Posisi: (${node.x.toStringAsFixed(1)}m, ${node.y.toStringAsFixed(1)}m)',
                              style: const TextStyle(color: Colors.white54, fontSize: 12),
                            ),
                            trailing: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: isSelected
                                    ? const Color(0xFFFFD600)
                                    : const Color(0xFF00E5FF),
                                foregroundColor: Colors.black,
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                              onPressed: () {
                                if (widget.isSelectingStart) {
                                  widget.controller.setStartNode(node);
                                } else {
                                  widget.controller.selectDestination(node);
                                }
                                Navigator.pop(context, node);
                              },
                              child: Text(
                                isSelected
                                    ? (widget.isSelectingStart ? 'Awal' : 'Terpilih')
                                    : (widget.isSelectingStart ? 'Pilih Awal' : 'Pilih'),
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}
