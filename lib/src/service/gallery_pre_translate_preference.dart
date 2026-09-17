import '../enum/config_enum.dart';
import 'local_config_service.dart';

/// Per-gallery on/off for pre-translating the first N pages. Default is off;
/// the detail page is the intended place to enable it for a specific gallery.
class GalleryPreTranslatePreference {
  const GalleryPreTranslatePreference._();

  static Future<bool> isEnabled(int gid) async {
    final String? value = await localConfigService.read(
      configKey: ConfigEnum.galleryPreTranslate,
      subConfigKey: gid.toString(),
    );
    return value == '1';
  }

  static Future<void> setEnabled(int gid, bool enabled) async {
    await localConfigService.write(
      configKey: ConfigEnum.galleryPreTranslate,
      subConfigKey: gid.toString(),
      value: enabled ? '1' : '0',
    );
  }
}
