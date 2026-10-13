import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../services/ar_sensor_service.dart';

/// Bottom sheet dialog untuk memindai kode QR kalibrasi posisi awal dan orientasi.
class ArQrScannerSheet extends StatefulWidget {
  final ARSensorService sensorService;

  const ArQrScannerSheet({super.key, required this.sensorService});

  static Future<bool?> show(BuildContext context, ARSensorService sensorService) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E222D),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => ArQrScannerSheet(sensorService: sensorService),
    );
  }

  @override
  State<ArQrScannerSheet> createState() => _ArQrScannerSheetState();
}

class _ArQrScannerSheetState extends State<ArQrScannerSheet> {
  final MobileScannerController _scannerController = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  final TextEditingController _textController = TextEditingController();
  bool _isProcessing = false;
  String? _errorMessage;

  @override
  void dispose() {
    _scannerController.dispose();
    _textController.dispose();
    super.dispose();
  }

  void _handleRawScannedText(String raw) {
    if (_isProcessing) return;
    setState(() {
      _isProcessing = true;
      _errorMessage = null;
    });

    String nodeId = raw.trim();
    double? heading;

    // Coba parse jika formatnya JSON, e.g. {"node":"lobby_A","heading":90}
    if (raw.trim().startsWith('{') && raw.trim().endsWith('}')) {
      try {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        if (decoded.containsKey('node')) {
          nodeId = decoded['node'].toString();
        }
        if (decoded.containsKey('heading')) {
          heading = (decoded['heading'] as num).toDouble();
        }
      } catch (_) {
        // Fallback gunakan string mentah
      }
    }

    final success = widget.sensorService.calibrateWithQR(
      nodeId: nodeId,
      headingOnMap: heading,
    );

    if (success) {
      if (mounted) {
        Navigator.pop(context, true);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFF00E676),
            content: Row(
              children: [
                const Icon(Icons.check_circle, color: Colors.black),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Posisi berhasil dikalibrasi ke node "$nodeId"${heading != null ? ' (Heading: ${heading.toStringAsFixed(0)}°)' : ''}',
                    style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ),
        );
      }
    } else {
      setState(() {
        _isProcessing = false;
        _errorMessage = 'Node "$nodeId" tidak ditemukan pada denah denah parkir ini.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(
        top: 20,
        left: 20,
        right: 20,
        bottom: 20 + bottomInset,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header Bar
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Row(
                children: [
                  Icon(Icons.qr_code_scanner, color: Color(0xFF00E5FF)),
                  SizedBox(width: 8),
                  Text(
                    'Kalibrasi Posisi via QR',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              IconButton(
                icon: const Icon(Icons.close, color: Colors.white70),
                onPressed: () => Navigator.pop(context, false),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Arahkan kamera ke stiker QR denah (format Node ID langsung atau JSON {"node":"c_l1","heading":90})',
            style: TextStyle(color: Colors.white60, fontSize: 13),
          ),
          const SizedBox(height: 16),

          // Area Scanner Kamera
          Container(
            height: 240,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: const Color(0xFF00E5FF), width: 2),
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              children: [
                MobileScanner(
                  controller: _scannerController,
                  onDetect: (capture) {
                    final barcodes = capture.barcodes;
                    for (final barcode in barcodes) {
                      final raw = barcode.rawValue;
                      if (raw != null && raw.isNotEmpty) {
                        _handleRawScannedText(raw);
                        break;
                      }
                    }
                  },
                ),
                // Flashlight toggle
                Positioned(
                  bottom: 12,
                  right: 12,
                  child: IconButton.filled(
                    style: IconButton.styleFrom(
                      backgroundColor: Colors.black54,
                    ),
                    icon: const Icon(Icons.flash_on, color: Colors.amber),
                    onPressed: () => _scannerController.toggleTorch(),
                  ),
                ),
              ],
            ),
          ),

          if (_errorMessage != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0x33FF5252),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFFF5252)),
              ),
              child: Text(
                _errorMessage!,
                style: const TextStyle(color: Color(0xFFFF8A80), fontSize: 12),
              ),
            ),
          ],

          const SizedBox(height: 16),
          // Fallback input manual teks
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _textController,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'Atau ketik ID Node (cth: c_l1, L1)',
                    hintStyle: const TextStyle(color: Colors.white38, fontSize: 13),
                    isDense: true,
                    filled: true,
                    fillColor: const Color(0xFF2A2E3D),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onSubmitted: _handleRawScannedText,
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00E5FF),
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                onPressed: () {
                  if (_textController.text.isNotEmpty) {
                    _handleRawScannedText(_textController.text);
                  }
                },
                child: const Text('Terapkan', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
