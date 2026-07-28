import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../models/trip.dart';
import '../providers/map_ui_state_provider.dart';
import '../providers/trip_listener_provider.dart';
import '../providers/trip_provider.dart';
import '../screens/location_search_screen.dart';
import 'app_toast.dart';

/// Asks where the user is staying on newly materialized trip day(s) — days
/// that just received their FIRST location (via add, move, or copy — however
/// a new date comes into existence). Offers the trip's EXISTING
/// accommodations (the chosen one's stay range is extended to cover the new
/// days) or adding a different place (opens search pre-scheduled to the
/// first new day).
///
/// Silently no-ops when there's nothing to ask: no new days, the trip isn't
/// the active one (accommodations are read from the active trip's state),
/// the trip has no accommodations yet, or every new day is already covered
/// by an accommodation's span.
Future<void> maybePromptAccommodationForNewDays(
  BuildContext context,
  WidgetRef ref, {
  required Trip trip,
  required List<DateTime> newDays,
}) async {
  DateTime day(DateTime d) => DateTime(d.year, d.month, d.day);

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

  // Only ask about days no accommodation already covers (a hotel spanning
  // the whole trip means there's nothing to decide).
  final uncovered = newDays
      .map(day)
      .toSet()
      .where((d) => !accommodations.any((a) => a.isActiveOnDate(d)))
      .toList()
    ..sort();
  if (uncovered.isEmpty) return;

  if (!context.mounted) return;
  final firstNewDay = uncovered.first;
  final lastNewDay = uncovered.last;
  final newDaysLabel = uncovered.length == 1
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
              'accommodations for the new ${uncovered.length == 1 ? 'day' : 'days'}?',
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
        '${acc.name} now covers the new ${uncovered.length == 1 ? 'day' : 'days'}.');
  } else {
    AppToast.error(context, 'Couldn\'t update the accommodation.');
  }
}
