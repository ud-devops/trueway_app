import '../../core/config/app_config.dart';
import '../../core/utils/json_utils.dart';

class AdBanner {
  const AdBanner({
    required this.key,
    required this.name,
    required this.image,
    required this.order,
    this.subtitle,
    this.buttonText,
    this.link,
    this.openInNewTab = false,
  });

  final String key;
  final String name;
  final String image;
  final int order;
  final String? subtitle;
  final String? buttonText;
  final String? link;
  final bool openInNewTab;

  factory AdBanner.fromJson(Map<String, dynamic> j) => AdBanner(
        key: asString(j['key']),
        name: asString(j['name']),
        image: AppConfig.resolveImage(asString(j['mobile_image'] ?? j['image'])),
        order: asInt(j['order']),
        subtitle: asStringOrNull(j['subtitle']),
        buttonText: asStringOrNull(j['button_text']),
        link: asStringOrNull(j['link']),
        openInNewTab: asBool(j['open_in_new_tab']),
      );
}
