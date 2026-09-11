import 'package:flutter_test/flutter_test.dart';
import 'package:trueway_farms/core/utils/json_utils.dart';

/// These helpers exist because the Botble backend mixes types across fields
/// (`price: 921.501`, `is_featured: 1`, `quantity: "0"`). The whole data layer
/// depends on them never throwing.
void main() {
  group('asInt', () {
    test('passes ints through', () => expect(asInt(7), 7));
    test('rounds doubles', () {
      expect(asInt(7.4), 7);
      expect(asInt(7.6), 8);
    });
    test('parses numeric strings', () {
      expect(asInt('42'), 42);
      expect(asInt('42.7'), 43);
    });
    test('falls back on junk and null', () {
      expect(asInt(null), 0);
      expect(asInt('abc'), 0);
      expect(asInt({}, 9), 9);
    });
  });

  group('asDouble', () {
    test('handles num and string', () {
      expect(asDouble(921.501), 921.501);
      expect(asDouble(3), 3.0);
      expect(asDouble('921.501'), 921.501);
    });
    test('falls back on junk and null', () {
      expect(asDouble(null), 0);
      expect(asDouble('n/a'), 0);
      expect(asDouble('n/a', 1.5), 1.5);
    });
  });

  group('asBool', () {
    test('accepts the backend truthy forms', () {
      expect(asBool(true), isTrue);
      expect(asBool(1), isTrue);
      expect(asBool('1'), isTrue);
      expect(asBool('true'), isTrue);
      expect(asBool('TRUE'), isTrue);
      expect(asBool('yes'), isTrue);
    });
    test('treats everything else as false', () {
      expect(asBool(0), isFalse);
      expect(asBool('0'), isFalse);
      expect(asBool('no'), isFalse);
      expect(asBool(null), isFalse);
    });
  });

  group('asString / asStringOrNull', () {
    test('stringifies non-strings', () => expect(asString(12), '12'));
    test('uses the default for null', () => expect(asString(null, 'x'), 'x'));
    test('maps empty to null', () {
      expect(asStringOrNull(''), isNull);
      expect(asStringOrNull(null), isNull);
      expect(asStringOrNull('a'), 'a');
    });
  });

  group('collection helpers', () {
    test('asStringList drops nulls and stringifies', () {
      expect(asStringList(['a', null, 2]), ['a', '2']);
      expect(asStringList('not a list'), isEmpty);
    });
    test('asMapList keeps only maps', () {
      expect(
        asMapList([
          {'a': 1},
          'skip',
          null,
        ]),
        [
          {'a': 1},
        ],
      );
      expect(asMapList(null), isEmpty);
    });
    test('asMap returns an empty map for non-maps', () {
      expect(asMap({'a': 1}), {'a': 1});
      expect(asMap('nope'), isEmpty);
      expect(asMap(null), isEmpty);
    });
  });
}
