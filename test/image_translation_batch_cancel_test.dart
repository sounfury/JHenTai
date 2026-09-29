import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/model/image_translation.dart';
import 'package:jhentai/src/service/engine/engine_contract.dart';
import 'package:jhentai/src/service/image_translation_service.dart';

void main() {
  test('canceling a batch stops every active page task', () async {
    final ImageTranslationService service = ImageTranslationService();
    final Completer<int> gate = Completer<int>();
    final EngineTask<int> first = EngineTask<int>.start(
      operation: (_) => gate.future,
    );
    final EngineTask<int> second = EngineTask<int>.start(
      operation: (_) => gate.future,
    );
    final Future<void> firstCanceled = expectLater(
      first.future,
      throwsA(isA<EngineTaskCancelledException>()),
    );
    final Future<void> secondCanceled = expectLater(
      second.future,
      throwsA(isA<EngineTaskCancelledException>()),
    );
    service.attachExternalBatchTask(first, activeCacheKey: 'page:1');
    service.attachExternalBatchTask(second, activeCacheKey: 'page:2');

    service.cancelBatch();
    expect(first.cancellation.isCancelled, isTrue);
    expect(second.cancellation.isCancelled, isTrue);
    expect(service.resultFor('page:1').status, ImageTranslationStatus.canceled);
    expect(service.resultFor('page:2').status, ImageTranslationStatus.canceled);

    gate.complete(1);
    await Future.wait(<Future<void>>[firstCanceled, secondCanceled]);
    service.detachExternalBatchTask(first);
    service.detachExternalBatchTask(second);
  });
}
