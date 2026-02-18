import 'package:flutter_test/flutter_test.dart';

import 'package:infkey/main.dart';

void main() {
  testWidgets('App smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const InfKeyApp());
    await tester.pump();
    // アプリが例外なく起動できることだけを確認する
    expect(tester.takeException(), isNull);
  });
}
