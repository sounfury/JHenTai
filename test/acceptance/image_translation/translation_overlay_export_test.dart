import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:jhentai/src/model/image_translation.dart';
import 'package:jhentai/src/service/image_translation_service.dart';
import 'package:jhentai/src/service/path_service.dart';
import 'package:jhentai/src/setting/image_translation_setting.dart';

void main() {
  const blocks = <RecognizedTextBlock>[
    RecognizedTextBlock(
      text: 'first',
      confidence: 1,
      left: 40,
      top: 40,
      width: 60,
      height: 20,
      backgroundColor: 0xffaaaaaa,
    ),
    RecognizedTextBlock(
      text: 'continuation',
      confidence: 1,
      left: 40,
      top: 65,
      width: 60,
      height: 20,
      backgroundColor: 0xffaaaaaa,
    ),
    // An old zero-sized OCR entry must keep its place in the index mapping.
    RecognizedTextBlock(text: 'old artifact', confidence: 1),
    RecognizedTextBlock(
      text: 'second',
      confidence: 1,
      left: 240,
      top: 180,
      width: 80,
      height: 20,
      backgroundColor: 0xffbbbbbb,
    ),
  ];
  const containers = <RecognizedTextContainer>[
    RecognizedTextContainer(
      blockIndices: [0, 1],
      left: 30,
      top: 30,
      width: 100,
      height: 80,
    ),
    RecognizedTextContainer(
      blockIndices: [2],
      left: 0,
      top: 0,
      width: 0,
      height: 0,
    ),
    RecognizedTextContainer(
      blockIndices: [3],
      left: 230,
      top: 170,
      width: 100,
      height: 50,
    ),
  ];

  for (final groupedOnly in [false, true]) {
    testWidgets(
      groupedOnly ? '分组译文无需逐行文本也能导出实际图片' : '多行气泡的短译文保留空占位，旧小尺寸块不使其他气泡错位',
      (tester) async {
        await tester.runAsync(() async {
          final originalPaths = pathService;
          final originalSetting = imageTranslationSetting;
          final directory = Directory(
            '.dart_tool/acceptance/translation-overlay',
          );
          await directory.create(recursive: true);
          pathService = PathService()..jhOcrModelDir = directory;
          imageTranslationSetting = ImageTranslationSetting();
          imageTranslationSetting.translationBackgroundOpacity.value = 1;
          try {
            final source = img.Image(width: 400, height: 300);
            img.fill(source, color: img.ColorRgb8(255, 255, 255));
            final input = File('${directory.path}/source.png');
            await input.writeAsBytes(img.encodePng(source));
            final service = ImageTranslationService();
            service.publishResult(
              'short-translation',
              ImageTranslationResult(
                status: ImageTranslationStatus.success,
                translatedText: groupedOnly ? '' : 'A\n\n\nB',
                translatedGroups: groupedOnly ? ['A', '', 'B'] : [],
                blocks: blocks,
                containers: containers,
                imageWidth: 400,
                imageHeight: 300,
              ),
            );
            final output = await service.exportOverlay(
              ImageTranslationRequest(
                cacheKey: 'short-translation',
                imagePath: input.path,
              ),
            );
            await output.copy(
              '${directory.path}/${groupedOnly ? 'grouped' : 'short'}.png',
            );
            final rendered = img.decodeImage(await output.readAsBytes())!;
            expect((rendered.width, rendered.height), (400, 300));
            // Test the delivered image, including the intended bubble positions.
            expect(rendered.getPixel(32, 32).r.toInt(), 0xaa);
            expect(rendered.getPixel(232, 172).r.toInt(), 0xbb);
            expect(rendered.getPixel(5, 5).r.toInt(), 255);
            expect(rendered.getPixel(390, 290).r.toInt(), 255);
          } finally {
            imageTranslationSetting = originalSetting;
            pathService = originalPaths;
          }
        });
      },
    );
  }
}
