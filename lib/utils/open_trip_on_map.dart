import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/trip.dart';
import '../providers/all_days_route_provider.dart';
import '../providers/map_ui_state_provider.dart';
import '../providers/onboarding_provider.dart';

/// Index of the Map tab on the home screen.
const int mapTabIndex = 1;

/// Points the map at [trip]'s most useful day and asks the home screen for
/// the Map tab. The trip must already be the active one — the map draws the
/// active trip.
///
/// An ONGOING trip (today inside its dates) lands on today, the day being
/// lived; a trip that has not started, has ended, or has no end date lands
/// on day one. A trip without a start date keeps whatever day the map had.
void requestMapForTrip(WidgetRef ref, Trip trip, {DateTime? now}) {
  final day = mapLandingDayFor(trip, now: now);
  if (day != null) {
    ref.read(allDaysModeProvider.notifier).state = false;
    ref.read(selectedDateProvider.notifier).state = day;
    // Nudge the trip sheet onto the "Selected Day" toggle so the landing
    // actually shows that day (the toggle otherwise keeps its last state).
    ref.read(mapDayFocusRequestProvider.notifier).state++;
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
