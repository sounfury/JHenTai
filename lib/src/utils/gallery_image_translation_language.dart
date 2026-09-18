import 'package:jhentai/src/consts/locale_consts.dart';
import 'package:jhentai/src/model/gallery_tag.dart';
import 'package:jhentai/src/setting/image_translation_setting.dart';

/// Detects whether a gallery is already in (or equivalent to) the current
/// image-translation [ImageTranslationSetting.targetLanguage].
///
/// EH exposes language via `gallery.language` / detail language (often
/// capitalized English names such as `Chinese`) and/or `language:` tags
/// (`language:chinese`, `language:translated`, …). Matching is driven by the
/// user's target language string — not hardcoded to Chinese alone.
class GalleryImageTranslationLanguage {
  const GalleryImageTranslationLanguage._();

  /// Display-name / alias → EH `language:` tag key.
  ///
  /// Keys intentionally include the image-translation setting options, locale
  /// description strings from [LocaleConsts.localeCode2Description], and the
  /// lowercase EH keys from [LocaleConsts.language2Abbreviation].
  static const Map<String, String> targetAliasToEhKey = <String, String>{
    '简体中文': 'chinese',
    '繁體中文': 'chinese',
    '繁體中文(台灣)': 'chinese',
    '中文': 'chinese',
    'chinese': 'chinese',
    'Chinese': 'chinese',
    'English': 'english',
    'english': 'english',
    '日本語': 'japanese',
    'japanese': 'japanese',
    'Japanese': 'japanese',
    '한국어': 'korean',
    'korean': 'korean',
    'Korean': 'korean',
    'Português': 'portuguese',
    'Português brasileiro': 'portuguese',
    'portuguese': 'portuguese',
    'Portuguese': 'portuguese',
    'Русский': 'russian',
    'russian': 'russian',
    'Russian': 'russian',
    'Español': 'spanish',
    'spanish': 'spanish',
    'Spanish': 'spanish',
    'Français': 'french',
    'french': 'french',
    'French': 'french',
    'Italiano': 'italian',
    'italian': 'italian',
    'Italian': 'italian',
    'Deutsch': 'german',
    'german': 'german',
    'German': 'german',
    'ไทย': 'thai',
    'thai': 'thai',
    'Thai': 'thai',
    'Nederlands': 'dutch',
    'dutch': 'dutch',
    'Dutch': 'dutch',
    'Tiếng Việt': 'vietnamese',
    'vietnamese': 'vietnamese',
    'Vietnamese': 'vietnamese',
    'polski': 'polish',
    'polish': 'polish',
    'Polish': 'polish',
    'magyar': 'hungarian',
    'hungarian': 'hungarian',
    'Hungarian': 'hungarian',
  };

  static const Map<String, String> _localeCodeToEhKey = <String, String>{
    'zh_CN': 'chinese',
    'zh_TW': 'chinese',
    'en_US': 'english',
    'pt_BR': 'portuguese',
    'ko_KR': 'korean',
    'ru_RU': 'russian',
  };

  /// EH language keys that mean the gallery is already in [targetLanguage].
  /// Empty when the target cannot be mapped (caller should not skip).
  static Set<String> ehKeysForTargetLanguage(String? targetLanguage) {
    final String raw =
        (targetLanguage ?? imageTranslationSetting.targetLanguage.value).trim();
    if (raw.isEmpty) {
      return const <String>{};
    }

    final String lower = raw.toLowerCase();

    // Already an EH key from LocaleConsts.
    if (LocaleConsts.language2Abbreviation.containsKey(lower)) {
      return <String>{lower};
    }

    final String? alias = targetAliasToEhKey[raw] ?? targetAliasToEhKey[lower];
    if (alias != null) {
      return <String>{alias};
    }

    // Any UI string that clearly denotes Chinese (简体/繁體/中文…).
    if (raw.contains('中文')) {
      return const <String>{'chinese'};
    }

    if (lower.startsWith('portugu')) {
      return const <String>{'portuguese'};
    }

    for (final MapEntry<String, String> entry
        in LocaleConsts.localeCode2Description.entries) {
      if (entry.value == raw || entry.value.toLowerCase() == lower) {
        final String? eh = _localeCodeToEhKey[entry.key];
        if (eh != null) {
          return <String>{eh};
        }
      }
    }

    return const <String>{};
  }

  /// Collects normalized EH language keys present on a gallery.
  ///
  /// Follows the same rule as [EHSpiderParser] metadata parsing: the bare
  /// `translated` tag is not treated as a language by itself. Prefer
  /// `gallery.language` / detail language plus `language:` namespace tags.
  static Set<String> collectGalleryEhLanguageKeys({
    String? language,
    Iterable<String>? languageTagKeys,
    Map<String, List<GalleryTag>>? tags,
    String? tagsCsv,
  }) {
    final Set<String> keys = <String>{};

    void addLanguageToken(String? raw) {
      if (raw == null) {
        return;
      }
      final String token = raw.trim();
      if (token.isEmpty) {
        return;
      }
      final String lower = token.toLowerCase();
      // Bare "translated" is a status flag, not a language (see eh_spider_parser).
      if (lower == 'translated' || lower == 'rewrite' || lower == 'speechless') {
        return;
      }
      if (LocaleConsts.language2Abbreviation.containsKey(lower)) {
        keys.add(lower);
        return;
      }
      final String? alias = targetAliasToEhKey[token] ?? targetAliasToEhKey[lower];
      if (alias != null) {
        keys.add(alias);
        return;
      }
      if (token.contains('中文') || lower.contains('chinese')) {
        keys.add('chinese');
      }
    }

    addLanguageToken(language);

    if (languageTagKeys != null) {
      for (final String key in languageTagKeys) {
        addLanguageToken(key);
      }
    }

    if (tags != null) {
      final List<GalleryTag>? languageTags = tags['language'];
      if (languageTags != null) {
        for (final GalleryTag tag in languageTags) {
          addLanguageToken(tag.tagData.key);
        }
      }
    }

    if (tagsCsv != null && tagsCsv.isNotEmpty) {
      for (final String part in tagsCsv.split(',')) {
        final String item = part.trim();
        if (item.isEmpty) {
          continue;
        }
        final int colon = item.indexOf(':');
        if (colon <= 0) {
          continue;
        }
        final String ns = item.substring(0, colon).trim().toLowerCase();
        final String key = item.substring(colon + 1).trim();
        if (ns == 'language') {
          addLanguageToken(key);
        }
      }
    }

    return keys;
  }

  /// True when the gallery is already in the image-translation target language.
  static bool matchesTarget({
    String? language,
    Iterable<String>? languageTagKeys,
    Map<String, List<GalleryTag>>? tags,
    String? tagsCsv,
    String? targetLanguage,
  }) {
    final Set<String> targetKeys = ehKeysForTargetLanguage(targetLanguage);
    if (targetKeys.isEmpty) {
      return false;
    }
    final Set<String> galleryKeys = collectGalleryEhLanguageKeys(
      language: language,
      languageTagKeys: languageTagKeys,
      tags: tags,
      tagsCsv: tagsCsv,
    );
    return galleryKeys.any(targetKeys.contains);
  }

  /// Convenience: current setting target language.
  static bool matchesCurrentTarget({
    String? language,
    Iterable<String>? languageTagKeys,
    Map<String, List<GalleryTag>>? tags,
    String? tagsCsv,
  }) {
    return matchesTarget(
      language: language,
      languageTagKeys: languageTagKeys,
      tags: tags,
      tagsCsv: tagsCsv,
      targetLanguage: imageTranslationSetting.targetLanguage.value,
    );
  }
}
