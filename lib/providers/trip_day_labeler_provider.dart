import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../utils/trip_day_labels.dart';
import 'trip_listener_provider.dart';

/// Day labels for the ACTIVE trip (map screen, trip-plan sheet, cards,
/// detail sheet). Falls back to calendar dates when no trip is active.
final activeTripDayLabelerProvider = Provider<DayLabeler>((ref) {
  final trip = ref.watch(realtimeActiveTripProvider).valueOrNull;
  return DayLabeler.forTrip(trip);
});
