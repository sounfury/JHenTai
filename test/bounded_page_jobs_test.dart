import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/utils/bounded_page_jobs.dart';

void main() {
  test(
    'runs every page once without exceeding the concurrency limit',
    () async {
      final Completer<void> gate = Completer<void>();
      final List<int> visited = <int>[];
      int active = 0;
      int peak = 0;
      final Future<int> job = runBoundedPageJobs(
        total: 11,
        concurrency: 5,
        shouldStop: () => false,
        runPage: (int index) async {
          active++;
          if (active > peak) peak = active;
          visited.add(index);
          await gate.future;
          active--;
        },
      );

      expect(visited, <int>[0, 1, 2, 3, 4]);
      gate.complete();
      expect(await job, 11);
      expect(peak, 5);
      expect(visited, <int>[for (int i = 0; i < 11; i++) i]);
    },
  );

  test('stops claiming new pages after cancellation', () async {
    final Completer<void> gate = Completer<void>();
    bool canceled = false;
    final List<int> visited = <int>[];
    final Future<int> job = runBoundedPageJobs(
      total: 10,
      concurrency: 3,
      shouldStop: () => canceled,
      runPage: (int index) async {
        visited.add(index);
        await gate.future;
      },
    );

    expect(visited, <int>[0, 1, 2]);
    canceled = true;
    gate.complete();
    expect(await job, 3);
    expect(visited, <int>[0, 1, 2]);
  });
}
