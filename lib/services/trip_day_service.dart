import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../models/saved_location.dart';
import '../models/trip.dart';
import '../providers/location_provider.dart';
import '../providers/user_trip_provider.dart';
import '../utils/same_day_place_guard.dart';
import '../utils/trip_dates.dart';
import '../widgets/accommodation_prompts.dart';
import '../widgets/app_toast.dart';

/// The trip's persisted date range after a day add/removal — callers use it
/// to refresh their local trip copy without re-deriving any date math.
typedef TripRange = ({DateTime start, DateTime end, DateTime changedDay});

/// Growing and shrinking a trip by one day — ONE implementation shared by
/// the trip-details tile and the map sheet's day strip, so the two surfaces
/// can't drift (they already had different toasts and only one reset the
/// map selection before this was extracted).
class TripDayService {
  TripDayService._();

  /// The trip's new start when its range changes: the declared start when
  /// it still precedes [notAfter], else the earliest SCHEDULED day, else
  /// [notAfter] itself. Never later than [notAfter] — persisting an
  /// inverted range (start > end) crashes every DateTimeRange consumer.
  /// Unscheduled places are ignored on purpose: `isActiveOnDate` falls back
  /// to createdAt, and pinning a range to a weeks-old creation date
  /// back-dated trips by surprise.
  static DateTime _startPin(
      Trip trip, List<SavedLocation> tripLocations, DateTime notAfter) {
    final declared = trip.startDate;
    if (declared != null && !dayKey(declared).isAfter(notAfter)) {
      return dayKey(declared);
    }
    DateTime? earliest;
    for (final l in tripLocations) {
      final sched = l.scheduledDate;
      if (sched == null) continue;
      final d = dayKey(sched);
      if (earliest == null || d.isBefore(earliest)) earliest = d;
    }
    if (earliest != null && !earliest.isAfter(notAfter)) return earliest;
    return notAfter;
  }

  /// Reads the location list for destructive/persisting flows. Returns null
  /// (with a toast) when the provider has never produced a value — acting
  /// on an empty fallback list silently skipped the move/delete dialog and
  /// shrunk ranges while orphaning that day's places.
  static List<SavedLocation>? _locationsOrBail(
      BuildContext context, WidgetRef ref, String tripId) {
    final async = ref.read(savedLocationsProvider);
    final all = async.valueOrNull;
    if (all == null) {
      AppToast.info(context, 'Still loading your places — try again.');
      return null;
    }
    return all.where((l) => l.tripId == tripId).toList();
  }

  /// Adds one day after the trip's last day. Persists the widened range,
  /// then offers the accommodation prompt for the newly materialized day
  /// (matching every other day-materializing path). Returns the new range,
  /// or null when nothing was written.
  static Future<TripRange?> addDayAtEnd(
    BuildContext context,
    WidgetRef ref, {
    required Trip trip,
    required List<DateTime> days,
  }) async {
    if (days.isEmpty) return null;
    final last = dayKey(days.last);
    final newDay = DateTime(last.year, last.month, last.day + 1);
    final tripLocations = _locationsOrBail(context, ref, trip.id);
    if (tripLocations == null) return null;
    final first = _startPin(trip, tripLocations, newDay);

    try {
      await ref.read(tripRepositoryProvider).updateTrip(
            trip.id,
            startDate: first,
            endDate: newDay,
          );
      ref.invalidate(userTripsProvider);
      if (context.mounted) {
        AppToast.success(
            context, 'Day added — ${DateFormat('MMM d').format(newDay)}');
        // A new empty trip day just materialized — same question every
        // other materializing path asks (self-skips for non-active trips).
        await maybePromptAccommodationForNewDays(
          context,
          ref,
          trip: trip,
          newDays: [newDay],
        );
      }
      return (start: first, end: newDay, changedDay: newDay);
    } catch (e) {
      debugPrint('TripDayService.addDayAtEnd: $e');
      if (context.mounted) {
        AppToast.error(context, 'Couldn\'t add the day — try again.');
      }
      return null;
    }
  }

  /// Removes the trip's LAST day.
  ///
  ///   * No places SCHEDULED on it → the range just shrinks.
  ///   * Scheduled places on it → asks: delete them, or move them onto the
  ///     new last day. Moving merges same-place duplicates and unmarks a
  ///     moved accommodation when the target day already has one (the DB
  ///     enforces one accommodation per day).
  ///
  /// Multi-day stays that merely END on the removed day are shrunk by one
  /// day in both branches. Unscheduled places (no scheduledDate) are never
  /// touched — their createdAt-based phantom occupancy must not get them
  /// deleted. All row writes are dispatched together (single round-trip
  /// wall-clock) with deletions LAST, so a mid-flight failure cannot have
  /// destroyed anything the surviving rows still reference.
  ///
  /// Returns the new persisted range, or null when cancelled/failed.
  static Future<TripRange?> removeLastDay(
    BuildContext context,
    WidgetRef ref, {
    required Trip trip,
    required List<DateTime> days,
  }) async {
    if (days.length <= 1) {
      AppToast.warning(context, 'A trip needs at least one day.');
      return null;
    }
    final tripLocations = _locationsOrBail(context, ref, trip.id);
    if (tripLocations == null) return null;

    final last = dayKey(days.last);
    final newLast = dayKey(days[days.length - 2]);
    final first = _startPin(trip, tripLocations, newLast);
    final fmt = DateFormat('MMM d');

    // Scheduled rows only — see doc comment.
    final onLast = tripLocations
        .where((l) => l.scheduledDate != null && l.isActiveOnDate(last))
        .toList();
    final spans = <SavedLocation>[];
    final singles = <SavedLocation>[];
    for (final l in onLast) {
      (dayKey(l.scheduledDate!).isBefore(last) ? spans : singles).add(l);
    }

    String choice = 'shrink';
    if (onLast.isNotEmpty) {
      final n = onLast.length;
      if (!context.mounted) return null;
      final picked = await showDialog<String>(
        context: context,
        builder: (ctx) {
          final theme = Theme.of(ctx);
          return AlertDialog(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: Text('Remove ${fmt.format(last)}?'),
            content: Text(
              '$n ${n == 1 ? 'place is' : 'places are'} planned on this '
              'day. Move ${n == 1 ? 'it' : 'them'} to ${fmt.format(newLast)}, '
              'or delete ${n == 1 ? 'it' : 'them'} with the day?',
              style: theme.textTheme.bodyMedium,
            ),
            actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
            actions: [
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(ctx, 'move'),
                      child: const Text('Move'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => Navigator.pop(ctx, 'delete'),
                      style: FilledButton.styleFrom(
                        backgroundColor: theme.colorScheme.error,
                        foregroundColor: theme.colorScheme.onError,
                      ),
                      child: const Text('Delete'),
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      );
      if (picked == null) return null;
      choice = picked;
    }

    try {
      final repo = ref.read(locationRepositoryProvider);
      // Plan first, write after — updates batched together, deletes last.
      final updates = <String, Map<String, dynamic>>{};
      final deletions = <String>[];
      var moved = 0, merged = 0, deleted = 0, unmarked = 0;

      // Spans shrink in both branches — same row, one day shorter.
      for (final l in spans) {
        updates[l.id] = {
          'scheduled_end_date':
              dayKey(l.scheduledDate!).isAtSameMomentAs(newLast)
                  ? null
                  : newLast.toIso8601String(),
        };
      }

      if (choice == 'delete') {
        for (final l in singles) {
          deletions.add(l.id);
          deleted++;
        }
      } else if (choice == 'move') {
        final movedIds = singles.map((l) => l.id).toSet();
        // Occupancy on the target day after the shrink (scheduled rows
        // only), tracked as PlaceKeys and EXTENDED as singles land — so two
        // copies of one place on the removed day can't both move over.
        final placedKeys = tripLocations
            .where((l) =>
                l.scheduledDate != null &&
                !movedIds.contains(l.id) &&
                l.isActiveOnDate(newLast))
            .map(placeKeyOfSaved)
            .toList();
        var targetHasAccommodation = tripLocations.any((l) =>
            l.scheduledDate != null &&
            !movedIds.contains(l.id) &&
            l.isActiveOnDate(newLast) &&
            l.isAccommodation);

        for (final l in singles) {
          final key = placeKeyOfSaved(l);
          if (placedKeys.any((o) => isSamePlace(o, key))) {
            // Same place already on the target day — merge.
            deletions.add(l.id);
            merged++;
            continue;
          }
          placedKeys.add(key);
          final rowUpdates = <String, dynamic>{
            'scheduled_date': newLast.toIso8601String(),
            'scheduled_end_date': null,
          };
          if (l.isAccommodation) {
            if (targetHasAccommodation) {
              rowUpdates['is_accommodation'] = false;
              unmarked++;
            } else {
              targetHasAccommodation = true;
            }
          }
          updates[l.id] = rowUpdates;
          moved++;
        }
      }

      await Future.wait(
          updates.entries.map((e) => repo.updateLocation(e.key, e.value)));
      await Future.wait(deletions.map(repo.deleteLocation));
      await ref.read(tripRepositoryProvider).updateTrip(
            trip.id,
            startDate: first,
            endDate: newLast,
          );
      ref.invalidate(userTripsProvider);

      if (context.mounted) {
        final parts = <String>[
          if (moved > 0) '$moved moved to ${fmt.format(newLast)}',
          if (merged > 0) '$merged merged',
          if (deleted > 0) '$deleted deleted',
          if (unmarked > 0) '$unmarked accommodation unmarked',
        ];
        AppToast.success(
            context,
            parts.isEmpty
                ? 'Day removed — trip now ends ${fmt.format(newLast)}'
                : 'Day removed · ${parts.join(' · ')}');
      }
      return (start: first, end: newLast, changedDay: last);
    } catch (e) {
      debugPrint('TripDayService.removeLastDay: $e');
      if (context.mounted) {
        AppToast.error(context, 'Couldn\'t remove the day — try again.');
      }
      return null;
    }
  }
}
