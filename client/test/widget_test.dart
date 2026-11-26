import 'package:flutter_test/flutter_test.dart';
import 'package:creatorplaza_bots/models.dart';

void main() {
  test('decodeConfig parses JSON string', () {
    final cfg = decodeConfig('{"modules":[{"type":"command"}]}');
    expect(cfg['modules'], isA<List>());
    expect(decodeConfig(''), isEmpty);
    expect(decodeConfig(null), isEmpty);
  });
}
