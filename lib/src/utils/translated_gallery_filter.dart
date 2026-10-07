import '../model/gallery.dart';
import '../model/search_config.dart';

/// Hides Chinese-translated galleries and the raw galleries that already have a Chinese translation,
/// so a search for an artist or uploader only shows works that still need translating.
///
/// A raw gallery and its translation are paired by title: EH translations usually keep the raw title and only
/// append brackets such as `[Chinese] [汉化组]`, so titles are compared with every bracketed part stripped.
/// Translations retitled entirely in Chinese cannot be paired and their raw galleries stay visible.

const String _chineseLanguageTag = 'language:"chinese\$"';

final RegExp _bracketedPart = RegExp(r'\[[^\]]*\]|\([^)]*\)|\{[^}]*\}|【[^】]*】|〔[^〕]*〕');
final RegExp _nonWordChar = RegExp(r'[^\p{L}\p{N}]', unicode: true);
final RegExp _chineseTitleMarker = RegExp(r'中国翻訳|中國翻譯|中国语|中國語|汉化|漢化|\[chinese\]', caseSensitive: false);

/// Search config for the gallery list itself: Chinese galleries are excluded on the server side.
SearchConfig untranslatedSearchConfig(SearchConfig searchConfig) {
  return searchConfig.copyWith()..keyword = '${searchConfig.keyword ?? ''} -$_chineseLanguageTag'.trim();
}

/// Search config listing the Chinese galleries of the same search, with the filters that may differ between a raw
/// gallery and its translation (language, rating, pages, torrents) dropped.
SearchConfig chineseTranslationSearchConfig(SearchConfig searchConfig) {
  return searchConfig.copyWith()
    ..keyword = '${searchConfig.keyword ?? ''} $_chineseLanguageTag'.trim()
    ..language = null
    ..minimumRating = 1
    ..pageAtLeast = null
    ..pageAtMost = null
    ..onlyShowGalleriesWithTorrents = false
    ..onlySearchExpungedGalleries = false
    ..disableFilterForLanguage = true;
}

/// Normalized titles a gallery can be paired by. Dual titles (`日本語 | English`) yield one key per side.
Set<String> galleryTitleMatchKeys(String title) {
  return {title, ...title.split('|')}.map(_normalizeTitle).where((key) => key.length >= 2).toSet();
}

bool isChineseGallery(Gallery gallery) {
  if (gallery.tags['language']?.any((tag) => tag.tagData.key == 'chinese') ?? false) {
    return true;
  }
  if (gallery.language?.toLowerCase() == 'chinese') {
    return true;
  }
  return _chineseTitleMarker.hasMatch(gallery.title);
}

List<Gallery> filterUntranslatedGalleries(List<Gallery> galleries, Set<String> translatedTitleKeys) {
  return galleries
      .where((gallery) => !isChineseGallery(gallery) && !galleryTitleMatchKeys(gallery.title).any(translatedTitleKeys.contains))
      .toList();
}

String _normalizeTitle(String title) {
  return _toHalfWidth(title).replaceAll(_bracketedPart, ' ').toLowerCase().replaceAll(_nonWordChar, '');
}

/// Full-width ASCII (`（Ｃ１０２）`) to half-width, so full-width brackets are stripped like ASCII ones.
String _toHalfWidth(String text) {
  return String.fromCharCodes(text.runes.map((rune) {
    if (rune >= 0xFF01 && rune <= 0xFF5E) {
      return rune - 0xFEE0;
    }
    if (rune == 0x3000) {
      return 0x20;
    }
    return rune;
  }));
}
