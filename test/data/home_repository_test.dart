import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:trueway_farms/core/errors/api_exception.dart';
import 'package:trueway_farms/core/network/api_client.dart';
import 'package:trueway_farms/data/models/home_sections.dart';
import 'package:trueway_farms/data/repositories/home_repository.dart';

/// Canned response for one request.
class _Canned {
  const _Canned(this.statusCode, this.body);
  final int statusCode;
  final Object body;
}

/// Replays canned responses keyed by path and records what was sent.
///
/// Same shape as the adapter in `auth_repository_test.dart` — that pattern
/// already existed, so there is no excuse for a repository to ship untested,
/// and nothing here touches the network.
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.responses);

  final Map<String, _Canned> responses;
  final List<RequestOptions> requests = [];

  /// Paths that have been asked for more than once get successive responses.
  final Map<String, List<_Canned>> sequences = {};

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final queued = sequences[options.path];
    final canned = (queued != null && queued.isNotEmpty)
        ? queued.removeAt(0)
        : responses[options.path] ??
            const _Canned(404, {'message': 'no canned response'});
    return ResponseBody.fromString(
      jsonEncode(canned.body),
      canned.statusCode,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Future<({HomeRepository repo, _FakeAdapter adapter})> _build(
  Map<String, _Canned> responses, {
  Map<String, List<_Canned>> sequences = const {},
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final adapter = _FakeAdapter(responses);
  adapter.sequences.addAll(
    sequences.map((k, v) => MapEntry(k, List<_Canned>.from(v))),
  );
  final dio = Dio()..httpClientAdapter = adapter;
  return (repo: HomeRepository(ApiClient(prefs: prefs, dio: dio)), adapter: adapter);
}

const String _prefixedSections = '/ecommerce/top-products-group';
const String _legacySections = '/top-products-group';

Map<String, dynamic> _sectionsBody({List<dynamic> topSelling = const []}) => {
      'error': false,
      'data': {
        'top_selling': topSelling,
        'trending': <dynamic>[],
        'recently_added': <dynamic>[],
        'top_rated': <dynamic>[],
      },
      'message': 'All product sections with 4 products each',
    };

const Map<String, dynamic> _product = {
  'id': 118,
  'slug': 'desi-khand',
  'name': 'Desi Khand',
  'price': 943.95,
  'price_formatted': '₹943.95',
  'original_price': 1199.1,
  'is_out_of_stock': false,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('sections', () {
    test('uses the /ecommerce-prefixed path and parses the envelope', () async {
      final t = await _build({
        _prefixedSections: _Canned(200, _sectionsBody(topSelling: [_product])),
      });

      final s = await t.repo.sections();

      expect(s.topSelling.single.id, 118);
      expect(t.adapter.requests.single.path, _prefixedSections);
      expect(t.adapter.requests.single.uri.queryParameters['limit'], '4');
    });

    test('falls back to the unprefixed constant on a 404', () async {
      final t = await _build({
        _prefixedSections: const _Canned(404, {'message': 'not found'}),
        _legacySections: _Canned(200, _sectionsBody(topSelling: [_product])),
      });

      final s = await t.repo.sections();

      expect(s.topSelling, hasLength(1));
      expect(
        t.adapter.requests.map((r) => r.path),
        [_prefixedSections, _legacySections],
      );
    });

    test('does not fall back on a non-404 failure', () async {
      // A 500 from the prefixed route means the route exists and broke.
      // Retrying the dead legacy path would turn it into a bogus 404.
      final t = await _build({
        _prefixedSections: const _Canned(500, {'message': 'boom'}),
        _legacySections: _Canned(200, _sectionsBody()),
      });

      await expectLater(
        t.repo.sections(),
        throwsA(
          isA<ApiException>()
              .having((e) => e.kind, 'kind', ApiErrorKind.server),
        ),
      );
      expect(t.adapter.requests.single.path, _prefixedSections);
    });

    test('clamps limit away from the 500-inducing limit=1', () async {
      final t = await _build({_prefixedSections: _Canned(200, _sectionsBody())});

      await t.repo.sections(limit: 1);
      expect(t.adapter.requests.single.uri.queryParameters['limit'], '2');

      await t.repo.sections(limit: 500);
      expect(t.adapter.requests.last.uri.queryParameters['limit'], '20');
    });

    test('a non-map body yields empty sections rather than throwing', () async {
      final t = await _build({
        _prefixedSections: const _Canned(200, <dynamic>[]),
      });
      expect((await t.repo.sections()).isEmpty, isTrue);
    });
  });

  group('filters', () {
    test('sends categories[] so PHP reads it as an array', () async {
      final t = await _build({
        '/ecommerce/filters': const _Canned(200, {
          'error': false,
          'data': {'max_price': 4444, 'current_filter_categories': ['17']},
        }),
      });

      final f = await t.repo.filters(categoryId: 17);

      expect(f.maxPrice, 4444);
      expect(f.currentFilterCategoryIds, [17]);
      // `categories%5B%5D=17` is what PHP needs; a plain `categories=17` would
      // arrive as a scalar and be cast to ['17'] only by luck.
      expect(t.adapter.requests.single.uri.query, 'categories%5B%5D=17');
    });

    test('omits the parameter entirely when unscoped', () async {
      final t = await _build({
        '/ecommerce/filters': const _Canned(200, {
          'error': false,
          'data': <String, dynamic>{},
        }),
      });
      await t.repo.filters();
      expect(t.adapter.requests.single.uri.query, isEmpty);
    });

    test('price ranges are sent in the nested shape the helper reads', () async {
      final t = await _build({
        '/ecommerce/filters': const _Canned(200, {
          'error': false,
          'data': {
            'price_ranges': [
              {'from': '0', 'to': '500'},
            ],
          },
        }),
      });

      final f = await t.repo.filters(
        priceRanges: const [FilterPriceRange(from: 0, to: 500)],
      );

      // dataPriceRangesForFilter() reads request()->query('price_ranges') and
      // drops any entry whose from/to is not is_numeric.
      final q = Uri.decodeFull(t.adapter.requests.single.uri.query);
      expect(q, contains('price_ranges[0][from]=0'));
      expect(q, contains('price_ranges[0][to]=500'));
      // ...and comes back as strings, which must still coerce.
      expect(f.priceRanges.single.to, 500.0);
    });
  });

  group('flashSales', () {
    test('the only observed live response parses to an empty list', () async {
      final t = await _build({
        '/ecommerce/flash-sales':
            const _Canned(200, {'error': false, 'data': [], 'message': null}),
      });
      expect(await t.repo.flashSales(), isEmpty);
      expect(t.adapter.requests.single.uri.query, isEmpty);
    });

    test('ids go out as repeated keys[] entries, not a nested array', () async {
      // The controller validates `keys => array` and `keys.* => string`;
      // `keys[][]=1` would arrive as [["1"]] and 422.
      final t = await _build({
        '/ecommerce/flash-sales':
            const _Canned(200, {'error': false, 'data': []}),
      });

      await t.repo.flashSales(ids: [3, 4]);

      expect(
        t.adapter.requests.single.uri.query,
        'keys%5B%5D=3&keys%5B%5D=4',
      );
    });

    test('liveFlashSales drops expired and empty campaigns', () async {
      final t = await _build({
        '/ecommerce/flash-sales': const _Canned(200, {
          'error': false,
          'data': [
            {
              'id': 1,
              'name': 'Live',
              'end_date': '2030-01-31 23:59:59',
              'expired': false,
              'products': [
                {'id': 118, 'price': 799, 'quantity': 5, 'sold': 0},
              ],
            },
            {
              'id': 2,
              'name': 'Over',
              'end_date': '2020-01-01 00:00:00',
              'expired': true,
              'products': [
                {'id': 119, 'price': 1},
              ],
            },
            {
              'id': 3,
              'name': 'Empty',
              'end_date': '2030-01-31 23:59:59',
              'expired': false,
              'products': <dynamic>[],
            },
          ],
        }),
      });

      expect((await t.repo.flashSales()).map((s) => s.id), [1, 2, 3]);
      expect((await t.repo.liveFlashSales()).map((s) => s.id), [1]);
    });

    test('a 2xx body declaring error:true surfaces as an ApiException',
        () async {
      // FilterController and friends report refusals as HTTP 200 + error:true.
      final t = await _build({
        '/ecommerce/flash-sales': const _Canned(200, {
          'error': true,
          'data': null,
          'message': 'The keys must be an array.',
        }),
      });

      await expectLater(
        t.repo.flashSales(),
        throwsA(
          isA<ApiException>()
              .having((e) => e.kind, 'kind', ApiErrorKind.businessRule)
              .having(
                (e) => e.message,
                'message',
                'The keys must be an array.',
              ),
        ),
      );
    });
  });

  group('brands', () {
    test('parses the hybrid data+links+meta+error envelope', () async {
      final t = await _build({
        '/ecommerce/brands': const _Canned(200, {
          'data': [
            {'id': 8, 'name': 'Trueway Farms', 'slug': 'trueway-farms', 'is_featured': 1},
          ],
          'links': {'first': 'x', 'last': 'x', 'prev': null, 'next': null},
          'meta': {'current_page': 1, 'last_page': 1, 'per_page': 16, 'total': 1},
          'error': false,
          'message': null,
        }),
      });

      final brands = await t.repo.brands();
      expect(brands.single.id, 8);
      expect(brands.single.isFeatured, isTrue);
      expect(t.adapter.requests, hasLength(1));
    });

    test('pages past the hard 16-row ceiling instead of truncating', () async {
      // BrandController ignores ?per_page and always paginates at
      // config('ecommerce.pagination.per_page', 16), so page 1 is not the list.
      Map<String, dynamic> page(int n, int last, List<int> ids) => {
            'data': [
              for (final id in ids) {'id': id, 'name': 'B$id', 'slug': 'b$id'},
            ],
            'meta': {'current_page': n, 'last_page': last, 'per_page': 16},
            'error': false,
          };

      final t = await _build(
        {},
        sequences: {
          '/ecommerce/brands': [
            _Canned(200, page(1, 3, [for (var i = 1; i <= 16; i++) i])),
            _Canned(200, page(2, 3, [for (var i = 17; i <= 32; i++) i])),
            _Canned(200, page(3, 3, [33])),
          ],
        },
      );

      final brands = await t.repo.brands();

      expect(brands, hasLength(33));
      expect(brands.last.id, 33);
      expect(
        t.adapter.requests.map((r) => r.uri.queryParameters['page']),
        ['1', '2', '3'],
      );
    });

    test('stops on the first page when there is no pagination meta', () async {
      final t = await _build({
        '/ecommerce/brands': const _Canned(200, {
          'error': false,
          'data': [
            {'id': 8, 'name': 'Trueway Farms', 'slug': 'trueway-farms'},
          ],
        }),
      });

      expect(await t.repo.brands(), hasLength(1));
      expect(t.adapter.requests, hasLength(1));
    });

    test('a body whose data is not a list does not crash the hard cast',
        () async {
      // PaginatedResponse.fromJson does `json['data'] as List?`, which throws
      // on an object; the repository must not hand it one.
      final t = await _build({
        '/ecommerce/brands': const _Canned(200, {
          'error': false,
          'data': {'id': 8},
        }),
      });

      expect(await t.repo.brands(), isEmpty);
      expect(t.adapter.requests, hasLength(1));
    });
  });
}
