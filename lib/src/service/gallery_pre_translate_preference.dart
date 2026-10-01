import 'dart:convert';

import '../enum/config_enum.dart';
import '../setting/image_translation_setting.dart';
import 'local_config_service.dart';

class GalleryPreTranslateOptions {
  const GalleryPreTranslateOptions({
    required this.pageCount,
    required this.concurrency,
  });

  final int pageCount;
  final int concurrency;
}

/// Per-gallery on/off for pre-translating the first N pages. Default is off;
/// the detail page is the intended place to enable it for a specific gallery.
class GalleryPreTranslatePreference {
  const GalleryPreTranslatePreference._();

  static Future<GalleryPreTranslateOptions> optionsFor(int gid) async {
    final String? value = await localConfigService.read(
      configKey: ConfigEnum.galleryPreTranslate,
      subConfigKey: '$gid:options',
    );
    Map<String, dynamic> options = {};
    if (value != null) {
      try {
        final Object? decoded = jsonDecode(value);
        if (decoded is Map<String, dynamic>) {
          options = decoded;
        }
      } on FormatException {
        // Fall back to global defaults for an invalid saved configuration.
      }
    }
    final Object? pageCount = options['pageCount'];
    final Object? concurrency = options['concurrency'];
    return GalleryPreTranslateOptions(
      pageCount:
          pageCount is int && pageCount > 0
              ? pageCount
              : imageTranslationSetting.preTranslatePageCount.value,
      concurrency:
          concurrency is int
              ? concurrency.clamp(1, 20)
              : imageTranslationSetting.preTranslateConcurrency.value,
    );
  }

  static Future<void> saveOptions(
    int gid,
    GalleryPreTranslateOptions options,
  ) async {
    await localConfigService.write(
      configKey: ConfigEnum.galleryPreTranslate,
      subConfigKey: '$gid:options',
      value: jsonEncode({
        'pageCount': options.pageCount < 1 ? 1 : options.pageCount,
        'concurrency': options.concurrency.clamp(1, 20),
      }),
    );
  }

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
