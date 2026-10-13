import 'package:flutter/material.dart';
import '../services/ar_sensor_service.dart';

/// Modal bottom sheet untuk kalibrasi manual orientasi kompas, mode dead reckoning, dan titik awal.
class ArManualCalibrationSheet extends StatefulWidget {
  final ARSensorService sensorService;

  const ArManualCalibrationSheet({super.key, required this.sensorService});

  static Future<void> show(BuildContext context, ARSensorService sensorService) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E222D),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => ArManualCalibrationSheet(sensorService: sensorService),
    );
  }

  @override
  State<ArManualCalibrationSheet> createState() => _ArManualCalibrationSheetState();
}

class _ArManualCalibrationSheetState extends State<ArManualCalibrationSheet> {
  late double _offsetDeg;
  late double _stepLength;
  late bool _isSimulation;

  @override
  void initState() {
    super.initState();
    _offsetDeg = widget.sensorService.mapHeadingOffsetDeg;
    _stepLength = widget.sensorService.stepLengthMeters;
    _isSimulation = widget.sensorService.isSimulationMode;
  }

  @override
  Widget build(BuildContext context) {
    final layout = widget.sensorService.controller.layout;

    return Padding(
      padding: const EdgeInsets.all(20.0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Row(
                children: [
                  Icon(Icons.tune, color: Color(0xFF00FF88)),
                  SizedBox(width: 8),
                  Text(
                    'Pengaturan & Kalibrasi AR',
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
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // 1. Toggle Mode: Simulasi vs Dead Reckoning
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF2A2E3D),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Mode Simulasi Posisi',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      _isSimulation
                          ? 'Posisi bergerak otomatis dari controller'
                          : 'Posisi bergerak dari deteksi langkah kaki (Dead Reckoning)',
                      style: const TextStyle(color: Colors.white54, fontSize: 11),
                    ),
                  ],
                ),
                Switch(
                  value: _isSimulation,
                  activeThumbColor: const Color(0xFF00FF88),
                  onChanged: (val) {
                    setState(() => _isSimulation = val);
                    widget.sensorService.setSimulationMode(val);
                  },
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // 2. Slider Offset Heading Kompas
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF2A2E3D),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Offset Sudut Denah vs Utara',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      '${_offsetDeg.toStringAsFixed(0)}°',
                      style: const TextStyle(
                        color: Color(0xFF00E5FF),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                const Text(
                  'Geser slider jika panah di layar serong terhadap lorong fisik asli',
                  style: TextStyle(color: Colors.white54, fontSize: 11),
                ),
                Slider(
                  value: _offsetDeg,
                  min: 0,
                  max: 360,
                  divisions: 72,
                  activeColor: const Color(0xFF00E5FF),
                  inactiveColor: Colors.white24,
                  onChanged: (val) {
                    setState(() => _offsetDeg = val);
                    widget.sensorService.setManualHeadingOffset(val);
                  },
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // 3. Slider Panjang Langkah
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF2A2E3D),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Panjang Langkah Kaki',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      '${_stepLength.toStringAsFixed(2)} m',
                      style: const TextStyle(
                        color: Color(0xFF00FF88),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                Slider(
                  value: _stepLength,
                  min: 0.4,
                  max: 1.2,
                  divisions: 16,
                  activeColor: const Color(0xFF00FF88),
                  inactiveColor: Colors.white24,
                  onChanged: (val) {
                    setState(() => _stepLength = val);
                    widget.sensorService.setStepLength(val);
                  },
                ),
              ],
            ),
          ),

          if (layout != null && layout.lobbies.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Text(
              'Reset Posisi ke Pintu Masuk / Lobby:',
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: layout.lobbies.map((lobby) {
                return ActionChip(
                  backgroundColor: const Color(0xFF2A2E3D),
                  label: Text(
                    lobby.name,
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                  avatar: const Icon(Icons.login, size: 16, color: Color(0xFF00E5FF)),
                  onPressed: () {
                    widget.sensorService.calibrateWithQR(nodeId: lobby.entryNodeId);
                    Navigator.pop(context);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Posisi disetel ke ${lobby.name}'),
                        backgroundColor: const Color(0xFF1E222D),
                      ),
                    );
                  },
                );
              }).toList(),
            ),
          ],

          const SizedBox(height: 20),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00FF88),
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () => Navigator.pop(context),
            child: const Text('Selesai', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }
}
