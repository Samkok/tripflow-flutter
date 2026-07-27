import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../models/trip.dart';
import '../providers/map_ui_state_provider.dart';
import '../providers/trip_listener_provider.dart';
import '../providers/trip_provider.dart';
import '../screens/location_search_screen.dart';
import 'app_toast.dart';

/// After a trip's date range grows (a location confirmed onto a day outside
/// the old range), asks where the user is staying on the newly added day(s):
/// pick one of the trip's EXISTING accommodations (its stay range is extended
/// to cover the new days) or add a different place (opens search pre-scheduled
/// to the first new day).
///
/// Silently no-ops when there's nothing to ask about: no previous range to
/// compare, no new days, the trip isn't the active one (accommodations are
/// read from the active trip's state), or the trip has no accommodations yet.
Future<void> maybePromptAccommodationForNewDays(
  BuildContext context,
  WidgetRef ref, {
  required Trip trip,
  required DateTime? newStart,
  required DateTime? newEnd,
}) async {
  DateTime day(DateTime d) => DateTime(d.year, d.month, d.day);

  final oldStart = trip.startDate;
  final oldEnd = trip.endDate;
  if (oldStart == null || oldEnd == null) return;

  // Newly added days = outside the old [start..end] range.
  final newDays = <DateTime>[];
  if (newStart != null) {
    for (var d = day(newStart);
        d.isBefore(day(oldStart));
        d = DateTime(d.year, d.month, d.day + 1)) {
      newDays.add(d);
    }
  }
  if (newEnd != null) {
    for (var d = DateTime(oldEnd.year, oldEnd.month, oldEnd.day + 1);
        !d.isAfter(day(newEnd));
        d = DateTime(d.year, d.month, d.day + 1)) {
      newDays.add(d);
    }
  }
  if (newDays.isEmpty) return;

  // Accommodations come from the ACTIVE trip's in-memory state — bail for
  // any other trip rather than showing wrong options.
  final activeTrip = ref.read(realtimeActiveTripProvider).asData?.value;
  if (activeTrip?.id != trip.id) return;

  final accommodations = ref
      .read(tripProvider)
      .pinnedLocations
      .where((l) => l.isAccommodation)
      .toList();
  if (accommodations.isEmpty) return;

  if (!context.mounted) return;
  final firstNewDay = newDays.first;
  final lastNewDay = newDays.last;
  final newDaysLabel = newDays.length == 1
      ? DateFormat('EEE, MMM d').format(firstNewDay)
      : '${DateFormat('MMM d').format(firstNewDay)} – ${DateFormat('MMM d').format(lastNewDay)}';

  final choice = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('Where are you staying?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Your trip now includes $newDaysLabel. Keep one of your '
              'accommodations for the new ${newDays.length == 1 ? 'day' : 'days'}?',
              style: Theme.of(ctx).textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
            ...accommodations.map((acc) {
              final s = acc.scheduledDate;
              final e = acc.scheduledEndDate ?? s;
              final range = (s != null && e != null)
                  ? '${DateFormat('MMM d').format(s)} – ${DateFormat('MMM d').format(e)}'
                  : null;
              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.hotel_outlined,
                    color: Theme.of(ctx).colorScheme.primary),
                title: Text(acc.name,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: range != null ? Text('Currently $range') : null,
                onTap: () => Navigator.of(ctx).pop(acc.id),
              );
            }),
            const Divider(height: 16),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.add_location_alt_outlined),
              title: const Text('Add a different place'),
              subtitle: const Text('Search a new stay for those nights'),
              onTap: () => Navigator.of(ctx).pop('__different__'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Not now'),
        ),
      ],
    ),
  );
  if (choice == null || !context.mounted) return;

  if (choice == '__different__') {
    // Pre-schedule the search to the first new day; the add flow stamps the
    // ambient selected date onto the new place.
    ref.read(selectedDateProvider.notifier).state = firstNewDay;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const LocationSearchScreen()),
    );
    return;
  }

  final accIndex = accommodations.indexWhere((a) => a.id == choice);
  if (accIndex == -1) return;
  final acc = accommodations[accIndex];
  final accStartRaw = acc.scheduledDate ?? firstNewDay;
  final accEndRaw = acc.scheduledEndDate ?? accStartRaw;
  final accStart = day(accStartRaw);
  final accEnd = day(accEndRaw);
  final extendedStart = firstNewDay.isBefore(accStart) ? firstNewDay : accStart;
  final extendedEnd = lastNewDay.isAfter(accEnd) ? lastNewDay : accEnd;

  final notifier = ref.read(tripProvider.notifier);
  // The new days were just created (nothing scheduled on them), so a
  // conflict can only mean a concurrent edit — refuse rather than clobber.
  final conflicts =
      notifier.accommodationConflicts(acc.id, extendedStart, extendedEnd);
  if (conflicts.isNotEmpty) {
    AppToast.error(
        context, 'Another accommodation already covers part of those days.');
    return;
  }
  final ok = await notifier.setAccommodation(acc.id,
      start: extendedStart, end: extendedEnd);
  if (!context.mounted) return;
  if (ok) {
    AppToast.success(context,
        '${acc.name} now covers the new ${newDays.length == 1 ? 'day' : 'days'}.');
  } else {
    AppToast.error(context, 'Couldn\'t update the accommodation.');
  }
}
