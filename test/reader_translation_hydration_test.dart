import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/service/reader_translation_hydration.dart';

void main() {
  test('viewport tracker only reports pages that actually enter or leave', () {
    final ReaderViewportTracker tracker = ReaderViewportTracker();

    final ReaderViewportDelta first = tracker.update(<int>{4, 5});
    expect(first.entering, <int>{4, 5});
    expect(first.leaving, isEmpty);

    final ReaderViewportDelta repeated = tracker.update(<int>{4, 5});
    expect(repeated.entering, isEmpty);
    expect(repeated.leaving, isEmpty);

    final ReaderViewportDelta moved = tracker.update(<int>{5, 6});
    expect(moved.entering, <int>{6});
    expect(moved.leaving, <int>{4});
  });

  test(
    'page hydration is single-flight and an image-load event queues one retry',
    () async {
      final ReaderPageHydrationScheduler scheduler =
          ReaderPageHydrationScheduler();
      final Completer<void> firstGate = Completer<void>();
      int calls = 0;

      Future<void> hydrate(int index) async {
        expect(index, 4);
        calls++;
        if (calls == 1) {
          await firstGate.future;
        }
      }

      scheduler.schedule(index: 4, hydrate: hydrate);
      scheduler.schedule(index: 4, hydrate: hydrate);
      scheduler.schedule(index: 4, hydrate: hydrate, retryIfActive: true);
      scheduler.schedule(index: 4, hydrate: hydrate, retryIfActive: true);

      expect(calls, 1);
      firstGate.complete();
      await Future<void>.delayed(Duration.zero);
      expect(calls, 2);
      await Future<void>.delayed(Duration.zero);
      expect(scheduler.isIdle, isTrue);
      scheduler.dispose();
    },
  );

}
