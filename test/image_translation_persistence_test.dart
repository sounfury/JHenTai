import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:jhentai/src/model/image_translation.dart';
import 'package:jhentai/src/service/image_translation_service.dart';

void main() {
  late Directory temporaryDirectory;
  late File sourceImage;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'jh-image-translation-persistence',
    );
    sourceImage = File('${temporaryDirectory.path}/source.img');
    await sourceImage.writeAsBytes(<int>[1, 2, 3, 4, 5, 6]);
  });

  tearDown(() async {
    await temporaryDirectory.delete(recursive: true);
  });

  test(
    'persistent translation hydrates from bytes read from a real file',
    () async {
      final ImageTranslationService service = ImageTranslationService();
      service.setTranslationCacheDirectoryForTesting(temporaryDirectory);
      final ImageTranslationRequest request = ImageTranslationRequest(
        cacheKey: 'page-1',
        imagePath: sourceImage.path,
      );
      const ImageTranslationResult persisted = ImageTranslationResult(
        status: ImageTranslationStatus.success,
        sourceText: 'source',
        translatedText: 'translated',
        translatedGroups: <String>['完整的一句译文。'],
        mergeTextBlocks: false,
        blocks: <RecognizedTextBlock>[
          RecognizedTextBlock(text: 'source', confidence: 0.99),
        ],
        imageWidth: 10,
        imageHeight: 20,
      );

      await service.writePersistentResultForRequest(request, persisted);
      service.removeResult(request.cacheKey);

      expect(await service.hydrateResult(request), isTrue);
      final ImageTranslationResult hydrated = service.resultFor(
        request.cacheKey,
      );
      expect(hydrated.status, ImageTranslationStatus.success);
      expect(hydrated.translatedText, 'translated');
      expect(hydrated.translatedGroups, equals(<String>['完整的一句译文。']));
      expect(hydrated.mergeTextBlocks, isFalse);
      expect(hydrated.fromCache, isTrue);
    },
  );

  test('old translation cache acquires source colors without retranslation', () async {
    final source = image.Image(width: 40, height: 20);
    image.fill(source, color: image.ColorRgb8(0, 0, 0));
    await sourceImage.writeAsBytes(image.encodePng(source));
    final service = ImageTranslationService();
    service.setTranslationCacheDirectoryForTesting(temporaryDirectory);
    final request = ImageTranslationRequest(
      cacheKey: 'old-inverted-page', imagePath: sourceImage.path,
    );
    await service.writePersistentResultForRequest(request,
      const ImageTranslationResult(
        status: ImageTranslationStatus.success,
        translatedText: 'cached translation',
        imageWidth: 40,
        imageHeight: 20,
        blocks: [RecognizedTextBlock(
          text: 'source', confidence: 1, width: 40, height: 20,
        )],
      ),
    );
    expect(await service.hydrateResult(request), isTrue);
    final result = service.resultFor(request.cacheKey);
    expect(result.fromCache, isTrue);
    expect(result.translatedText, 'cached translation');
    expect(result.blocks.single.backgroundColor, 0xff000000);
  });

  test(
    'cached recognition does not throw while releasing source bytes',
    () async {
      final ImageTranslationService service = ImageTranslationService();
      service.setTranslationCacheDirectoryForTesting(temporaryDirectory);
      final ImageTranslationRequest request = ImageTranslationRequest(
        cacheKey: 'page-2',
        imagePath: sourceImage.path,
      );
      await service.writePersistentResultForRequest(
        request,
        const ImageTranslationResult(
          status: ImageTranslationStatus.success,
          sourceText: 'cached source',
          translatedText: 'cached translation',
        ),
      );

      expect(await service.recognizeImage(request), isNull);
      final ImageTranslationResult result = service.resultFor(request.cacheKey);
      expect(result.status, ImageTranslationStatus.success);
      expect(result.fromCache, isTrue);
    },
  );
}
