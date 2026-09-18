import 'dart:collection';

import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/model/gallery_tag.dart';
import 'package:jhentai/src/utils/gallery_image_translation_language.dart';

void main() {
  group('ehKeysForTargetLanguage', () {
    test('maps Chinese targets to chinese', () {
      expect(
        GalleryImageTranslationLanguage.ehKeysForTargetLanguage('简体中文'),
        {'chinese'},
      );
      expect(
        GalleryImageTranslationLanguage.ehKeysForTargetLanguage('繁體中文'),
        {'chinese'},
      );
      expect(
        GalleryImageTranslationLanguage.ehKeysForTargetLanguage('某中文别名'),
        {'chinese'},
      );
    });

    test('maps English / Japanese / Korean / Portuguese / Russian', () {
      expect(
        GalleryImageTranslationLanguage.ehKeysForTargetLanguage('English'),
        {'english'},
      );
      expect(
        GalleryImageTranslationLanguage.ehKeysForTargetLanguage('日本語'),
        {'japanese'},
      );
      expect(
        GalleryImageTranslationLanguage.ehKeysForTargetLanguage('한국어'),
        {'korean'},
      );
      expect(
        GalleryImageTranslationLanguage.ehKeysForTargetLanguage('Português'),
        {'portuguese'},
      );
      expect(
        GalleryImageTranslationLanguage.ehKeysForTargetLanguage('Русский'),
        {'russian'},
      );
    });

    test('accepts raw EH keys', () {
      expect(
        GalleryImageTranslationLanguage.ehKeysForTargetLanguage('chinese'),
        {'chinese'},
      );
      expect(
        GalleryImageTranslationLanguage.ehKeysForTargetLanguage('Japanese'),
        {'japanese'},
      );
    });
  });

  group('matchesTarget', () {
    test('Chinese 熟肉 via language field', () {
      expect(
        GalleryImageTranslationLanguage.matchesTarget(
          language: 'Chinese',
          targetLanguage: '简体中文',
        ),
        isTrue,
      );
    });

    test('Chinese 熟肉 via language:chinese + translated tags', () {
      final tags = LinkedHashMap<String, List<GalleryTag>>.of({
        'language': [
          GalleryTag(tagData: TagData(namespace: 'language', key: 'translated')),
          GalleryTag(tagData: TagData(namespace: 'language', key: 'chinese')),
        ],
      });
      expect(
        GalleryImageTranslationLanguage.matchesTarget(
          tags: tags,
          targetLanguage: '繁體中文',
        ),
        isTrue,
      );
    });

    test('bare translated alone does not match', () {
      expect(
        GalleryImageTranslationLanguage.matchesTarget(
          language: 'translated',
          tagsCsv: 'language:translated',
          targetLanguage: '简体中文',
        ),
        isFalse,
      );
    });

    test('English gallery skipped only for English target', () {
      expect(
        GalleryImageTranslationLanguage.matchesTarget(
          language: 'english',
          tagsCsv: 'language:english',
          targetLanguage: 'English',
        ),
        isTrue,
      );
      expect(
        GalleryImageTranslationLanguage.matchesTarget(
          language: 'english',
          tagsCsv: 'language:english',
          targetLanguage: '简体中文',
        ),
        isFalse,
      );
    });

    test('Japanese gallery matches 日本語 target', () {
      expect(
        GalleryImageTranslationLanguage.matchesTarget(
          language: 'Japanese',
          targetLanguage: '日本語',
        ),
        isTrue,
      );
    });

    test('tagsCsv language:chinese matches', () {
      expect(
        GalleryImageTranslationLanguage.matchesTarget(
          tagsCsv: 'female:lolicon,language:chinese,language:translated',
          targetLanguage: '简体中文',
        ),
        isTrue,
      );
    });
  });

  group('collectGalleryEhLanguageKeys hardening', () {
    test('bare CSV keys without language: prefix still map', () {
      expect(
        GalleryImageTranslationLanguage.collectGalleryEhLanguageKeys(
          tagsCsv: 'chinese,translated,female:lolicon',
        ),
        contains('chinese'),
      );
      expect(
        GalleryImageTranslationLanguage.matchesTarget(
          tagsCsv: 'chinese,translated',
          targetLanguage: '简体中文',
        ),
        isTrue,
      );
    });

    test('language field Chinese / ZH / 中文 map to chinese', () {
      expect(
        GalleryImageTranslationLanguage.collectGalleryEhLanguageKeys(
          language: 'Chinese',
        ),
        {'chinese'},
      );
      expect(
        GalleryImageTranslationLanguage.collectGalleryEhLanguageKeys(
          language: 'ZH',
        ),
        {'chinese'},
      );
      expect(
        GalleryImageTranslationLanguage.collectGalleryEhLanguageKeys(
          language: '中文',
        ),
        {'chinese'},
      );
    });
  });

  group('same-language skip vs target', () {
    test('target 简体中文 + gallery chinese → skip true', () {
      expect(
        GalleryImageTranslationLanguage.matchesTarget(
          language: 'chinese',
          tagsCsv: 'language:chinese',
          targetLanguage: '简体中文',
        ),
        isTrue,
      );
    });

    test('target English + chinese gallery → skip false', () {
      expect(
        GalleryImageTranslationLanguage.matchesTarget(
          language: 'chinese',
          tagsCsv: 'language:chinese',
          targetLanguage: 'English',
        ),
        isFalse,
      );
    });
  });
}
