import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/model/image_translation.dart';
import 'package:jhentai/src/model/reader_floating_ball_position.dart';
import 'package:jhentai/src/service/reader_action_persistence.dart';
import 'package:jhentai/src/service/image_translation_service.dart';

class _MemoryKeyValueStore implements ReaderActionKeyValueStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

void main() {
  test(
    'floating ball positions are persisted independently by orientation',
    () async {
      final _MemoryKeyValueStore memory = _MemoryKeyValueStore();
      final ReaderFloatingBallPositionStore store =
          ReaderFloatingBallPositionStore(store: memory);

      await store.save(
        Orientation.portrait,
        const ReaderFloatingBallPosition(x: 0, y: 0.25),
      );
      await store.save(
        Orientation.landscape,
        const ReaderFloatingBallPosition(x: 1, y: 0.75),
      );

      expect(
        await store.load(Orientation.portrait),
        const ReaderFloatingBallPosition(x: 0, y: 0.25),
      );
      expect(
        await store.load(Orientation.landscape),
        const ReaderFloatingBallPosition(x: 1, y: 0.75),
      );
    },
  );

  test(
    'canceling a translation batch does not delete completed disk cache',
    () async {
      final Directory temp = await Directory.systemTemp.createTemp(
        'jh-reader-translation',
      );
      final ImageTranslationService service = ImageTranslationService();
      service.setTranslationCacheDirectoryForTesting(temp);
      try {
        await service.writePersistentResultForKeyForTesting(
          'completed-page',
          const ImageTranslationResult(
            status: ImageTranslationStatus.success,
            sourceText: 'source',
            translatedText: 'translated',
          ),
        );
        final File cache = File('${temp.path}/completed-page.json');
        expect(await cache.exists(), isTrue);
        service.beginBatch(2);
        service.cancelBatch();
        expect(await cache.exists(), isTrue);
      } finally {
        await temp.delete(recursive: true);
      }
    },
  );
}
