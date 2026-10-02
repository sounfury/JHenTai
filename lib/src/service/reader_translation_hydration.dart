import 'dart:async';

class ReaderViewportDelta {
  const ReaderViewportDelta({required this.entering, required this.leaving});

  final Set<int> entering;
  final Set<int> leaving;
}

/// Tracks viewport membership so frame-by-frame scroll callbacks do not
/// repeat page-entry work such as disk-backed translation hydration.
class ReaderViewportTracker {
  Set<int> _visible = <int>{};

  Set<int> get visible => Set<int>.unmodifiable(_visible);

  ReaderViewportDelta update(Set<int> next) {
    final ReaderViewportDelta delta = ReaderViewportDelta(
      entering: next.difference(_visible),
      leaving: _visible.difference(next),
    );
    _visible = Set<int>.of(next);
    return delta;
  }

  void clear() => _visible = <int>{};
}

typedef ReaderPageHydrator = Future<void> Function(int index);
typedef ReaderHydrationErrorHandler =
    void Function(int index, Object error, StackTrace stackTrace);

/// Keeps translation-cache hydration out of widget builders and layout
/// initialization. At most one task runs for a page; an image-load event that
/// arrives while the viewport-entry task is active queues exactly one follow-up
/// attempt, after the image has reached the disk cache.
class ReaderPageHydrationScheduler {
  final Map<int, Future<void>> _active = <int, Future<void>>{};
  final Map<int, _ReaderHydrationRequest> _pending =
      <int, _ReaderHydrationRequest>{};
  bool _disposed = false;

  bool get isIdle => _active.isEmpty && _pending.isEmpty;

  void schedule({
    required int index,
    required ReaderPageHydrator hydrate,
    bool retryIfActive = false,
    ReaderHydrationErrorHandler? onError,
  }) {
    if (_disposed) {
      return;
    }
    final _ReaderHydrationRequest request = _ReaderHydrationRequest(
      hydrate: hydrate,
      onError: onError,
    );
    if (_active.containsKey(index)) {
      if (retryIfActive) {
        _pending[index] = request;
      }
      return;
    }
    _start(index, request);
  }

  void _start(int index, _ReaderHydrationRequest request) {
    late final Future<void> task;
    task = Future<void>.sync(() => request.hydrate(index));
    _active[index] = task;
    unawaited(
      task.then<void>(
        (_) => _complete(index, task),
        onError: (Object error, StackTrace stackTrace) {
          try {
            request.onError?.call(index, error, stackTrace);
          } finally {
            _complete(index, task);
          }
        },
      ),
    );
  }

  void _complete(int index, Future<void> task) {
    if (!identical(_active[index], task)) {
      return;
    }
    _active.remove(index);
    final _ReaderHydrationRequest? pending = _pending.remove(index);
    if (!_disposed && pending != null) {
      _start(index, pending);
    }
  }

  void dispose() {
    _disposed = true;
    _pending.clear();
  }
}

class _ReaderHydrationRequest {
  const _ReaderHydrationRequest({required this.hydrate, this.onError});

  final ReaderPageHydrator hydrate;
  final ReaderHydrationErrorHandler? onError;
}

