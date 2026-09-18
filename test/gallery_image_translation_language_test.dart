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
}
