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
/// with either the user override or — by default — the device's current
/// time of day, rounded down to the nearest 15 min. The "Start at" picker
/// matches what's on the user's clock the moment they open the modal,
/// regardless of which day is selected. If they want a different anchor
/// they pick one explicitly (writes [tripStartTimeOverrideProvider]).
final effectiveTripStartTimeProvider = Provider<DateTime>((ref) {
  final selectedDate = ref.watch(selectedDateProvider);
  final override = ref.watch(tripStartTimeOverrideProvider);

  final TimeOfDay resolved;
  if (override != null) {
    resolved = override;
  } else {
    final now = DateTime.now();
    resolved = TimeOfDay(hour: now.hour, minute: (now.minute ~/ 15) * 15);
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
  // Past dates are read-only and the day's hours no longer matter.
  // Skip the simulation entirely so warnings/badges/sheets don't appear
  // for trips the user is just reviewing.
  final selectedDate = ref.watch(selectedDateProvider);
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final selectedDay =
      DateTime(selectedDate.year, selectedDate.month, selectedDate.day);
  if (selectedDay.isBefore(today)) return null;

  // Point-to-point previews ("route from A to B") aren't a plan for the
  // day — timing warnings there are noise, so no simulation runs at all.
  if (ref.watch(tripProvider.select((s) => s.isRoutePreview))) return null;

  final ordered = ref
      .watch(tripProvider.select((s) => s.optimizedLocationsForSelectedDate));
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

/// Stop IDs whose timing warning the user has explicitly accepted via
/// "Go anyway" in [TimingWarningsSheet]. The sheet-trigger listener
/// filters these out before deciding whether to re-open the sheet —
/// without this filter the re-optimize call inside `_confirm` would
/// land with the same warnings still present and the sheet would
/// re-open immediately, looping. Cleared when the user manually taps
/// the Optimize button (a fresh planning attempt should start with no
/// prior acknowledgements).
final acknowledgedTimingWarningsProvider =
    StateProvider<Set<String>>((ref) => const {});

/// Per-stop warnings indexed by `locationId` for cheap O(1) lookup from
/// [OptimizedLocationCard]'s badge. Empty map when no simulation has run
/// or every stop is feasible.
final stopWarningsProvider = Provider<Map<String, List<TimingWarning>>>((ref) {
  final result = ref.watch(tripSimulationProvider);
  if (result == null) return const {};
  return {
    for (final s in result.stops)
      if (s.warnings.isNotEmpty) s.locationId: s.warnings,
  };
});
