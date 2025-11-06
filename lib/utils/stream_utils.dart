import 'dart:async';

class StreamUtils {
  /// A stream transformer that throttles events from a source stream.
  ///
  /// It emits the most recent value from the source stream at a specified
  /// interval, effectively reducing the frequency of events. This is useful
  /// for high-frequency streams like sensor data to improve performance
  /// and reduce battery consumption.
  static StreamTransformer<T, T> throttle<T>(Duration duration) {
    return StreamTransformer<T, T>.fromHandlers(
      handleData: (data, sink) {
        if (_throttleTimer == null || !_throttleTimer!.isActive) {
          _throttleTimer = Timer(duration, () {
            if (_latestValue != null) {
              sink.add(_latestValue as T);
              _latestValue = null; // Clear after emitting
            }
          });
        }
        _latestValue = data;
      },
      handleDone: (sink) {
        _throttleTimer?.cancel();
        sink.close();
      },
    );
  }

  static Timer? _throttleTimer;
  static dynamic _latestValue;
}