import '../../core/utils/json_utils.dart';

class Brand {
  const Brand({
    required this.id,
    required this.name,
    required this.slug,
    required this.isFeatured,
    this.website,
    this.description,
    this.logo,
  });

  final int id;
  final String name;
  final String slug;
  final bool isFeatured;
  final String? website;
  final String? description;
  final String? logo;

  factory Brand.fromJson(Map<String, dynamic> j) {
    final sizes = asMap(j['logo_with_sizes']);
    return Brand(
      id: asInt(j['id']),
      name: asString(j['name']),
      slug: asString(j['slug']),
      isFeatured: asBool(j['is_featured']),
      website: asStringOrNull(j['website']),
      description: asStringOrNull(j['description']),
      logo: asStringOrNull(sizes['thumb'] ?? sizes['origin'] ?? j['logo']),
    );
  }
}
