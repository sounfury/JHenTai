import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/service/image_translation/onomatopoeia_filter.dart';

void main() {
  test('sound effects are detected', () {
    for (final String sfx in <String>[
      'ドキドキ', 'ズン', 'バッ', 'どきどき', 'あっ', 'んんっ♡', 'ーーッ！！', 'ぱんぱん', 'ビクッ',
      'わあぁ♥', 'わああ', 'わああv', 'わぁぁ', 'ひいい', 'はぁはぁ',
    ]) {
      expect(isOnomatopoeia(sfx), isTrue, reason: sfx);
    }
  });

  test('short kana outside every bubble is treated as a sound effect', () {
    for (final String sfx in <String>['ひゃあん', 'くちゅ', 'ちゅぱ', 'わあ']) {
      expect(isOnomatopoeia(sfx, insideBubble: false), isTrue, reason: sfx);
    }
  });

  test('only effects confirmed outside bubbles are preserved', () {
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
        isFalse,
        reason: effect,
      );
    }
    expect(
      shouldPreserveSoundEffect('大丈夫です', insideBubble: false),
      isFalse,
    );
  });

  test('dialogue is kept', () {
    for (final String line in <String>['はい', 'どうしたの？', '大丈夫です', 'やめてください', '好き', 'Hello', 'ちょっと', 'じゃない']) {
      expect(isOnomatopoeia(line), isFalse, reason: line);
      expect(isOnomatopoeia(line, insideBubble: true), isFalse, reason: line);
    }
    // Longer or kanji-bearing text outside bubbles (narration) still translates.
    expect(isOnomatopoeia('そのころ学校では', insideBubble: false), isFalse);
    expect(isOnomatopoeia('どうしてそんなことをいうの', insideBubble: false), isFalse);
  });
}
