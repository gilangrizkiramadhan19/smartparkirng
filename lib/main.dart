import 'package:flutter/material.dart';
import 'pages/map_page.dart';
import 'services/navigation_controller.dart';
import 'services/parking_repository.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SmartParkingApp());
}

class SmartParkingApp extends StatefulWidget {
  const SmartParkingApp({super.key});

  @override
  State<SmartParkingApp> createState() => _SmartParkingAppState();
}

class _SmartParkingAppState extends State<SmartParkingApp> {
  late final ParkingRepository _repository;
  late final NavigationController _navigationController;

  @override
  void initState() {
    super.initState();
    // Tahap 1: Menggunakan MockParkingRepository
    _repository = MockParkingRepository();
    _navigationController = NavigationController(repository: _repository);
  }

  @override
  void dispose() {
    _navigationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smart Indoor Parking',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF12141A),
        colorScheme: ColorScheme.dark(
          primary: const Color(0xFF00E5FF),
          secondary: const Color(0xFF00E676),
          surface: const Color(0xFF1E222D),
          error: const Color(0xFFFF1744),
        ),
        useMaterial3: true,
      ),
      home: MapPage(controller: _navigationController),
    );
  }
}
