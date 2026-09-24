import 'package:flutter_test/flutter_test.dart';
import 'package:voyza/services/place_photo_refresh_service.dart';
import 'package:voyza/services/places_service.dart';
import 'package:voyza/utils/photo_refresh_policy.dart';

typedef _Save = ({String id, Map<String, dynamic> updates, bool synced});

/// The service over fakes: Google answers from [answers] (missing place →
/// unreachable), saves are recorded, prefs are a map, the clock is manual.
class _Harness {
  final fetches = <String>[];
  final saves = <_Save>[];
  final prefs = <String, String>{};
  final answers = <String, PlacePhotosResult>{};
  bool canWrite = true;
  DateTime now = DateTime(2026, 9, 13, 12);

  late final PlacePhotoRefreshService svc = PlacePhotoRefreshService(
    fetch: (placeId) async {
      fetches.add(placeId);
      return answers[placeId] ?? const PlacePhotosResult.unreached();
    },
    canWrite: (_) async => canWrite,
    save: (id, updates, {required synced}) async {
      saves.add((id: id, updates: updates, synced: synced));
    },
    readPref: (key) => prefs[key],
    writePref: (key, value) async => prefs[key] = value,
    clock: () => now,
  );

  String? record(String placeId) =>
      prefs['${PlacePhotoRefreshService.prefsPrefix}$placeId'];
}

PhotoRefreshTarget target({
  String id = 'loc1',
  String? placeId = 'P1',
  List<String> refs = const ['old1', 'old2'],
  DateTime? createdAt,
  String? tripId = 'trip1',
  bool hasPlaceTypes = false,
}) =>
    PhotoRefreshTarget(
      id: id,
      placeId: placeId,
      refs: refs,
      createdAt: createdAt ?? DateTime(2026, 9, 1),
      tripId: tripId,
      hasPlaceTypes: hasPlaceTypes,
    );

/// Lets the fire-and-forget renewals run to completion.
Future<void> settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  const fresh = ['new1', 'new2'];

  test('a failing tile renews the references once and saves them', () async {
    final h = _Harness();
    h.answers['P1'] =
        const PlacePhotosResult.ok(fresh, attributions: ['<a>Someone</a>']);
    h.svc.noteLoadFailed(target());
    h.svc.noteLoadFailed(target()); // tiles report on every rebuild
    await settle();

    expect(h.fetches, ['P1']);
    expect(h.saves, hasLength(1));
    final save = h.saves.single;
    expect(save.id, 'loc1');
    expect(save.synced, isTrue);
    expect(save.updates['photo_references'], fresh);
    expect(save.updates['photo_reference'], 'new1');
    expect(save.updates['photo_attributions'], ['<a>Someone</a>']);
    final record = PhotoRefreshRecord.decode(h.record('P1'));
    expect(record?.at, h.now);
    expect(record?.signature, PhotoRefreshPolicy.signature(fresh));
  });

  test('a row without place types takes Google\'s, photos unchanged or not',
      () async {
    final h = _Harness();
    const types = ['airport', 'point_of_interest'];
    // Same photos as the row holds — only the types are news.
    h.answers['P1'] =
        const PlacePhotosResult.ok(['old1', 'old2'], types: types);
    final r = await h.svc.refreshNow(target());
    expect(r.outcome, PhotoRefreshOutcome.unchanged,
        reason: 'the photos are what the user asked about');
    expect(h.saves, hasLength(1));
    expect(h.saves.single.updates['place_types'], types);

    // A row that already has types keeps them (a hand-picked mode may live
    // there): the session answer is not applied to it.
    h.saves.clear();
    h.svc.noteLoadFailed(target(id: 'loc2', hasPlaceTypes: true));
    await settle();
    expect(h.saves, isEmpty);

    // An answer with no types never writes an empty list.
    h.answers['P2'] = const PlacePhotosResult.ok(['old1', 'old2']);
    expect((await h.svc.refreshNow(target(id: 'loc3', placeId: 'P2'))).outcome,
        PhotoRefreshOutcome.unchanged);
    expect(h.saves, isEmpty);
  });

  test('a sibling copy of the place is updated from the session answer',
      () async {
    final h = _Harness();
    h.answers['P1'] = const PlacePhotosResult.ok(fresh);
    h.svc.noteLoadFailed(target());
    await settle();
    h.svc.noteLoadFailed(target(id: 'loc2', tripId: 'trip2'));
    await settle();

    expect(h.fetches, ['P1']);
    expect(h.saves.map((s) => s.id), ['loc1', 'loc2']);
  });

  test('a tile that already shows the latest answer is left alone', () async {
    final h = _Harness();
    // A previous session recorded this answer an hour ago.
    h.prefs['${PlacePhotoRefreshService.prefsPrefix}P1'] = PhotoRefreshRecord(
      at: h.now.subtract(const Duration(hours: 1)),
      signature: PhotoRefreshPolicy.signature(fresh),
    ).encode();
    h.answers['P1'] = const PlacePhotosResult.ok(fresh);

    h.svc.noteLoadFailed(target(refs: fresh));
    await settle();
    expect(h.fetches, isEmpty);
    expect(h.saves, isEmpty);

    // A day later the same failure is worth one more look.
    h.now = h.now.add(const Duration(hours: 24));
    h.svc.noteLoadFailed(target(refs: fresh));
    await settle();
    expect(h.fetches, ['P1']);
    expect(h.saves, isEmpty, reason: 'same list back → nothing to write');
  });

  test('read-only members get a device-local update', () async {
    final h = _Harness()..canWrite = false;
    h.answers['P1'] = const PlacePhotosResult.ok(fresh);
    h.svc.noteLoadFailed(target());
    await settle();
    expect(h.saves.single.synced, isFalse);
  });

  test('unreachable Google changes nothing and is retried after the cooldown',
      () async {
    final h = _Harness();
    h.svc.noteLoadFailed(target());
    await settle();
    expect(h.fetches, ['P1']);
    expect(h.saves, isEmpty);
    expect(h.record('P1'), isNull);

    h.svc.noteLoadFailed(target()); // inside the per-stop cooldown
    await settle();
    expect(h.fetches, ['P1']);

    h.now = h.now.add(const Duration(minutes: 2));
    h.answers['P1'] = const PlacePhotosResult.ok(fresh);
    h.svc.noteLoadFailed(target());
    await settle();
    expect(h.fetches, ['P1', 'P1']);
    expect(h.saves, hasLength(1));
  });

  test('showing old photos renews them; recent ones are not looked up',
      () async {
    final h = _Harness();
    h.answers['P1'] = const PlacePhotosResult.ok(fresh);
    h.answers['P2'] = const PlacePhotosResult.ok(['p2']);
    h.answers['P3'] = const PlacePhotosResult.ok(['p3']);

    h.svc.noteShown(
        target(id: 'old', createdAt: h.now.subtract(const Duration(days: 40))));
    h.svc.noteShown(target(
        id: 'young',
        placeId: 'P2',
        createdAt: h.now.subtract(const Duration(days: 3))));
    // Old row, but this device asked about the place last week.
    h.prefs['${PlacePhotoRefreshService.prefsPrefix}P3'] = PhotoRefreshRecord(
      at: h.now.subtract(const Duration(days: 7)),
      signature: 'whatever',
    ).encode();
    h.svc.noteShown(target(
        id: 'checked',
        placeId: 'P3',
        createdAt: h.now.subtract(const Duration(days: 400))));
    await settle();

    expect(h.fetches, ['P1']);
    expect(h.saves.single.id, 'old');

    // Once per session per stop, even if the card rebuilds.
    h.svc.noteShown(
        target(id: 'old', createdAt: h.now.subtract(const Duration(days: 40))));
    await settle();
    expect(h.fetches, ['P1']);
  });

  test('Google reporting no photos clears the stale gallery', () async {
    final h = _Harness();
    h.answers['P1'] = const PlacePhotosResult.ok([]);
    h.svc.noteLoadFailed(target());
    await settle();
    final save = h.saves.single;
    expect(save.updates['photo_references'], isEmpty);
    expect(save.updates['photo_reference'], '');
  });

  test('a refusal or a vanished place keeps the list and is not retried soon',
      () async {
    for (final answer in [
      const PlacePhotosResult.denied(),
      const PlacePhotosResult.placeGone(),
    ]) {
      final h = _Harness();
      h.answers['P1'] = answer;
      h.svc.noteLoadFailed(target());
      await settle();
      expect(h.saves, isEmpty);
      // Recorded against the list the row keeps → the same failing tile
      // waits a day before asking again, even in a fresh session.
      final record = PhotoRefreshRecord.decode(h.record('P1'));
      expect(record?.signature,
          PhotoRefreshPolicy.signature(const ['old1', 'old2']));
      expect(
        PhotoRefreshPolicy.dueOnError(
          record: record,
          currentSignature:
              PhotoRefreshPolicy.signature(const ['old1', 'old2']),
          now: h.now.add(const Duration(hours: 1)),
        ),
        isFalse,
      );
    }
  });

  test('stops without a place id are ignored', () async {
    final h = _Harness();
    h.svc.noteLoadFailed(target(placeId: null));
    h.svc.noteShown(target(placeId: ''));
    await settle();
    expect(h.fetches, isEmpty);
    expect((await h.svc.refreshNow(target(placeId: null))).outcome,
        PhotoRefreshOutcome.noPlaceId);
  });

  group('refreshNow', () {
    test('asks Google regardless of a recent answer and saves changes',
        () async {
      final h = _Harness();
      h.prefs['${PlacePhotoRefreshService.prefsPrefix}P1'] = PhotoRefreshRecord(
        at: h.now,
        signature: PhotoRefreshPolicy.signature(const ['old1', 'old2']),
      ).encode();
      h.answers['P1'] = const PlacePhotosResult.ok(fresh);

      final result = await h.svc.refreshNow(target());
      expect(result.outcome, PhotoRefreshOutcome.updated);
      expect(result.photoCount, 2);
      expect(h.fetches, ['P1']);
      expect(h.saves.single.updates['photo_references'], fresh);
      expect(h.svc.lastRenewedAt('P1'), h.now);
    });

    test('reports unchanged, no photos, gone and failed without saving',
        () async {
      Future<PhotoRefreshOutcome> outcome(
          PlacePhotosResult? answer, List<String> rowRefs) async {
        final h = _Harness();
        if (answer != null) h.answers['P1'] = answer;
        final r = await h.svc.refreshNow(target(refs: rowRefs));
        if (r.outcome != PhotoRefreshOutcome.noPhotos) {
          expect(h.saves, isEmpty);
        }
        return r.outcome;
      }

      expect(await outcome(const PlacePhotosResult.ok(fresh), fresh),
          PhotoRefreshOutcome.unchanged);
      expect(await outcome(const PlacePhotosResult.ok([]), const ['old1']),
          PhotoRefreshOutcome.noPhotos);
      expect(await outcome(const PlacePhotosResult.placeGone(), fresh),
          PhotoRefreshOutcome.placeGone);
      expect(await outcome(const PlacePhotosResult.denied(), fresh),
          PhotoRefreshOutcome.failed);
      expect(await outcome(null, fresh), PhotoRefreshOutcome.failed);
    });

    test('concurrent taps share one lookup', () async {
      final h = _Harness();
      h.answers['P1'] = const PlacePhotosResult.ok(fresh);
      final results = await Future.wait(
          [h.svc.refreshNow(target()), h.svc.refreshNow(target())]);
      expect(h.fetches, ['P1']);
      expect(results.map((r) => r.outcome),
          everyElement(PhotoRefreshOutcome.updated));
    });
  });
}
