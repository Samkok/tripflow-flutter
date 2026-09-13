import 'package:flutter_test/flutter_test.dart';
import 'package:voyza/utils/photo_refresh_policy.dart';

void main() {
  final now = DateTime(2026, 9, 13, 12);

  group('signature', () {
    test('is stable, order-sensitive and short', () {
      final a = PhotoRefreshPolicy.signature(['x', 'y']);
      expect(a, PhotoRefreshPolicy.signature(['x', 'y']));
      expect(a, isNot(PhotoRefreshPolicy.signature(['y', 'x'])));
      expect(a, isNot(PhotoRefreshPolicy.signature(const [])));
      expect(a.length, 16);
    });
  });

  group('record', () {
    test('round-trips through encode/decode', () {
      final r = PhotoRefreshRecord(at: now, signature: 'abc');
      final back = PhotoRefreshRecord.decode(r.encode());
      expect(back?.at, now);
      expect(back?.signature, 'abc');
    });

    test('rejects junk', () {
      expect(PhotoRefreshRecord.decode(null), isNull);
      expect(PhotoRefreshRecord.decode(''), isNull);
      expect(PhotoRefreshRecord.decode('nope'), isNull);
      expect(PhotoRefreshRecord.decode('x|sig'), isNull);
      expect(PhotoRefreshRecord.decode('123|'), isNull);
    });
  });

  group('dueOnShow', () {
    test('never asked: due once the row is 30 days old', () {
      expect(
        PhotoRefreshPolicy.dueOnShow(
          record: null,
          rowCreatedAt: now.subtract(const Duration(days: 29)),
          now: now,
        ),
        isFalse,
      );
      expect(
        PhotoRefreshPolicy.dueOnShow(
          record: null,
          rowCreatedAt: now.subtract(const Duration(days: 30)),
          now: now,
        ),
        isTrue,
      );
    });

    test('asked before: counts from the answer, not the row', () {
      final oldRow = now.subtract(const Duration(days: 400));
      expect(
        PhotoRefreshPolicy.dueOnShow(
          record: PhotoRefreshRecord(
              at: now.subtract(const Duration(days: 2)), signature: 's'),
          rowCreatedAt: oldRow,
          now: now,
        ),
        isFalse,
      );
      expect(
        PhotoRefreshPolicy.dueOnShow(
          record: PhotoRefreshRecord(
              at: now.subtract(const Duration(days: 31)), signature: 's'),
          rowCreatedAt: oldRow,
          now: now,
        ),
        isTrue,
      );
    });
  });

  group('dueOnError', () {
    const sig = 'current';

    test('never asked → due', () {
      expect(
        PhotoRefreshPolicy.dueOnError(
            record: null, currentSignature: sig, now: now),
        isTrue,
      );
    });

    test('row holds other references than the last answer → due', () {
      expect(
        PhotoRefreshPolicy.dueOnError(
          record: PhotoRefreshRecord(at: now, signature: 'other'),
          currentSignature: sig,
          now: now,
        ),
        isTrue,
      );
    });

    test('row holds the last answer → due only after the retry window', () {
      expect(
        PhotoRefreshPolicy.dueOnError(
          record: PhotoRefreshRecord(
              at: now.subtract(const Duration(hours: 23)), signature: sig),
          currentSignature: sig,
          now: now,
        ),
        isFalse,
      );
      expect(
        PhotoRefreshPolicy.dueOnError(
          record: PhotoRefreshRecord(
              at: now.subtract(const Duration(hours: 24)), signature: sig),
          currentSignature: sig,
          now: now,
        ),
        isTrue,
      );
    });
  });
}
