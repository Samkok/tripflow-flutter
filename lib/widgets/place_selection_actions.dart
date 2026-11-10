import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/all_days_route_provider.dart';
import '../providers/map_ui_state_provider.dart';
import '../providers/trip_day_labeler_provider.dart';
import '../providers/trip_listener_provider.dart';
import '../providers/trip_provider.dart';
import '../services/subscription_limit_service.dart';
import '../utils/date_picker_utils.dart';
import '../utils/same_day_place_guard.dart';
import '../utils/trip_date_validator.dart';
import 'accommodation_prompts.dart';
import 'app_toast.dart';
import 'move_to_trip_sheet.dart';
import 'trip_day_picker.dart';

/// Multi-select actions for planned places — the trip page's selection
/// bar. The selection lives in [selectedLocationsProvider]; every action
/// goes through `TripNotifier`, so the caller makes its trip the map trip
/// first ([buildPlaceSelectionMenu.beforeAction]).

void clearPlaceSelection(WidgetRef ref) {
  ref.read(isSelectionModeProvider.notifier).state = false;
  ref.read(selectedLocationsProvider.notifier).state = {};
}

/// Delete the selection. With [day], a spanning row (an accommodation
/// across the trip) only loses that day; without one the rows go entirely.
Future<void> deleteSelectedPlaces(BuildContext context, WidgetRef ref,
    {DateTime? day}) async {
  final selectedCount = ref.read(selectedLocationsProvider).length;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: Theme.of(context).cardColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text('Delete $selectedCount Locations?'),
      content: const Text(
          'Are you sure you want to permanently delete the selected locations? This action cannot be undone.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text('Cancel',
              style: TextStyle(
                  color: Theme.of(context).textTheme.bodyMedium?.color)),
        ),
        ElevatedButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          style: ElevatedButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  if (confirmed != true) return;
  final ids = ref.read(selectedLocationsProvider);
  final notifier = ref.read(tripProvider.notifier);
  if (day != null) {
    await notifier.removeLocationsFromDay(ids, day);
  } else {
    for (final id in ids) {
      await notifier.removeLocation(id);
    }
  }
  clearPlaceSelection(ref);
}

/// Shared same-day gate for the bulk move/copy — one body so the two
/// can't drift. Returns the ids that may proceed (null = everything
/// blocked; caller bails), toasting whatever was skipped. [copy] uses copy
/// semantics: the source rows COUNT as occupants, so copying a place onto
/// the day it already occupies is blocked.
Set<String>? _dedupeForDay(
  BuildContext context,
  WidgetRef ref,
  Set<String> selectedIds,
  DateTime dayKey, {
  required bool copy,
  required String verb,
}) {
  final pinned = ref.read(tripProvider).pinnedLocations;
  final dup = filterSameDayDuplicates(
    moving:
        pinned.where((l) => selectedIds.contains(l.id)).map(placeKeyOfModel),
    occupantsOnDay: pinned
        .where((l) =>
            (copy || !selectedIds.contains(l.id)) &&
            l.scheduledDate != null &&
            l.isActiveOnDate(dayKey))
        .map(placeKeyOfModel),
  );
  if (dup.allowedIds.isEmpty) {
    if (context.mounted) {
      AppToast.warning(
          context,
          'Already on ${ref.read(activeTripDayLabelerProvider)(dayKey)} — '
          'nothing to $verb.');
    }
    return null;
  }
  if (dup.blockedNames.isNotEmpty && context.mounted) {
    AppToast.info(
        context, 'Skipped ${dup.blockedNames.length} already on that day');
  }
  return dup.allowedIds;
}

/// Day picker for move/copy: the calendar on a dated trip, the numbered
/// day list on a trip without dates yet.
Future<DateTime?> _pickPlanDay(
  BuildContext context,
  WidgetRef ref, {
  required Set<DateTime> highlightedDates,
  required DateTime earliestDate,
}) {
  final labeler = ref.read(activeTripDayLabelerProvider);
  if (labeler.tbd) {
    return showTripDayPicker(
      context,
      days: ref.read(activeTripDayAxisProvider),
      labeler: labeler,
      selected: ref.read(selectedDateProvider),
      marked: highlightedDates,
    );
  }
  return DatePickerUtils.showCustomDatePicker(
    context: context,
    initialDate: ref.read(selectedDateProvider),
    firstDate: earliestDate,
    lastDate: DateTime.now().add(const Duration(days: 365 * 5)),
    highlightedDates: highlightedDates,
    highlightRange: activeTripDateRange(ref),
  );
}

/// Move or copy the selection onto a day the user picks. [promptContext]
/// is the host page's own context: the caller's may belong to a selection
/// bar that unmounts when the selection clears, which would silently skip
/// the accommodation prompt. [followDay] switches the map's day to the
/// target (the plan sheet's habit; the trip page shows every day).
Future<void> _moveOrCopySelectedToDay(
  BuildContext context,
  WidgetRef ref, {
  required bool copy,
  required BuildContext promptContext,
  required bool followDay,
}) async {
  // A copy creates new place rows: an add like any other, so it is Pro.
  if (copy && !await SubscriptionLimitService(ref).canAddPlace(context)) {
    return;
  }
  if (!context.mounted) return;
  final highlightedDates = ref.read(datesWithLocationsProvider);
  final earliestDate = highlightedDates.isNotEmpty
      ? highlightedDates.reduce((a, b) => a.isBefore(b) ? a : b)
      : DateTime.now();

  final newDate = await _pickPlanDay(context, ref,
      highlightedDates: highlightedDates, earliestDate: earliestDate);
  if (newDate == null) return;

  final activeTrip = ref.read(realtimeActiveTripProvider).valueOrNull;
  if (!context.mounted) return;
  final allowed = await ensureScheduledDateAllowed(
    context,
    activeTrip,
    newDate,
    actionLabel: copy ? 'Copy anyway' : 'Move anyway',
  );
  if (!allowed) return;

  final selectedIds = ref.read(selectedLocationsProvider);
  // Captured before the write: landing on a previously-empty day
  // materializes a new trip day → ask about accommodation after.
  final dayKey = DateTime(newDate.year, newDate.month, newDate.day);
  final dayWasEmpty = !ref
      .read(tripProvider)
      .pinnedLocations
      .any((l) => l.isActiveOnDate(dayKey));
  if (!context.mounted) return;
  final allowedIds = _dedupeForDay(context, ref, selectedIds, dayKey,
      copy: copy, verb: copy ? 'copy' : 'move');
  if (allowedIds == null) return;
  final notifier = ref.read(tripProvider.notifier);
  if (copy) {
    await notifier.copyMultipleLocationsToDate(allowedIds, newDate);
  } else {
    await notifier.updateMultipleLocationsScheduledDate(allowedIds, newDate);
  }
  clearPlaceSelection(ref);
  if (followDay) ref.read(selectedDateProvider.notifier).state = newDate;

  if (dayWasEmpty && activeTrip != null && promptContext.mounted) {
    await maybePromptAccommodationForNewDays(
      promptContext,
      ref,
      trip: activeTrip,
      newDays: [dayKey],
    );
  }
}

Future<void> moveSelectedPlacesToDay(BuildContext context, WidgetRef ref,
        {required BuildContext promptContext, bool followDay = false}) =>
    _moveOrCopySelectedToDay(context, ref,
        copy: false, promptContext: promptContext, followDay: followDay);

Future<void> copySelectedPlacesToDay(BuildContext context, WidgetRef ref,
        {required BuildContext promptContext, bool followDay = false}) =>
    _moveOrCopySelectedToDay(context, ref,
        copy: true, promptContext: promptContext, followDay: followDay);

/// "Move to another trip": the picked places leave this trip for one the
/// user chooses (country-guarded, day picked there).
Future<void> moveSelectedPlacesToTrip(
    BuildContext context, WidgetRef ref) async {
  final selectedIds = ref.read(selectedLocationsProvider);
  final picks = ref
      .read(tripProvider)
      .pinnedLocations
      .where((l) => selectedIds.contains(l.id))
      .toList();
  if (picks.isEmpty) return;
  final moved = await showMoveToTripSheet(context, ref, picks);
  if (!moved) return;
  clearPlaceSelection(ref);
}

void markSelectedPlacesDone(WidgetRef ref) {
  final selectedIds = ref.read(selectedLocationsProvider);
  ref.read(tripProvider.notifier).markLocationsAsDone(selectedIds);
  clearPlaceSelection(ref);
}

Future<void> skipSelectedPlaces(BuildContext context, WidgetRef ref) async {
  final selectedCount = ref.read(selectedLocationsProvider).length;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: Theme.of(context).cardColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text('Skip $selectedCount Locations?'),
      content: const Text(
          'Are you sure you want to skip the selected locations? They will be excluded from the route but remain on the map.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text('Cancel',
              style: TextStyle(
                  color: Theme.of(context).textTheme.bodyMedium?.color)),
        ),
        ElevatedButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Skip'),
        ),
      ],
    ),
  );
  if (confirmed != true) return;
  final selectedIds = ref.read(selectedLocationsProvider);
  await ref.read(tripProvider.notifier).skipMultipleLocations(selectedIds);
  clearPlaceSelection(ref);
}

/// The ⋮ menu of a selection bar: Delete, Move to another day, Move to
/// another trip, Skip, Mark as Done, Copy to another day.
Widget buildPlaceSelectionMenu(
  BuildContext context,
  WidgetRef ref, {
  required bool hasWriteAccess,
  required bool canEdit,
  required BuildContext promptContext,
  DateTime? day,
  bool followDay = false,
  Future<void> Function()? beforeAction,
  Color? iconColor,
}) {
  Future<void> run(Future<void> Function() action) async {
    if (beforeAction != null) await beforeAction();
    await action();
  }

  return PopupMenuButton<String>(
    tooltip: 'Actions',
    onSelected: (value) {
      if (!hasWriteAccess && value != 'copy') {
        AppToast.warning(
          context,
          'You don\'t have permission to modify locations in this trip.',
        );
        return;
      }
      switch (value) {
        case 'delete':
          run(() => deleteSelectedPlaces(context, ref, day: day));
        case 'move':
          run(() => moveSelectedPlacesToDay(context, ref,
              promptContext: promptContext, followDay: followDay));
        case 'move_trip':
          run(() => moveSelectedPlacesToTrip(context, ref));
        case 'copy':
          run(() => copySelectedPlacesToDay(context, ref,
              promptContext: promptContext, followDay: followDay));
        case 'skip':
          if (canEdit) run(() => skipSelectedPlaces(context, ref));
        case 'done':
          if (hasWriteAccess) run(() async => markSelectedPlacesDone(ref));
      }
    },
    icon: Icon(Icons.more_vert,
        color: iconColor ?? Theme.of(context).textTheme.bodyMedium?.color),
    itemBuilder: (context) => [
      PopupMenuItem<String>(
        value: 'delete',
        enabled: hasWriteAccess,
        child: ListTile(
          leading: Icon(
            Icons.delete_outline,
            color: hasWriteAccess
                ? Theme.of(context).colorScheme.error
                : Colors.grey,
          ),
          title: Text(
            'Delete',
            style: TextStyle(
                color: hasWriteAccess
                    ? Theme.of(context).colorScheme.error
                    : Colors.grey),
          ),
        ),
      ),
      PopupMenuItem<String>(
        value: 'move',
        enabled: canEdit,
        child: ListTile(
          leading: Icon(Icons.calendar_today_outlined,
              color: canEdit ? null : Colors.grey),
          title: Text('Move to another day',
              style: TextStyle(color: canEdit ? null : Colors.grey)),
        ),
      ),
      PopupMenuItem<String>(
        value: 'move_trip',
        enabled: hasWriteAccess,
        child: ListTile(
          leading: Icon(Icons.luggage_outlined,
              color: hasWriteAccess ? null : Colors.grey),
          title: Text('Move to another trip',
              style: TextStyle(color: hasWriteAccess ? null : Colors.grey)),
        ),
      ),
      PopupMenuItem<String>(
        value: 'skip',
        enabled: canEdit,
        child: ListTile(
          leading: Icon(
            Icons.remove_circle_outline,
            color: canEdit
                ? Theme.of(context).textTheme.bodyMedium?.color
                : Colors.grey,
          ),
          title: Text('Skip',
              style: TextStyle(color: canEdit ? null : Colors.grey)),
        ),
      ),
      PopupMenuItem<String>(
        value: 'done',
        enabled: hasWriteAccess,
        child: ListTile(
          leading: Icon(Icons.check_circle_outline,
              color: hasWriteAccess ? Colors.green : Colors.grey),
          title: Text('Mark as Done',
              style: TextStyle(
                  color: hasWriteAccess ? Colors.green : Colors.grey)),
        ),
      ),
      const PopupMenuItem(
        value: 'copy',
        child: ListTile(
            leading: Icon(Icons.copy), title: Text('Copy to another day')),
      ),
    ],
  );
}
