import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/service/image_translation_service.dart';
import 'package:jhentai/src/utils/vertical_translation_layout.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('characters flow downwards, then into a column to the left', () {
    final layout = VerticalTranslationLayout(
      '一二三四五六', fontSize: 16, maxHeight: 55,
    );
    addTearDown(layout.dispose);
    expect(layout.glyphs.map((glyph) => glyph.text).join(), '一二三四五六');
    final first = layout.glyphs.first.bounds;
    expect(layout.glyphs[1].bounds.left, first.left);
    expect(layout.glyphs[1].bounds.top, greaterThan(first.top));
    final nextColumn = layout.glyphs.firstWhere((glyph) => glyph.bounds.left < first.left);
    expect(nextColumn.bounds.top, 0);
    for (final glyph in layout.glyphs) {
      expect(glyph.bounds.left, greaterThanOrEqualTo(-0.001));
      expect(glyph.bounds.right, lessThanOrEqualTo(layout.size.width + 0.001));
      expect(glyph.bounds.bottom, lessThanOrEqualTo(layout.size.height + 0.001));
    }
  });

  test('long translation shrinks to fit without truncation or losing characters', () {
    const text = '不管怎样也比冻僵了要好！还有三天就到截稿日期了！';
    const width = 45.0;
    const height = 100.0;
    final font = fitTranslationFontSize(
      text, width, height, TextDirection.ltr,
      maxFontSize: 20, vertical: true,
    );
    final layout = VerticalTranslationLayout(text, fontSize: font, maxHeight: height);
    addTearDown(layout.dispose);
    expect(font, greaterThan(0));
    expect(font, lessThan(20));
    expect(layout.size.width, lessThanOrEqualTo(width));
    expect(layout.size.height, lessThanOrEqualTo(height));
    expect(layout.glyphs.map((glyph) => glyph.text).join(), text);
  });

  test('OCR soft line breaks do not force fragmented columns', () {
    final continuous = VerticalTranslationLayout('好暖和啊', fontSize: 12, maxHeight: 80);
    final split = VerticalTranslationLayout('好暖\n和啊', fontSize: 12, maxHeight: 80);
    addTearDown(continuous.dispose);
    addTearDown(split.dispose);
    expect(split.size, continuous.size);
    expect(split.glyphs, continuous.glyphs);
  });

  test('grapheme clusters stay intact and punctuation stays inside the layout', () {
    const text = '「好…」👩‍💻';
    final layout = VerticalTranslationLayout(text, fontSize: 12, maxHeight: 80);
    addTearDown(layout.dispose);
    expect(layout.glyphs.length, 5);
    expect(layout.glyphs.last.text, '👩‍💻');
    expect(layout.glyphs.map((glyph) => glyph.text).join(), text);
  });

  test('reader and export fitting scale together', () {
    const text = '暖洋洋的真舒服';
    final original = fitTranslationFontSize(
      text, 80, 200, TextDirection.ltr, maxFontSize: 32, vertical: true,
    );
    final displayed = fitTranslationFontSize(
      text, 40, 100, TextDirection.ltr, maxFontSize: 16, vertical: true,
    );
    expect(displayed, closeTo(original / 2, 0.1));
  });
}
