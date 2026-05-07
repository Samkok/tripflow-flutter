import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/timing_simulation.dart';
import 'map_ui_state_provider.dart';
import 'trip_provider.dart';

/// User-supplied "Start at" time for the optimized plan. `null` means
/// "use the computed default for the selected date" — see
/// [effectiveTripStartTimeProvider]. Set this when the user picks a time
/// from the optimize dialog; the simulation reacts automatically.
///
/// MVP scope: not persisted across app launches. The override is reset
/// implicitly when the app restarts. Persistence-per-trip is a follow-up.
final tripStartTimeOverrideProvider = StateProvider<TimeOfDay?>((ref) => null);

/// Wall-clock start time for the simulation. Combines the selected date
/// with either the user override or a sensible default:
///   - selected date is today → now, rounded down to the nearest 15 min,
///     so the picker label shows a clean value the user can recognize.
///   - selected date is in the future → 09:00.
///   - selected date is in the past → 09:00 (the optimizer is hidden in
///     that case anyway, so this is just a safe fallback).
final effectiveTripStartTimeProvider = Provider<DateTime>((ref) {
  final selectedDate = ref.watch(selectedDateProvider);
  final override = ref.watch(tripStartTimeOverrideProvider);

  TimeOfDay resolved;
  if (override != null) {
    resolved = override;
  } else {
    final now = DateTime.now();
    final isToday = selectedDate.year == now.year &&
        selectedDate.month == now.month &&
        selectedDate.day == now.day;
    if (isToday) {
      resolved =
          TimeOfDay(hour: now.hour, minute: (now.minute ~/ 15) * 15);
    } else {
      resolved = const TimeOfDay(hour: 9, minute: 0);
    }
  }

  return DateTime(
    selectedDate.year,
    selectedDate.month,
    selectedDate.day,
    resolved.hour,
    resolved.minute,
  );
});

/// Closing-time-aware simulation of the currently-optimized plan. Returns
/// `null` until there's an optimized route to evaluate so consumers can
/// distinguish "not run yet" from "ran, no warnings."
///
/// Skipped/done locations are filtered out before simulating — the optimizer
/// already excludes them from the route, so the leg-vs-stop indices stay
/// aligned with [TripState.legDetails].
final tripSimulationProvider = Provider<TimingSimulationResult?>((ref) {
  final ordered = ref.watch(
      tripProvider.select((s) => s.optimizedLocationsForSelectedDate));
  if (ordered.isEmpty) return null;

  final routable = ordered.where((s) => !s.isSkipped && !s.isDone).toList();
  if (routable.isEmpty) return null;

  final legDetails = ref.watch(tripProvider.select((s) => s.legDetails));
  final startWall = ref.watch(effectiveTripStartTimeProvider);

  return simulateTrip(
    startWallTime: startWall,
    orderedStops: routable,
    legDetails: legDetails,
  );
});

/// Per-stop warnings indexed by `locationId` for cheap O(1) lookup from
/// [OptimizedLocationCard]'s badge. Empty map when no simulation has run
/// or every stop is feasible.
final stopWarningsProvider =
    Provider<Map<String, List<TimingWarning>>>((ref) {
  final result = ref.watch(tripSimulationProvider);
  if (result == null) return const {};
  return {
    for (final s in result.stops)
      if (s.warnings.isNotEmpty) s.locationId: s.warnings,
  };
});
