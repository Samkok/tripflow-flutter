import 'dart:convert';

import 'package:crypto/crypto.dart';

/// What this device last learned about a place's photos: when it asked
/// Google, and a signature of the references the row was left holding.
class PhotoRefreshRecord {
  final DateTime at;
  final String signature;

  const PhotoRefreshRecord({required this.at, required this.signature});

  /// Compact `epochMillis|signature` form for SharedPreferences.
  String encode() => '${at.millisecondsSinceEpoch}|$signature';

  static PhotoRefreshRecord? decode(String? raw) {
    if (raw == null) return null;
    final split = raw.indexOf('|');
    if (split <= 0 || split == raw.length - 1) return null;
    final ms = int.tryParse(raw.substring(0, split));
    if (ms == null) return null;
    return PhotoRefreshRecord(
      at: DateTime.fromMillisecondsSinceEpoch(ms),
      signature: raw.substring(split + 1),
    );
  }
}

/// Decision rules for renewing a stop's Google photo references. Pure, so
/// the cadence is unit-tested; PlacePhotoRefreshService applies them.
///
/// Google's `photo_reference` tokens are temporary — Google rotates them and
/// its terms let an app keep only the place id long-term — so a list saved
/// at add time eventually stops resolving, and photos added on Google Maps
/// since then never show up. Renewing means one photos-only Place Details
/// call per place, and these rules keep that rare.
class PhotoRefreshPolicy {
  /// References older than this are renewed when their photos are shown —
  /// that is also how photos newly added on Google Maps reach a stop.
  static const staleAfter = Duration(days: 30);

  /// After a renewal, a photo that still fails to load isn't asked about
  /// again before this passes (a place with no photos, a key problem…).
  static const retryAfter = Duration(hours: 24);

  /// Order-sensitive digest of a reference list — short enough to persist.
  static String signature(Iterable<String> refs) {
    final digest = sha1.convert(utf8.encode(refs.join('\n')));
    return digest.toString().substring(0, 16);
  }

  /// Photos are on screen: renew when this device never asked and the row
  /// is old, or when the last answer is older than [staleAfter].
  static bool dueOnShow({
    required PhotoRefreshRecord? record,
    required DateTime rowCreatedAt,
    required DateTime now,
  }) {
    final since = record?.at ?? rowCreatedAt;
    return now.difference(since) >= staleAfter;
  }

  /// A photo failed to load: renew unless the row already holds the
  /// references from a recent answer — then the failure is something else
  /// and asking again within [retryAfter] would only cost a call.
  static bool dueOnError({
    required PhotoRefreshRecord? record,
    required String currentSignature,
    required DateTime now,
  }) {
    if (record == null) return true;
    if (record.signature != currentSignature) return true;
    return now.difference(record.at) >= retryAfter;
  }
}
