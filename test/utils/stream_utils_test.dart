import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:voyza/utils/stream_utils.dart';

// Real timers, short intervals: the throttle is wall-clock driven and these
// windows (40 ms) are an order of magnitude wider than scheduler jitter.
const _interval = Duration(milliseconds: 40);
Future<void> _tick([int ms = 60]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  group('StreamUtils.throttle', () {
    test('delivers the newest value once per interval', () async {
      final source = StreamController<int>();
      final out = <int>[];
      source.stream.transform(StreamUtils.throttle(_interval)).listen(out.add);

      source.add(1);
      source.add(2);
      await _tick(10);
      source.add(3);
      expect(out, isEmpty,
          reason: 'trailing edge: nothing before the interval');
      await _tick();
      expect(out, [3]);

      source.add(4);
      await _tick();
      expect(out, [3, 4]);
      await source.close();
    });

    test('two throttled streams do not share state', () async {
      final a = StreamController<String>();
      final b = StreamController<String>();
      final outA = <String>[], outB = <String>[];
      a.stream.transform(StreamUtils.throttle(_interval)).listen(outA.add);
      b.stream.transform(StreamUtils.throttle(_interval)).listen(outB.add);

      a.add('a1');
      b.add('b1');
      await _tick();
      expect(outA, ['a1']);
      expect(outB, ['b1']);
      await a.close();
      await b.close();
    });

    test('a cancelled listener keeps nothing from the next one', () async {
      final source = StreamController<int>.broadcast();
      final first = <int>[];
      final sub = source.stream
          .transform(StreamUtils.throttle(_interval))
          .listen(first.add);
      source.add(1); // pending in the first listener's timer
      await sub.cancel();

      final second = <int>[];
      source.stream
          .transform(StreamUtils.throttle(_interval))
          .listen(second.add);
      source.add(2);
      await _tick();
      expect(first, isEmpty, reason: 'cancelled: its timer was dropped');
      expect(second, [2], reason: 'the new listener gets its own value');
      await source.close();
    });

    test('cancelling stops the source subscription', () async {
      var cancelled = false;
      final source = StreamController<int>(onCancel: () => cancelled = true);
      final sub = source.stream
          .transform(StreamUtils.throttle(const Duration(seconds: 1)))
          .listen((_) {});
      await sub.cancel();
      expect(cancelled, isTrue);
    });
  });
}
