import 'package:flutter_test/flutter_test.dart';
import 'package:hourglass/main.dart';

void main() {
  testWidgets('Hourglass home screen shows the new brand', (tester) async {
    await tester.pumpWidget(const HourglassApp());
    await tester.pump();
    expect(find.text('Hourglass'), findsOneWidget);
  });
}
