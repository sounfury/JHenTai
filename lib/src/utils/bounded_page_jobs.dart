/// Runs page jobs with at most [concurrency] active futures.
///
/// Returns the number of pages claimed. The caller can mark unclaimed pages
/// canceled after [shouldStop] becomes true.
Future<int> runBoundedPageJobs({
  required int total,
  required int concurrency,
  required bool Function() shouldStop,
  required Future<void> Function(int index) runPage,
}) async {
  if (total <= 0) {
    return 0;
  }
  int nextIndex = 0;

  Future<void> worker() async {
    while (!shouldStop() && nextIndex < total) {
      final int index = nextIndex++;
      await runPage(index);
    }
  }

  await Future.wait(
    List<Future<void>>.generate(concurrency.clamp(1, total), (_) => worker()),
  );
  return nextIndex;
}
