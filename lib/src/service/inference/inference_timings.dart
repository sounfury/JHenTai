/// Opt-in diagnostics shared by the release benchmark and inference engines.
/// Durations are wall time; parent spans overlap their child spans.
class InferenceTimings {
  final Stopwatch _clock = Stopwatch()..start();
  final List<Map<String, Object>> events = [];

  int get now => _clock.elapsedMicroseconds;

  void record(
    String stage,
    int since, [
    Map<String, Object> details = const {},
  ]) {
    events.add({'stage': stage, 'ms': (now - since) / 1000, ...details});
  }

  Map<String, Object> toJson() {
    final Map<String, double> totals = {};
    final Map<String, int> calls = {};
    for (final event in events) {
      final stage = event['stage'] as String;
      totals[stage] = (totals[stage] ?? 0) + (event['ms'] as double);
      calls[stage] = (calls[stage] ?? 0) + 1;
    }
    return {'totalsMs': totals, 'calls': calls, 'events': events};
  }
}
