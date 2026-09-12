import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:voyza/main.dart' show SharedPrefsCache;

import '../models/saved_location.dart';
import '../models/trip.dart';
import '../providers/auth_provider.dart';
import '../providers/location_provider.dart';
import '../providers/user_trip_provider.dart';
import '../repositories/location_repository.dart';
import '../utils/rollover_planner.dart';
import '../utils/trip_dates.dart';
import 'supabase_service.dart';

/// What one carry-forward run did to one trip. This is the ONE alert the
/// run produces: the owner's device toasts [message] (via
/// [rolloverNoticeProvider]) and every other member gets the same sentence
/// as a single push (see [TripRolloverService._notifyMembers]) — never one
/// alert per moved stop.
class RolloverNotice {
  final String tripId;
  final String tripName;
  final int moved;

  /// "yesterday", "Sep 9" or "earlier days" — see [rolloverFromLabel].
  final String fromLabel;
  final DateTime at;

  const RolloverNotice({
    required this.tripId,
    required this.tripName,
    required this.moved,
    required this.fromLabel,
    required this.at,
  });

  /// e.g. `3 places from yesterday moved to today in "Vietnam"`.
  String get message =>
      rolloverMessage(moved: moved, fromLabel: fromLabel, tripName: tripName);
}

/// The latest AUTOMATIC run that moved something, for the owner's device
/// to toast once. MainScreen listens and consumes (nulls) it when shown, so
/// a rebuild can never repeat it. Only [TripRolloverService.runIfDue]
/// publishes here — the settings switch's immediate run reports through
/// its own toast at the switch.
final rolloverNoticeProvider = StateProvider<RolloverNotice?>((ref) => null);

/// "Carry unvisited places forward" — a per-trip, owner-controlled setting
/// ([Trip.autoRollUnvisited]). While the trip is ongoing, every stop left
/// ACTIVE (not done, not skipped) on a day that has passed is moved to
/// today, so the plan follows the traveller instead of piling up behind
/// them. Runs on the OWNER's device — at launch, on resume and when the trip
/// page opens — at most once per trip per day; the moves reach every member
/// through the normal location update path (one batched UPDATE, so no push
/// storm), followed by one heads-up push per member. Which rows move is
/// decided by [planRollover].
class TripRolloverService {
  static const _prefsPrefix = 'trip_rollover_last_';

  /// Runs the carry-over for every owned, ongoing trip with the setting on.
  /// Returns how many places moved. Cheap when nothing is due.
  static Future<int> runIfDue(WidgetRef ref) async {
    List<Trip> trips;
    List<SavedLocation> rows;
    try {
      trips = await ref
          .read(userTripsProvider.future)
          .timeout(const Duration(seconds: 8));
      rows = await ref
          .read(savedLocationsProvider.future)
          .timeout(const Duration(seconds: 8));
    } catch (e) {
      debugPrint('TripRollover: data not ready ($e) — skipping this pass');
      return 0;
    }
    final userId = ref.read(currentUserIdProvider);
    final repo = ref.read(locationRepositoryProvider);
    final today = dayKey(DateTime.now());
    final prefs = SharedPrefsCache.instance;
    var moved = 0;
    for (final trip in trips) {
      if (!trip.autoRollUnvisited) continue;
      // Owner only: the setting is the owner's, and one device doing the
      // move is enough (collaborators receive it through sync).
      if (userId != null && trip.userId != userId) continue;
      if (!isOngoing(trip, today)) continue;
      final key = '$_prefsPrefix${trip.id}';
      final stamp = today.toIso8601String();
      if (prefs.getString(key) == stamp) continue; // already ran today
      final notice =
          await _rollTrip(trip: trip, rows: rows, repo: repo, today: today);
      await prefs.setString(key, stamp);
      if (notice != null) {
        moved += notice.moved;
        ref.read(rolloverNoticeProvider.notifier).state = notice;
      }
    }
    return moved;
  }

  /// Immediate run for one trip — the owner just switched the setting on
  /// and expects to see the effect now, not at the next launch. Returns
  /// what moved (null when nothing did); the caller shows it.
  static Future<RolloverNotice?> rollNow(WidgetRef ref, Trip trip) async {
    final rows =
        ref.read(savedLocationsProvider).valueOrNull ?? const <SavedLocation>[];
    final today = dayKey(DateTime.now());
    if (!isOngoing(trip, today)) return null;
    final notice = await _rollTrip(
      trip: trip,
      rows: rows,
      repo: ref.read(locationRepositoryProvider),
      today: today,
    );
    await SharedPrefsCache.instance
        .setString('$_prefsPrefix${trip.id}', today.toIso8601String());
    return notice;
  }

  /// Started and not yet over: the only window in which carrying forward
  /// makes sense (nothing to move before day one; nowhere to move after
  /// the last day).
  static bool isOngoing(Trip trip, DateTime today) {
    final s = trip.startDate;
    final e = trip.endDate;
    if (s == null || e == null) return false;
    return !today.isBefore(dayKey(s)) && !today.isAfter(dayKey(e));
  }

  static Future<RolloverNotice?> _rollTrip({
    required Trip trip,
    required List<SavedLocation> rows,
    required LocationRepository repo,
    required DateTime today,
  }) async {
    final ids = planRollover(tripId: trip.id, rows: rows, today: today);
    if (ids.isEmpty) return null;

    // Remember where the rows came from BEFORE the write — that is what the
    // notice says ("from yesterday" / "from Sep 9" / "from earlier days").
    final moving = ids.toSet();
    final fromDays = <DateTime>[
      for (final l in rows)
        if (moving.contains(l.id) && l.scheduledDate != null) l.scheduledDate!,
    ];

    await repo.updateLocationsBatch({
      for (final id in ids) id: {'scheduled_date': today},
    });

    final notice = RolloverNotice(
      tripId: trip.id,
      tripName: trip.name,
      moved: ids.length,
      fromLabel: rolloverFromLabel(fromDays, today),
      at: DateTime.now(),
    );
    debugPrint('TripRollover: ${notice.message}');
    await _notifyMembers(notice, fromDays: fromDays, today: today);
    return notice;
  }

  /// One push per member, never per stop. The server (notify_trip_rollover,
  /// owner-only) builds the same sentence as [RolloverNotice.message] and
  /// inserts one notifications row per collaborator other than the owner
  /// running the move; a member already told about this trip's move for
  /// this day is not told twice. Best effort: guests have no members, and
  /// offline the move itself still syncs later even though the heads-up
  /// is skipped.
  static Future<void> _notifyMembers(
    RolloverNotice notice, {
    required List<DateTime> fromDays,
    required DateTime today,
  }) async {
    final client = SupabaseService.instance.client;
    if (client.auth.currentUser == null) return;
    final ymd = DateFormat('yyyy-MM-dd');
    final distinctFrom = {for (final d in fromDays) ymd.format(dayKey(d))};
    try {
      final sent = await client.rpc('notify_trip_rollover', params: {
        'p_trip_id': notice.tripId,
        'p_moved': notice.moved,
        'p_from_dates': distinctFrom.toList(),
        'p_to_date': ymd.format(today),
      });
      debugPrint('TripRollover: told $sent member(s) of "${notice.tripName}"');
    } catch (e) {
      debugPrint('TripRollover: member heads-up skipped ($e)');
    }
  }
}
