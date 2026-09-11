/// Helpers for the two envelope shapes the backend returns:
///   1. `{ "error": false, "data": [...] }`                (sliders, ads, brands)
///   2. `{ "data": [...], "links": {...}, "meta": {...} }`  (paginated products)
typedef JsonMap = Map<String, dynamic>;
typedef FromJson<T> = T Function(JsonMap json);

/// Unwrap the `data` field from a simple envelope and map a list.
List<T> unwrapList<T>(dynamic body, FromJson<T> fromJson) {
  final data = (body is Map) ? body['data'] : body;
  if (data is List) {
    return data.whereType<JsonMap>().map(fromJson).toList();
  }
  return const [];
}

/// Unwrap a single object from `{ data: {...} }` or a bare object.
T? unwrapObject<T>(dynamic body, FromJson<T> fromJson) {
  final data = (body is Map && body.containsKey('data')) ? body['data'] : body;
  return (data is Map) ? fromJson(Map<String, dynamic>.from(data)) : null;
}

class PaginatedResponse<T> {
  const PaginatedResponse({
    required this.items,
    required this.meta,
    this.links,
  });

  final List<T> items;
  final PaginationMeta meta;
  final PaginationLinks? links;

  bool get hasMore => meta.currentPage < meta.lastPage;
  int get nextPage => meta.currentPage + 1;

  factory PaginatedResponse.fromJson(JsonMap json, FromJson<T> fromJson) {
    final rawList = (json['data'] as List?) ?? const [];
    return PaginatedResponse<T>(
      items: rawList.whereType<JsonMap>().map(fromJson).toList(),
      meta: PaginationMeta.fromJson(
        (json['meta'] as JsonMap?) ?? const {},
        fallbackCount: rawList.length,
      ),
      links: json['links'] is Map
          ? PaginationLinks.fromJson(json['links'] as JsonMap)
          : null,
    );
  }
}

class PaginationMeta {
  const PaginationMeta({
    required this.currentPage,
    required this.lastPage,
    required this.perPage,
    required this.total,
    this.from,
    this.to,
  });

  final int currentPage;
  final int lastPage;
  final int perPage;
  final int total;
  final int? from;
  final int? to;

  factory PaginationMeta.fromJson(JsonMap json, {int fallbackCount = 0}) {
    int asInt(dynamic v, int d) =>
        v is int ? v : int.tryParse('${v ?? ''}') ?? d;
    return PaginationMeta(
      currentPage: asInt(json['current_page'], 1),
      lastPage: asInt(json['last_page'], 1),
      perPage: asInt(json['per_page'], fallbackCount),
      total: asInt(json['total'], fallbackCount),
      from: json['from'] == null ? null : asInt(json['from'], 0),
      to: json['to'] == null ? null : asInt(json['to'], 0),
    );
  }

  static PaginationMeta single(int count) => PaginationMeta(
        currentPage: 1,
        lastPage: 1,
        perPage: count,
        total: count,
        from: count == 0 ? null : 1,
        to: count == 0 ? null : count,
      );
}

class PaginationLinks {
  const PaginationLinks({this.first, this.last, this.prev, this.next});

  final String? first;
  final String? last;
  final String? prev;
  final String? next;

  factory PaginationLinks.fromJson(JsonMap json) => PaginationLinks(
        first: json['first'] as String?,
        last: json['last'] as String?,
        prev: json['prev'] as String?,
        next: json['next'] as String?,
      );
}
