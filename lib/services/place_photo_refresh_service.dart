import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/location_model.dart';
import '../models/saved_location.dart';
import '../utils/photo_refresh_policy.dart';
import 'places_service.dart';

/// The stop whose photos are on screen, reduced to what a renewal needs.
/// Built from either model so the map sheet, the trip cards and the trip
/// details list share one path.
class PhotoRefreshTarget {
  final String id;
  final String? placeId;
  final List<String> refs;
  final DateTime createdAt;
  final String? tripId;

  const PhotoRefreshTarget({
    required this.id,
    required this.placeId,
    required this.refs,
    required this.createdAt,
    required this.tripId,
  });

  factory PhotoRefreshTarget.fromModel(LocationModel m) => PhotoRefreshTarget(
        id: m.id,
        placeId: m.placeId,
        refs: m.photoReferences,
        createdAt: m.addedAt,
        tripId: m.tripId,
      );

  factory PhotoRefreshTarget.fromSaved(SavedLocation s) => PhotoRefreshTarget(
        id: s.id,
        placeId: s.placeId,
        refs: s.effectivePhotoReferences,
        createdAt: s.createdAt,
        tripId: s.tripId,
      );
}

typedef PhotoFetch = Future<PlacePhotosResult> Function(String placeId);
typedef PhotoSave = Future<void> Function(
  String locationId,
  Map<String, dynamic> updates, {
  required bool synced,
});

/// Keeps a stop's Google photos renderable.
///
/// Google's `photo_reference` tokens are temporary: Google rotates them, and
/// its terms let an app store only the place id long-term. VoyZa saves the
/// references at add time, so months later the photo endpoint starts
/// answering 400 and the tiles go blank — and photos added on Google Maps
/// since the add never appear. This service re-asks Place Details (photos
/// field only, keyed by the permanent place id) and writes Google's current
/// list back to the row:
///   * [noteLoadFailed] — a tile failed to load: renew now, unless the row
///     already holds a recent answer (then it isn't the reference's fault);
///   * [noteShown] — photos are on screen: renew when the last answer (or,
///     never asked on this device, the row itself) is 30 days old.
///
/// Cost guards: one in-flight lookup per place, a per-stop cooldown on the
/// error path (failing tiles report on every rebuild), one on-show check
/// per stop per session, a persisted per-place record shared by every copy
/// of the place on this device, and an in-session memo so sibling copies
/// are brought in line without another call.
///
/// Collaborators are handled through [canWrite]: a member who may edit the
/// trip saves the new list for everyone; a read-only member gets a
/// device-local patch so their own tiles render.
class PlacePhotoRefreshService {
  PlacePhotoRefreshService({
    required PhotoFetch fetch,
    required Future<bool> Function(String? tripId) canWrite,
    required PhotoSave save,
    required String? Function(String key) readPref,
    required Future<void> Function(String key, String value) writePref,
    DateTime Function() clock = DateTime.now,
  })  : _fetch = fetch,
        _canWrite = canWrite,
        _save = save,
        _readPref = readPref,
        _writePref = writePref,
        _now = clock;

  final PhotoFetch _fetch;
  final Future<bool> Function(String? tripId) _canWrite;
  final PhotoSave _save;
  final String? Function(String key) _readPref;
  final Future<void> Function(String key, String value) _writePref;
  final DateTime Function() _now;

  static const prefsPrefix = 'place_photos_v1_';

  /// A stop that just triggered a lookup isn't looked up again from the
  /// error path before this passes.
  static const attemptCooldown = Duration(minutes: 1);

  final _inFlight = <String, Future<PlacePhotosResult>>{};
  final _attemptedAt = <String, DateTime>{};
  final _shownChecked = <String>{};
  final _answers = <String, PlacePhotosResult>{};

  /// Photos for [t] are being rendered.
  void noteShown(PhotoRefreshTarget t) {
    final placeId = t.placeId;
    if (placeId == null || placeId.isEmpty) return;
    if (!_shownChecked.add(t.id)) return;
    if (_applyKnownAnswer(t, placeId)) return;
    final due = PhotoRefreshPolicy.dueOnShow(
      record: _record(placeId),
      rowCreatedAt: t.createdAt,
      now: _now(),
    );
    if (!due) return;
    unawaited(_renew(t, placeId));
  }

  /// A photo of [t] failed to load.
  void noteLoadFailed(PhotoRefreshTarget t) {
    final placeId = t.placeId;
    if (placeId == null || placeId.isEmpty) return;
    if (_applyKnownAnswer(t, placeId)) return;
    final now = _now();
    final last = _attemptedAt[t.id];
    if (last != null && now.difference(last) < attemptCooldown) return;
    final due = PhotoRefreshPolicy.dueOnError(
      record: _record(placeId),
      currentSignature: PhotoRefreshPolicy.signature(t.refs),
      now: now,
    );
    if (!due) return;
    _attemptedAt[t.id] = now;
    unawaited(_renew(t, placeId));
  }

  /// True when this session already asked Google about the place. If the
  /// answer was a photo list the row doesn't hold yet, it is applied without
  /// another lookup — a sibling copy of the same place, or a server echo
  /// that put the old list back.
  bool _applyKnownAnswer(PhotoRefreshTarget t, String placeId) {
    final answer = _answers[placeId];
    if (answer == null) return false;
    if (answer.status == PlacePhotosStatus.ok &&
        !listEquals(answer.refs, t.refs)) {
      unawaited(_apply(t, answer));
    }
    return true;
  }

  Future<void> _renew(PhotoRefreshTarget t, String placeId) async {
    // Block body on purpose: an arrow would return the removed future to
    // whenComplete, which would then wait on it — that is, on itself.
    final result = await (_inFlight[placeId] ??= _fetch(placeId).whenComplete(
      () {
        _inFlight.remove(placeId);
      },
    ));
    if (result.status == PlacePhotosStatus.unreached) return;

    _answers[placeId] = result;
    // A usable answer is remembered by the list the row ends up with; a
    // refusal by the list it keeps, so the same failing tile isn't asked
    // about again for a day.
    final kept = result.status == PlacePhotosStatus.ok ? result.refs : t.refs;
    await _writeRecord(
      placeId,
      PhotoRefreshRecord(
        at: _now(),
        signature: PhotoRefreshPolicy.signature(kept),
      ),
    );

    if (result.status != PlacePhotosStatus.ok) return;
    if (listEquals(result.refs, t.refs)) return;
    await _apply(t, result);
  }

  /// Writes Google's current list to the row. An empty list clears the
  /// gallery: the place has no photos any more, and a dead reference would
  /// only render as a blank tile.
  Future<void> _apply(PhotoRefreshTarget t, PlacePhotosResult fresh) async {
    final refs = fresh.refs;
    final updates = <String, dynamic>{
      'photo_reference': refs.isEmpty ? '' : refs.first,
      'photo_references': List<String>.of(refs),
      if (fresh.attributions != null) 'photo_attributions': fresh.attributions,
    };
    try {
      await _save(t.id, updates, synced: await _canWrite(t.tripId));
    } catch (e) {
      debugPrint('PlacePhotoRefreshService: could not save ${t.id}: $e');
    }
  }

  PhotoRefreshRecord? _record(String placeId) =>
      PhotoRefreshRecord.decode(_readPref('$prefsPrefix$placeId'));

  Future<void> _writeRecord(String placeId, PhotoRefreshRecord record) async {
    try {
      await _writePref('$prefsPrefix$placeId', record.encode());
    } catch (e) {
      debugPrint('PlacePhotoRefreshService: could not record $placeId: $e');
    }
  }
}
