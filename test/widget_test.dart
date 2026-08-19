import 'package:flutter_test/flutter_test.dart';

import 'package:jmlcall_app/main.dart';

void main() {
  testWidgets('Home screen renders both modes', (WidgetTester tester) async {
    await tester.pumpWidget(const IntercomApp());

    expect(find.text('Panggil Rumah (Caller Mode)'), findsOneWidget);
    expect(find.text('Standby Rumah (Auto-Answer Callee Mode)'), findsOneWidget);
  });
}
