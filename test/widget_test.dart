// flutter_soloud はネイティブライブラリを必要とするため、
// CI 環境でのウィジェットテストは実施しない。
// ロジック層のユニットテストをここに追加する。
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('placeholder', () {
    expect(1 + 1, 2);
  });
}
