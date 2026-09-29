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

      int readerUpdates = 0;
      final removeListener = service.addListenerId(
        ImageTranslationService.readerStateId,
        () => readerUpdates++,
      );
      addTearDown(removeListener);
      expect(await service.hydrateResult(request), isTrue);
      expect(readerUpdates, greaterThan(0));
      final updatesAfterHydration = readerUpdates;
      service.releaseInMemoryResult(request.cacheKey);
      expect(readerUpdates, greaterThan(updatesAfterHydration));
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

  test(
    'cache inspection counts only the current image without hydration',
    () async {
      final service = ImageTranslationService();
      service.setTranslationCacheDirectoryForTesting(temporaryDirectory);
      final request = ImageTranslationRequest(
        cacheKey: 'inspection-page',
        imagePath: sourceImage.path,
      );
      expect(await service.hasCachedTranslation(request), isFalse);
      await service.writePersistentResultForRequest(
        request,
        const ImageTranslationResult(
          status: ImageTranslationStatus.success,
          translatedText: 'translated',
        ),
      );
      expect(await service.hasCachedTranslation(request), isTrue);
      expect(
        service.resultFor(request.cacheKey).status,
        ImageTranslationStatus.idle,
      );
      await sourceImage.writeAsBytes(<int>[8, 7, 6, 5]);
      expect(await service.hasCachedTranslation(request), isFalse);
    },
  );

  test(
    'old translation cache acquires source colors without retranslation',
    () async {
      final source = image.Image(width: 40, height: 20);
      image.fill(source, color: image.ColorRgb8(0, 0, 0));
      await sourceImage.writeAsBytes(image.encodePng(source));
      final service = ImageTranslationService();
      service.setTranslationCacheDirectoryForTesting(temporaryDirectory);
      final request = ImageTranslationRequest(
        cacheKey: 'old-inverted-page',
        imagePath: sourceImage.path,
      );
      await service.writePersistentResultForRequest(
        request,
        const ImageTranslationResult(
          status: ImageTranslationStatus.success,
          translatedText: 'cached translation',
          imageWidth: 40,
          imageHeight: 20,
          blocks: [
            RecognizedTextBlock(
              text: 'source',
              confidence: 1,
              width: 40,
              height: 20,
            ),
          ],
        ),
      );
      expect(await service.hydrateResult(request), isTrue);
      final result = service.resultFor(request.cacheKey);
      expect(result.fromCache, isTrue);
      expect(result.translatedText, 'cached translation');
      expect(result.blocks.single.backgroundColor, 0xff000000);
    },
  );

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

  test(
    'cached connected bubbles acquire areas without changing translation groups',
    () async {
      final source = image.Image(width: 104, height: 40);
      image.fill(source, color: image.ColorRgb8(30, 30, 30));
      for (int y = 0; y < 40; y++) {
        for (int x = 0; x < 104; x++) {
          final inLobe = [
            20,
            52,
            84,
          ].any((cx) => (x - cx) * (x - cx) + (y - 20) * (y - 20) <= 225);
          if (inLobe || ((y - 20).abs() <= 2 && x >= 20 && x <= 84)) {
            source.setPixelRgb(x, y, 250, 250, 250);
          }
        }
      }
      await sourceImage.writeAsBytes(image.encodePng(source));
      final service = ImageTranslationService();
      service.setTranslationCacheDirectoryForTesting(temporaryDirectory);
      final request = ImageTranslationRequest(
        cacheKey: 'connected-cache',
        imagePath: sourceImage.path,
      );
      await service.writePersistentResultForRequest(
        request,
        const ImageTranslationResult(
          status: ImageTranslationStatus.success,
          imageWidth: 104,
          imageHeight: 40,
          translatedText: '完整译文不必重新翻译',
          translatedGroups: ['完整译文不必重新翻译'],
          blocks: [
            RecognizedTextBlock(
              text: 'source',
              confidence: 1,
              left: 12,
              top: 12,
              width: 80,
              height: 16,
            ),
          ],
          containers: [
            RecognizedTextContainer(
              blockIndices: [0],
              left: 0,
              top: 0,
              width: 104,
              height: 40,
            ),
          ],
        ),
      );
      expect(await service.hydrateResult(request), isTrue);
      final result = service.resultFor(request.cacheKey);
      expect(result.containers.single.layoutRegions.length, 3);
      expect(result.containers.single.blockIndices, [0]);
      expect(result.translatedGroups, ['完整译文不必重新翻译']);
      expect(result.translatedText, '完整译文不必重新翻译');
    },
  );
}
