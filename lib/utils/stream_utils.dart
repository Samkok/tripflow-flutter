import 'dart:async';

class StreamUtils {
  /// A stream transformer that throttles events from a source stream.
  ///
  /// It emits the most recent value from the source stream at most once per
  /// [duration] (trailing edge: the first event after a quiet period starts
  /// the timer, and whatever value is newest when it fires is delivered).
  /// Useful for high-frequency streams like sensor data to reduce rendering
  /// and battery work.
  ///
  /// Every subscription gets its own timer and latest value. The previous
  /// version kept both in static fields, so two throttled streams shared
  /// one timer (one of them starved) and a stream cancelled mid-interval
  /// handed its pending value to the next listener's dead subscription:
  /// the compass beam missed its first reading after each restart.
  static StreamTransformer<T, T> throttle<T>(Duration duration) {
    return StreamTransformer<T, T>.fromBind((source) {
      late StreamController<T> controller;
      StreamSubscription<T>? subscription;
      Timer? timer;
      T? latest;
      var hasLatest = false;

      void emit() {
        timer = null;
        if (!hasLatest) return;
        final value = latest as T;
        latest = null;
        hasLatest = false;
        if (!controller.isClosed) controller.add(value);
      }

      controller = StreamController<T>(
        onListen: () {
          subscription = source.listen(
            (data) {
              latest = data;
              hasLatest = true;
              timer ??= Timer(duration, emit);
            },
            onError: controller.addError,
            onDone: () {
              timer?.cancel();
              timer = null;
              controller.close();
            },
          );
        },
        onPause: () => subscription?.pause(),
        onResume: () => subscription?.resume(),
        onCancel: () {
          timer?.cancel();
          timer = null;
          final sub = subscription;
          subscription = null;
          return sub?.cancel();
        },
      );
      return controller.stream;
    });
  }
}
