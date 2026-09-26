import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:jhentai/src/model/image_translation.dart';
import 'package:jhentai/src/service/image_translation_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'empty layout analysis is persisted and reused after viewport eviction',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'bubble-upgrade-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/page.png');
      final source = image.Image(width: 32, height: 32);
      image.fill(source, color: image.ColorRgb8(255, 255, 255));
      await file.writeAsBytes(image.encodePng(source));
      final service = ImageTranslationService();
      service.setTranslationCacheDirectoryForTesting(directory);
      final request = ImageTranslationRequest(
        cacheKey: 'page',
        imagePath: file.path,
      );
      await service.writePersistentResultForRequest(
        request,
        const ImageTranslationResult(
          status: ImageTranslationStatus.success,
          translatedText: 'cached translation',
          imageWidth: 32,
          imageHeight: 32,
          containers: [
            RecognizedTextContainer(
              blockIndices: [],
              left: 0,
              top: 0,
              width: 4,
              height: 4,
            ),
          ],
        ),
      );

      expect(await service.hydrateResult(request), isTrue);
      final container = service.resultFor('page').containers.single;
      expect(container.layoutRegions, isEmpty);
      expect(container.hasAnalyzedLayout, isTrue);

      final key = await service.persistentKeyForRequest(request);
      final cache = File('${directory.path}/$key.json');
      final persisted =
          jsonDecode(utf8.decode(gzip.decode(await cache.readAsBytes())))
              as Map;
      expect(
        (persisted['containers'] as List).single['layoutAnalysisVersion'],
        1,
      );
      final sentinel = DateTime.utc(2020, 1, 1);
      await cache.setLastModified(sentinel);
      service.releaseInMemoryResult('page');
      expect(await service.hydrateResult(request), isTrue);
      expect(
        service.resultFor('page').containers.single.hasAnalyzedLayout,
        isTrue,
      );
      expect((await cache.lastModified()).toUtc(), sentinel);
    },
  );

  test('older nonempty layout remains valid without a version marker', () {
    final container = RecognizedTextContainer.fromJson({
      'blockIndices': [0],
      'left': 0,
      'top': 0,
      'width': 20,
      'height': 20,
      'layoutRegions': [
        {'left': 2, 'top': 2, 'width': 16, 'height': 16},
      ],
    });
    expect(container.hasAnalyzedLayout, isTrue);
    expect(
      RecognizedTextContainer.fromJson(container.toJson()).layoutRegions,
      hasLength(1),
    );
  });
}
