import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:jhentai/src/model/image_translation.dart';
import 'package:jhentai/src/utils/connected_bubble_layout.dart';
import 'package:jhentai/src/utils/image_text_grouping.dart';
import 'package:jhentai/src/utils/image_translation_typography.dart';
import 'package:jhentai/src/utils/vertical_translation_layout.dart';
import 'package:jhentai/src/utils/ocr_layout_protocol.dart';
import 'package:jhentai/src/utils/sound_effect_style.dart';
import 'package:jhentai/src/utils/rgba_raster.dart';
import 'package:jhentai/src/service/image_translation/onomatopoeia_filter.dart';
import 'package:jhentai/src/model/bubble_interior_mask.dart';
import 'package:jhentai/src/service/engine/engine_contract.dart';
import 'package:jhentai/src/service/image_translation_service.dart'
    show containersFromBubbleDetection;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'real model masks use four areas even when transparent lobes are missing',
    () {
      final raw =
          jsonDecode(
                File(
                  'test/fixtures/translation_layout/connected_dialogue_ocr.json',
                ).readAsStringSync(),
              )
              as List;
      final blocks = sortRecognizedTextBlocks(
        raw
            .map(
              (b) => RecognizedTextBlock.fromJson(Map<String, dynamic>.from(b)),
            )
            .where((b) => b.text != 'ドキ' && b.text != '1')
            .toList(),
      );
      final masks =
          jsonDecode(
                File(
                  'test/fixtures/translation_layout/connected_dialogue_masks.json',
                ).readAsStringSync(),
              )
              as List;
      final regions =
          masks.map((r) {
            final box =
                (r['box'] as List).map((v) => (v as num).toDouble()).toList();
            return DetectedTextRegion(
              left: box[0],
              top: box[1],
              width: box[2],
              height: box[3],
              confidence: (r['confidence'] as num).toDouble(),
              bubbleInterior: BubbleInteriorMask(
                bounds: ui.Rect.fromLTWH(box[0], box[1], box[2], box[3]),
                width: r['maskWidth'] as int,
                height: r['maskHeight'] as int,
                pixels: base64Decode(r['maskPixels'] as String),
              ),
            );
          }).toList();
      final containers = containersFromBubbleDetection(
        blocks,
        DetectionResult(regions: regions),
        imageWidth: 1670,
        imageHeight: 658,
      );
      final groups = translationTextGroups(blocks, containers: containers);
      expect(groups, hasLength(3));
      expect(groups.expand((g) => g.blockIndices).length, 12);
      final counts =
          groups.map((g) {
            final areas = layoutRegionsForRecognizedTextGroup(
              g,
              containers,
              blocks: blocks,
            );
            return areas.isEmpty ? 1 : areas.length;
          }).toList();
      expect(counts, [1, 2, 1]);
      final middle = layoutRegionsForRecognizedTextGroup(
        groups[1],
        containers,
        blocks: blocks,
      );
      expect(middle.first.top, lessThan(110));
      expect(middle.last.top + middle.last.height, greaterThan(500));
    },
  );
  test(
    'real OCR keeps column order and does not translate the pink digit ghost',
    () {
      final raw =
          jsonDecode(
                File(
                  'test/fixtures/translation_layout/connected_dialogue_ocr.json',
                ).readAsStringSync(),
              )
              as List;
      final blocks = sortRecognizedTextBlocks(
        raw
            .map(
              (b) => RecognizedTextBlock.fromJson(Map<String, dynamic>.from(b)),
            )
            .toList(),
      );
      final text = blocks.map((b) => b.text).toList();
      expect(text.indexOf('明日の保健は'), lessThan(text.indexOf('久しぶりに性教育…し')));
      expect(text.indexOf('ペアの佐々木くん'), lessThan(text.indexOf('こういうのは')));
      expect(text.indexOf('こういうのは'), lessThan(text.indexOf('嫌いじゃないかな')));
      expect(text.indexOf('って'), lessThan(text.indexOf('ただの授業なのに')));
      final source =
          RgbaRaster.decode(
            File(
              'test/fixtures/translation_layout/connected_dialogue_original.png',
            ).readAsBytesSync(),
          )!;
      final styled = styleMatchedSoundEffects(source, blocks, []);
      expect(styled.map((i) => blocks[i].text), ['1']);
      final ghost = blocks[text.indexOf('1')];
      expect(
        shouldPreserveSoundEffect(
          ghost.text,
          insideBubble: false,
          confidence: ghost.confidence,
          matchesSoundEffectStyle: true,
        ),
        isTrue,
      );
      expect(shouldPreserveSoundEffect('って', insideBubble: false), isFalse);
      expect(shouldPreserveSoundEffect('から…', insideBubble: false), isFalse);
      final withoutAnchor = blocks.where((b) => b.text != 'ドキ').toList();
      expect(styleMatchedSoundEffects(source, withoutAnchor, []), isEmpty);
    },
  );
  test('shaded connected dialogue keeps all three source lobes', () async {
    final bytes =
        File(
          'test/fixtures/translation_layout/connected_dialogue_original.png',
        ).readAsBytesSync();
    final source = image.decodePng(bytes)!;
    // Manually annotated columns in the supplied screenshot, not OCR output.
    final blocks = <RecognizedTextBlock>[
      for (final x in [670.0, 620.0, 570.0])
        RecognizedTextBlock(
          text: '縦書きの文章です',
          confidence: 1,
          left: x,
          top: 110,
          width: 36,
          height: 290,
        ),
      for (final x in [520.0, 470.0, 420.0])
        RecognizedTextBlock(
          text: '縦書きの文章です',
          confidence: 1,
          left: x,
          top: 205,
          width: 36,
          height: x == 520 ? 300 : 225,
        ),
      for (final x in [335.0, 285.0, 235.0, 185.0])
        RecognizedTextBlock(
          text: '縦書きの文章です',
          confidence: 1,
          left: x,
          top: 285,
          width: 36,
          height:
              x == 335
                  ? 75
                  : x == 185
                  ? 180
                  : 295,
        ),
    ];
    final indices = List.generate(blocks.length, (i) => i);
    final container = RecognizedTextContainer(
      blockIndices: indices,
      left: 143,
      top: 53,
      width: 612,
      height: 583,
    );
    final detected = detectBubbleLayoutRegions(source, container);
    final group = RecognizedTextGroup(
      blockIndices: indices,
      left: 143,
      top: 53,
      right: 755,
      bottom: 636,
    );
    final refined = RecognizedTextContainer.fromJson({
      ...container.toJson(),
      'layoutRegions': detected.map((r) => r.toJson()).toList(),
    });
    final regions = layoutRegionsForRecognizedTextGroup(group, [
      refined,
    ], blocks: blocks);
    expect(regions, hasLength(3));
    expect(regions.last.left, lessThan(200));
    expect(regions.first.top, 110);
    expect(
      layoutRegionsForRecognizedTextGroup(group, [], blocks: blocks),
      hasLength(3),
    );
    const text = '搭档佐佐木同学应该不讨厌这种事吧。上次讲到性感话题时他还有反应呢……明明只是普通的课，我到底在期待什么啊。';
    final entries = layoutTranslationInRegions(
      text,
      [
        for (final r in regions)
          Rect.fromLTWH(r.left, r.top, r.width, r.height),
      ],
      TextDirection.ltr,
      maxFontSize: 32,
      vertical: true,
    );
    expect(entries.map((e) => e.$2).join(), text);
    for (final (rect, chunk, font) in entries) {
      final layout = VerticalTranslationLayout(
        chunk,
        fontSize: font,
        maxHeight: rect.height - 4,
      );
      expect(layout.size.width, lessThanOrEqualTo(rect.width - 4));
      expect(layout.size.height, lessThanOrEqualTo(rect.height - 4));
      layout.dispose();
    }
  });
}
