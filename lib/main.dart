import 'package:flutter/material.dart';
import 'pages/map_page.dart';
import 'services/navigation_controller.dart';
import 'services/parking_repository.dart';
import 'services/position_provider.dart';

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
  late final PositionProvider _positionProvider;
  late final NavigationController _navigationController;

  @override
  void initState() {
    super.initState();
    _repository = MockParkingRepository();
    _positionProvider = SimulatedPositionProvider();
    _navigationController = NavigationController(
      repository: _repository,
      positionProvider: _positionProvider,
    );
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
