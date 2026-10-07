import 'package:flutter_test/flutter_test.dart';
import 'package:smartparking/main.dart';

void main() {
  testWidgets('SmartParkingApp smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const SmartParkingApp());
    // Biarkan async layout loading selesai dan frame stabil
    await tester.pumpAndSettle();
    expect(find.byType(SmartParkingApp), findsOneWidget);
  });
}
