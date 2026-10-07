// 用真实漫画字形验收字色、白描边、旧缓存补采样及阅读与导出的样式一致性。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:jhentai/src/model/image_translation.dart';
import 'package:jhentai/src/service/image_translation_service.dart';
import 'package:jhentai/src/service/path_service.dart';
import 'package:jhentai/src/setting/image_translation_setting.dart';
import 'package:jhentai/src/utils/image_translation_colors.dart';
import 'package:jhentai/src/utils/image_translation_renderer.dart';

const _fixtures = 'test/acceptance/image_translation';

void main() {
  final annotation = jsonDecode(
    File('$_fixtures/colored_horizontal_text/case.json').readAsStringSync(),
  );
  final original =
      img.decodeImage(
        File('$_fixtures/colored_horizontal_text/source.png').readAsBytesSync(),
      )!;
  final source = img.copyCrop(
    original,
    x: 1070,
    y: 140,
    width: 200,
    height: 400,
  );
  final blocks =
      (annotation['translatedBlocks'] as List)
          .sublist(1, 9)
          .map(
            (json) => RecognizedTextBlock.fromJson({
              ...json as Map<String, dynamic>,
              'left': (json['left'] as num) - 1070,
              'top': (json['top'] as num) - 140,
            }),
          )
          .toList();

  test('真实粉字白描边及派生红蓝字正确采样，旧缓存保存后不再重复采样', () {
    for (final color in [
      null,
      [200, 30, 80],
      [30, 90, 220],
    ]) {
      final page = _recolor(source, color);
      final detected = _sample(page, blocks);
      print(
        '源颜色 $color: ${detected.map((b) => '${b.textColor?.toRadixString(16)}/${b.outlineColor?.toRadixString(16)}/${b.outlineWidthRatio}').join(', ')}',
      );
      for (final block in detected) {
        expect(block.textColor, isNotNull);
        expect(block.outlineColor, 0xffffffff);
        expect(block.outlineWidthRatio, inInclusiveRange(.025, .12));
        final rgb = _rgb(block.textColor!);
        if (color == null) {
          expect(rgb[0], greaterThan(150));
          expect(rgb[1], lessThan(100));
          expect(rgb[2], greaterThan(90));
        } else {
          for (int channel = 0; channel < 3; channel++) {
            expect(rgb[channel], closeTo(color[channel], 12));
          }
        }
        final restored = RecognizedTextBlock.fromJson(block.toJson());
        expect(restored.textStyleVersion, 1);
        expect(restored.textColor, block.textColor);
        expect(restored.outlineColor, block.outlineColor);
        expect(restored.outlineWidthRatio, block.outlineWidthRatio);
      }
      final cached =
          detected
              .map((b) => RecognizedTextBlock.fromJson(b.toJson()))
              .toList();
      final again = _sample(img.Image(width: 200, height: 400), cached);
      expect(again.map((b) => b.toJson()), cached.map((b) => b.toJson()));
    }
  });

  test('真实黑白页保持黑字，白纸不被当成白描边', () {
    final page =
        img.decodeImage(
          File('$_fixtures/background_residual/source.png').readAsBytesSync(),
        )!;
    final snapshot = jsonDecode(
      File(
        '$_fixtures/background_residual/pipeline_snapshot.json',
      ).readAsStringSync(),
    );
    final originalBlocks =
        (snapshot['allOcrBlocks'] as List)
            .take(4)
            .map((b) => RecognizedTextBlock.fromJson(b))
            .toList();
    for (final block in _sample(page, originalBlocks)) {
      print(
        '黑白页: ${block.textColor?.toRadixString(16)}/${block.outlineColor?.toRadixString(16)}',
      );
      expect(_rgb(block.textColor!).every((v) => v < 40), isTrue);
      expect(block.outlineColor, isNull);
    }
  });

  testWidgets('采样样式经共同布局进入实际导出 PNG，横竖排均保留红蓝字与白边', (tester) async {
    await tester.runAsync(() async {
      final originalPaths = pathService;
      final originalSetting = imageTranslationSetting;
      final directory = Directory('.dart_tool/acceptance/source-text-style');
      await directory.create(recursive: true);
      pathService = PathService()..jhOcrModelDir = directory;
      imageTranslationSetting = ImageTranslationSetting();
      imageTranslationSetting.translationBackgroundOpacity.value = 0;
      try {
        for (final (name, color) in [
          ('red', [200, 30, 80]),
          ('blue', [30, 90, 220]),
        ]) {
          final style = _sample(_recolor(source, color), blocks)[2];
          for (final vertical in [false, true]) {
            final styled = RecognizedTextBlock.fromJson({
              ...style.toJson(),
              'text': vertical ? '原文' : 'original',
              'left': 30,
              'top': 30,
              'width': vertical ? 40 : 200,
              'height': vertical ? 200 : 40,
              'sourceGlyphWidth': 30,
              'sourceGlyphHeight': 30,
            });
            final result = ImageTranslationResult(
              status: ImageTranslationStatus.success,
              translatedText: vertical ? '译文' : 'COLOR',
              blocks: [styled],
              imageWidth: 260,
              imageHeight: 260,
            );
            final reader = buildTranslationOverlayLayout(
              result: result,
              sourceSize: const Size(260, 260),
              visibleImage: const Rect.fromLTWH(0, 0, 260, 260),
              textDirection: TextDirection.ltr,
              backgroundColor: Colors.white,
              backgroundOpacity: 0,
            );
            expect(reader.texts.single.color, Color(style.textColor!));
            expect(reader.texts.single.outlineColor, Colors.white);
            expect(reader.texts.single.vertical, vertical);
            final blank = img.Image(width: 260, height: 260);
            img.fill(blank, color: img.ColorRgb8(150, 130, 120));
            final input = File('${directory.path}/source.png');
            await input.writeAsBytes(img.encodePng(blank));
            final key = '$name-${vertical ? 'vertical' : 'horizontal'}';
            final service =
                ImageTranslationService()..publishResult(key, result);
            final output = await service.exportOverlay(
              ImageTranslationRequest(cacheKey: key, imagePath: input.path),
            );
            await output.copy('${directory.path}/$key.png');
            final rendered = img.decodeImage(await output.readAsBytes())!;
            int colored = 0, white = 0;
            for (final p in rendered) {
              if ((p.r - color[0]).abs() < 12 &&
                  (p.g - color[1]).abs() < 12 &&
                  (p.b - color[2]).abs() < 12)
                colored++;
              if (p.r > 240 && p.g > 240 && p.b > 240) white++;
            }
            expect(colored, greaterThan(30), reason: '$key 的实际译文字色');
            expect(white, greaterThan(20), reason: '$key 的实际白描边');
          }
        }
      } finally {
        imageTranslationSetting = originalSetting;
        pathService = originalPaths;
      }
    });
  });
}

// ===== 私有工具 =====

List<int> _rgb(int color) => [color >> 16 & 255, color >> 8 & 255, color & 255];

List<RecognizedTextBlock> _sample(
  img.Image image,
  List<RecognizedTextBlock> blocks,
) => detectTranslationColors({
  'bytes': Uint8List.fromList(img.encodePng(image)),
  'width': image.width,
  'height': image.height,
  'blocks': blocks,
});

// 红蓝样例只替换真实粉色字芯，保留原图背景和白描边；属于派生验收素材。
img.Image _recolor(img.Image source, List<int>? color) {
  final result = source.clone();
  if (color != null) {
    for (final p in result) {
      if (p.r > 150 && p.g < 100 && p.b > 90)
        p.setRgb(color[0], color[1], color[2]);
    }
  }
  return result;
}
