import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/model/bubble_interior_mask.dart';
import 'package:jhentai/src/model/image_translation.dart';
import 'package:jhentai/src/service/engine/engine_contract.dart';
import 'package:jhentai/src/service/engine/translation_protocol.dart';
import 'package:jhentai/src/service/image_translation/onomatopoeia_filter.dart';
import 'package:jhentai/src/service/image_translation_service.dart'
    show isBlockInsideAnyRegion;
import 'package:jhentai/src/utils/rgba_raster.dart';
import 'package:jhentai/src/utils/sound_effect_style.dart';

const _root = 'test/acceptance/image_translation/outlined_sound_effects';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final annotation = jsonDecode(File('$_root/case.json').readAsStringSync());
  for (final sample in annotation['cases'] as List) {
    final snapshot = jsonDecode(
      File('$_root/${sample['snapshot']}').readAsStringSync(),
    );
    final bytes = File('$_root/${sample['source']}').readAsBytesSync();
    final page = RgbaRaster.decode(bytes)!;
    final blocks =
        (snapshot['allOcrBlocks'] as List)
            .map(
              (b) => RecognizedTextBlock.fromJson(Map<String, dynamic>.from(b)),
            )
            .toList();
    final regions =
        (snapshot['regions'] as List).map((r) {
          final box = (r['box'] as List).cast<num>();
          final bounds = Rect.fromLTWH(
            box[0].toDouble(),
            box[1].toDouble(),
            box[2].toDouble(),
            box[3].toDouble(),
          );
          return DetectedTextRegion(
            left: bounds.left,
            top: bounds.top,
            width: bounds.width,
            height: bounds.height,
            confidence: (r['confidence'] as num).toDouble(),
            bubbleInterior:
                r['maskPixels'] == null
                    ? null
                    : BubbleInteriorMask(
                      bounds: bounds,
                      width: r['maskWidth'],
                      height: r['maskHeight'],
                      pixels: base64Decode(r['maskPixels']),
                    ),
          );
        }).toList();

    test('${sample['id']}：真实页面的误识别拟声词不进入翻译，对白完整保留', () {
      expect(sha256.convert(bytes).toString(), sample['sourceSha256']);
      final outlines = outlinedArtworkSoundEffects(page, blocks, regions);
      final styles = styleMatchedSoundEffects(page, blocks, regions);
      final retained = <RecognizedTextBlock>[];
      for (int i = 0; i < blocks.length; i++) {
        final block = blocks[i];
        if (!shouldPreserveSoundEffect(
          block.text,
          insideBubble: isBlockInsideAnyRegion(block, regions),
          confidence: block.confidence,
          width: block.width,
          height: block.height,
          matchesSoundEffectStyle: styles.contains(i),
          matchesSoundEffectOutline: outlines.contains(i),
        )) {
          retained.add(block);
        }
      }
      final prompt = buildTranslationPrompt(
        TranslationEngineRequest(
          blocks: retained,
          targetLanguage: '简体中文',
          mergeTextBlocks: false,
        ),
      );
      for (final text in sample['preserve'] as List) {
        final index = blocks.indexWhere((b) => b.text == text);
        expect(index, greaterThanOrEqualTo(0));
        expect(outlines, contains(index), reason: text);
        expect(retained.map((b) => b.text), isNot(contains(text)));
        expect(
          prompt.groups.map((g) => g.textOf(retained)),
          isNot(contains(text)),
        );
        // 位置未知时，单凭误识别文本仍不能保留，必须提供原图视觉证据。
        expect(
          shouldPreserveSoundEffect(
            text,
            insideBubble: null,
            confidence: blocks[index].confidence,
            width: blocks[index].width,
            height: blocks[index].height,
            matchesSoundEffectStyle: styles.contains(index),
          ),
          isFalse,
        );
      }
      for (final text in sample['translate'] as List) {
        expect(retained.map((b) => b.text), contains(text), reason: text);
        expect(prompt.prompt, contains(text));
      }
      final output = Directory('.dart_tool/acceptance/outlined_sound_effects')
        ..createSync(recursive: true);
      File('${output.path}/${sample['id']}.decisions.json').writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
          'preserved': [
            for (int i = 0; i < blocks.length; i++)
              if (!retained.contains(blocks[i])) blocks[i].text,
          ],
          'translated': retained.map((b) => b.text).toList(),
        }),
      );
    });

    test('${sample['id']}：气泡优先，缺失检测时需原图描边证据', () {
      final outlines = outlinedArtworkSoundEffects(page, blocks, null);
      for (final text in sample['preserve'] as List) {
        final index = blocks.indexWhere((b) => b.text == text);
        expect(outlines, contains(index));
        expect(
          shouldPreserveSoundEffect(
            text,
            insideBubble: null,
            matchesSoundEffectOutline: outlines.contains(index),
          ),
          isTrue,
        );
        expect(
          shouldPreserveSoundEffect(
            text,
            insideBubble: true,
            matchesSoundEffectOutline: true,
          ),
          isFalse,
        );
      }
      final wholePageBalloon = [
        DetectedTextRegion(
          left: 0,
          top: 0,
          width: page.width.toDouble(),
          height: page.height.toDouble(),
          confidence: 1,
        ),
      ];
      expect(
        outlinedArtworkSoundEffects(page, blocks, wholePageBalloon),
        isEmpty,
      );
      for (final colour in [
        <int>[180, 180, 180, 255],
        <int>[245, 90, 180, 255],
      ]) {
        final pixels = Uint8List(page.pixels.length);
        for (int i = 0; i < pixels.length; i += 4) {
          pixels.setRange(i, i + 4, colour);
        }
        expect(
          outlinedArtworkSoundEffects(
            RgbaRaster(page.width, page.height, pixels),
            blocks,
            null,
          ),
          isEmpty,
          reason: '仅颜色、尺寸和低置信度不足以判定拟声词',
        );
      }
    });
  }
}
