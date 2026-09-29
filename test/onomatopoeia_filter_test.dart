import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/service/image_translation/onomatopoeia_filter.dart';

void main() {
  test('sound effects are detected', () {
    for (final String sfx in <String>[
      'ドキドキ',
      'ズン',
      'バッ',
      'どきどき',
      'あっ',
      'んんっ♡',
      'ーーッ！！',
      'ぱんぱん',
      'ビクッ',
      'わあぁ♥',
      'わああ',
      'わああv',
      'わぁぁ',
      'ひいい',
      'はぁはぁ',
    ]) {
      expect(isOnomatopoeia(sfx), isTrue, reason: sfx);
    }
  });

  test('short kana outside every bubble is treated as a sound effect', () {
    for (final String sfx in <String>['ひゃあん', 'くちゅ', 'ちゅぱ', 'わあ']) {
      expect(isOnomatopoeia(sfx, insideBubble: false), isTrue, reason: sfx);
    }
  });

  test('bubble evidence takes precedence over the text-only fallback', () {
    for (final String effect in <String>['ドキドキ', 'ああ!!', 'ーーッ！！']) {
      expect(
        shouldPreserveSoundEffect(effect, insideBubble: false),
        isTrue,
        reason: effect,
      );
      expect(
        shouldPreserveSoundEffect(effect, insideBubble: true),
        isFalse,
        reason: effect,
      );
      expect(
        shouldPreserveSoundEffect(effect, insideBubble: null),
        effect == 'ドキドキ' ? isTrue : isFalse,
        reason: effect,
      );
    }
    expect(shouldPreserveSoundEffect('大丈夫です', insideBubble: false), isFalse);
  });

  test('recognizable artwork effects survive unavailable bubble detection', () {
    for (final text in ['ドキ', 'ド\nキ', 'ドキッ', 'ソワ', 'ソワソワ']) {
      expect(shouldPreserveSoundEffect(text, insideBubble: null), isTrue);
      expect(shouldPreserveSoundEffect(text, insideBubble: true), isFalse);
    }
    for (final text in ['はい', 'あっ', 'ああ!!', '彼はドキドキしている', 'ドア', 'ソファ']) {
      expect(shouldPreserveSoundEffect(text, insideBubble: null), isFalse);
    }
  });

  test(
    'low-confidence vertical OCR errors outside bubbles stay in artwork',
    () {
      for (final String effect in <String>['4チ', 'VH']) {
        expect(
          shouldPreserveSoundEffect(
            effect,
            insideBubble: false,
            confidence: effect == 'VH' ? 0.59 : 0.76,
            width: effect == 'VH' ? 150 : 97,
            height: effect == 'VH' ? 241 : 282,
          ),
          isTrue,
          reason: effect,
        );
        expect(
          shouldPreserveSoundEffect(
            effect,
            insideBubble: true,
            confidence: 0.5,
            width: 100,
            height: 200,
          ),
          isFalse,
        );
      }
      expect(
        shouldPreserveSoundEffect(
          'OK',
          insideBubble: false,
          confidence: 0.6,
          width: 100,
          height: 30,
        ),
        isFalse,
      );
      expect(
        shouldPreserveSoundEffect(
          'VH',
          insideBubble: false,
          confidence: 0.95,
          width: 40,
          height: 80,
        ),
        isFalse,
      );
    },
  );

  test('dialogue is kept', () {
    for (final String line in <String>[
      'はい',
      'どうしたの？',
      '大丈夫です',
      'やめてください',
      '好き',
      'Hello',
      'ちょっと',
      'じゃない',
    ]) {
      expect(isOnomatopoeia(line), isFalse, reason: line);
      expect(isOnomatopoeia(line, insideBubble: true), isFalse, reason: line);
    }
    // Longer or kanji-bearing text outside bubbles (narration) still translates.
    expect(isOnomatopoeia('そのころ学校では', insideBubble: false), isFalse);
    expect(isOnomatopoeia('どうしてそんなことをいうの', insideBubble: false), isFalse);
  });
}
