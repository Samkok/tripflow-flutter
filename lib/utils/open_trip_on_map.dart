import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/trip.dart';
import '../providers/all_days_route_provider.dart';
import '../providers/local_active_trip_provider.dart';
import '../providers/location_provider.dart';
import '../providers/map_ui_state_provider.dart';
import '../providers/onboarding_checklist_provider.dart';
import '../providers/onboarding_provider.dart';
import '../providers/trip_provider.dart';

/// Index of the Map tab on the home screen.
const int mapTabIndex = 1;

/// Makes [trip] the trip the map draws. The map shows one trip at a time:
/// the one last opened on it, or last edited from its page. Returns true
/// when the map trip actually changed.
///
/// The previous trip's pins and route leave `TripNotifier` at once; the new
/// trip's pins arrive through the locations stream (it restarts on the id).
/// Checklist step 3 is the same moment, recorded silently.
Future<bool> setMapTrip(WidgetRef ref, Trip trip) async {
  if (ref.read(localActiveTripIdProvider) == trip.id) return false;
  ref.read(tripProvider.notifier).clearTrip();
  await ref.read(localActiveTripIdProvider.notifier).setActiveTrip(trip.id);
  await ref
      .read(checklistProvider.notifier)
      .mark(ChecklistStep.activateTrip, silent: true);
  return true;
}

/// [setMapTrip], then the landing day and the Map tab.
Future<void> openTripOnMap(WidgetRef ref, Trip trip, {DateTime? now}) async {
  await setMapTrip(ref, trip);
  requestMapForTrip(ref, trip, now: now);
}

/// For an action that goes through `TripNotifier` (every place mutation,
/// Plan): makes [trip] the map trip and, when that switched it, waits for
/// its pins to land so the action sees them. Bounded: an empty trip has
/// nothing to wait for, and a stalled stream gives up after two seconds.
Future<void> ensureMapTrip(WidgetRef ref, Trip trip) async {
  if (!await setMapTrip(ref, trip)) return;
  bool hasPins(TripState s) =>
      s.pinnedLocations.any((l) => l.tripId == trip.id);
  if (hasPins(ref.read(tripProvider))) return;
  final rows = ref.read(savedLocationsProvider).valueOrNull;
  if (rows != null && !rows.any((r) => r.tripId == trip.id)) return;
  try {
    await ref
        .read(tripProvider.notifier)
        .stream
        .firstWhere(hasPins)
        .timeout(const Duration(seconds: 2));
  } on TimeoutException {
    // Carry on; whatever watches the pins recomputes when they land.
  }
}

/// Points the map at [trip]'s most useful day and asks the home screen for
/// the Map tab. The trip must already be the one on the map.
///
/// An ONGOING trip (today inside its dates) lands on today, the day being
/// lived; a trip that has not started, has ended, or has no end date lands
/// on day one. A trip without a start date keeps whatever day the map had.
void requestMapForTrip(WidgetRef ref, Trip trip, {DateTime? now}) {
  final day = mapLandingDayFor(trip, now: now);
  if (day != null) {
    ref.read(allDaysModeProvider.notifier).state = false;
    ref.read(selectedDateProvider.notifier).state = day;
  }
  ref.read(mainTabRequestProvider.notifier).state = mapTabIndex;
}

/// The day the map should open on for [trip]; null when the trip has no
/// start date.
DateTime? mapLandingDayFor(Trip trip, {DateTime? now}) {
  final start = trip.startDate;
  if (start == null) return null;
  final startDay = DateTime(start.year, start.month, start.day);
  final end = trip.endDate;
  final clock = now ?? DateTime.now();
  final today = DateTime(clock.year, clock.month, clock.day);
  final ongoing = end != null &&
      !today.isBefore(startDay) &&
      !today.isAfter(DateTime(end.year, end.month, end.day));
  return ongoing ? today : startDay;
}
