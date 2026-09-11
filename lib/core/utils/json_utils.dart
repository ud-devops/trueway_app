/// Defensive JSON coercion helpers — the backend mixes strings/numbers/nulls
/// (e.g. `price: 921.501`, `is_featured: 1`, `quantity: "0"`), so never trust a
/// raw cast.
int asInt(dynamic v, [int def = 0]) {
  if (v is int) return v;
  if (v is double) return v.round();
  if (v is String) return int.tryParse(v) ?? double.tryParse(v)?.round() ?? def;
  return def;
}

double asDouble(dynamic v, [double def = 0]) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v) ?? def;
  return def;
}

/// A money field that is **absent** rather than zero.
///
/// [asDouble]'s `0` default cannot tell "the server sent 0.00" from "the server
/// does not serialize this key at all", and for money those mean opposite
/// things: one is a fee of nothing, the other is a term the client must not
/// pretend to know. `payment_fee` was missing from both order resources while
/// really being ₹10.00 on three orders — reading it as 0 is exactly how a bill
/// comes to disagree with its own total.
///
/// Returns null for a null, a missing key, an empty string, or an unparseable
/// value.
double? asDoubleOrNull(dynamic v) {
  if (v is num) return v.toDouble();
  if (v is String) return v.trim().isEmpty ? null : double.tryParse(v);
  return null;
}

String asString(dynamic v, [String def = '']) {
  if (v == null) return def;
  if (v is String) return v;
  return v.toString();
}

String? asStringOrNull(dynamic v) {
  if (v == null) return null;
  final s = v is String ? v : v.toString();
  return s.isEmpty ? null : s;
}

bool asBool(dynamic v, [bool def = false]) {
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) {
    final s = v.toLowerCase();
    return s == '1' || s == 'true' || s == 'yes';
  }
  return def;
}

List<String> asStringList(dynamic v) {
  if (v is List) {
    return v.where((e) => e != null).map((e) => e.toString()).toList();
  }
  return const [];
}

List<Map<String, dynamic>> asMapList(dynamic v) {
  if (v is List) {
    return v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  }
  return const [];
}

Map<String, dynamic> asMap(dynamic v) {
  if (v is Map) return Map<String, dynamic>.from(v);
  return const {};
}
