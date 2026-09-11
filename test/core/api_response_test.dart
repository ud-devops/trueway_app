import 'package:flutter_test/flutter_test.dart';
import 'package:trueway_farms/core/network/api_response.dart';

class _Item {
  const _Item(this.id);
  final int id;
  static _Item fromJson(Map<String, dynamic> j) => _Item(j['id'] as int);
}

/// The backend returns two envelope shapes:
///   `{ "error": false, "data": [...] }`          (sliders, ads, brands)
///   `{ "data": [...], "links": ..., "meta": ...}` (paginated products)
void main() {
  group('unwrapList', () {
    test('unwraps the simple envelope', () {
      final out = unwrapList(
        {
          'error': false,
          'data': [
            {'id': 1},
            {'id': 2},
          ],
        },
        _Item.fromJson,
      );
      expect(out.map((e) => e.id), [1, 2]);
    });

    test('accepts a bare list', () {
      final out = unwrapList([
        {'id': 3},
      ], _Item.fromJson,);
      expect(out.single.id, 3);
    });

    test('returns empty rather than throwing on junk', () {
      expect(unwrapList(null, _Item.fromJson), isEmpty);
      expect(unwrapList({'data': 'nope'}, _Item.fromJson), isEmpty);
      expect(unwrapList({'no_data_key': 1}, _Item.fromJson), isEmpty);
    });

    test('skips non-map entries instead of failing the whole list', () {
      final out = unwrapList({
        'data': [
          {'id': 1},
          'garbage',
          null,
        ],
      }, _Item.fromJson,);
      expect(out.single.id, 1);
    });
  });

  group('unwrapObject', () {
    test('unwraps a wrapped object', () {
      expect(unwrapObject({'data': {'id': 9}}, _Item.fromJson)?.id, 9);
    });
    test('accepts a bare object', () {
      expect(unwrapObject({'id': 9}, _Item.fromJson)?.id, 9);
    });
    test('returns null for non-objects', () {
      expect(unwrapObject('nope', _Item.fromJson), isNull);
      expect(unwrapObject(null, _Item.fromJson), isNull);
    });
  });

  group('PaginatedResponse', () {
    test('reads items and meta', () {
      final page = PaginatedResponse.fromJson({
        'data': [
          {'id': 1},
          {'id': 2},
        ],
        'meta': {'current_page': 1, 'last_page': 3, 'per_page': 2, 'total': 6},
      }, _Item.fromJson,);

      expect(page.items.length, 2);
      expect(page.meta.currentPage, 1);
      expect(page.meta.lastPage, 3);
      expect(page.hasMore, isTrue);
      expect(page.nextPage, 2);
    });

    test('reports no more pages on the last page', () {
      final page = PaginatedResponse.fromJson({
        'data': <Map<String, dynamic>>[],
        'meta': {'current_page': 3, 'last_page': 3},
      }, _Item.fromJson,);
      expect(page.hasMore, isFalse);
    });

    test('falls back sanely when meta is missing entirely', () {
      final page = PaginatedResponse.fromJson({
        'data': [
          {'id': 1},
        ],
      }, _Item.fromJson,);
      expect(page.meta.currentPage, 1);
      expect(page.meta.lastPage, 1);
      expect(page.meta.perPage, 1);
      expect(page.hasMore, isFalse);
    });

    test('parses string-valued meta numbers', () {
      final meta = PaginationMeta.fromJson({
        'current_page': '2',
        'last_page': '5',
        'per_page': '20',
        'total': '96',
      });
      expect(meta.currentPage, 2);
      expect(meta.lastPage, 5);
      expect(meta.total, 96);
    });
  });
}
