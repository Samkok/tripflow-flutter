import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/city_label_service.dart';
import '../services/day_distribution/day_distribution_engine.dart';
import '../services/day_distribution/distribution_constants.dart';
import '../services/day_distribution/distribution_models.dart';
import '../services/day_distribution/model_bridge.dart';
import '../services/leg_mode_prefs.dart';
import 'trip_listener_provider.dart';
import 'trip_provider.dart';

/// The sheet's live "places per day" choice (null = Auto). Seeded from
/// [LegModePrefs.autoPlanMaxStops] when the sheet opens; changes recompute
/// the plan instantly and persist back.
final autoPlanMaxStopsProvider = StateProvider<int?>((ref) => null);

/// Balanced vs pack-to-the-limit (see [FillStyle]); seeded from prefs.
final autoPlanFillStyleProvider =
    StateProvider<FillStyle>((ref) => FillStyle.balanced);

/// "Keep places on their current days when possible" — session-scoped
/// intent, reset to true each time the sheet opens.
final autoPlanKeepCurrentProvider = StateProvider<bool>((ref) => true);

/// Trip date range to plan against, when it's known to be fresher than
/// what [realtimeActiveTripProvider] currently holds — "Add a day" inside
/// the sheet writes the new range here the moment it's persisted, so the
/// recompute doesn't race the trip's async reload. Cleared on sheet open.
final autoPlanRangeOverrideProvider =
    StateProvider<({DateTime start, DateTime end})?>((ref) => null);

/// Arrival and departure times to plan against, when they were just changed
/// from inside the sheet — same reason as the range override: the plan must
/// follow the new times at once, not when the trip's reload lands. Minutes
/// after midnight, null = not set. Cleared on sheet open.
final autoPlanTimesOverrideProvider =
    StateProvider<({int? arrival, int? departure})?>((ref) => null);

/// Computes an Auto-plan proposal for the ACTIVE trip. autoDispose: every
/// sheet-open recomputes against live data (the plan carries a fingerprint
/// so applying re-validates anyway). Pure local work + zero API calls —
/// safe to run for free users (preview is free; APPLY is gated).
final autoPlanProvider =
    FutureProvider.autoDispose<DistributionPlan>((ref) async {
  final trip = ref.watch(realtimeActiveTripProvider).valueOrNull;
  final locations = ref.watch(tripProvider.select((s) => s.pinnedLocations));

  final maxStops = ref.watch(autoPlanMaxStopsProvider);
  final fillStyle = ref.watch(autoPlanFillStyleProvider);
  final keepCurrent = ref.watch(autoPlanKeepCurrentProvider);
  final rangeOverride = ref.watch(autoPlanRangeOverrideProvider);
  final timesOverride = ref.watch(autoPlanTimesOverrideProvider);

  final routingTripId = trip?.id ?? 'no_trip';
  final travelStyle = await LegModePrefs.travelProfile(routingTripId);

  final input = DistributionInput(
    places: [for (final l in locations) toEnginePlace(l)],
    tripStart: rangeOverride?.start ?? trip?.startDate,
    tripEnd: rangeOverride?.end ?? trip?.endDate,
    today: DateTime.now(),
    travelStyle: travelStyle,
    maxStopsPerDay: maxStops,
    fillStyle: fillStyle,
    keepCurrentDays: keepCurrent,
    arrivalMinute:
        timesOverride != null ? timesOverride.arrival : trip?.arrivalMinute,
    departureMinute:
        timesOverride != null ? timesOverride.departure : trip?.departureMinute,
    // Numbered days have no weekday: no "closed on Mondays" guesses.
    weekdaysKnown: !(trip?.isUndated ?? false),
    fingerprint: distributionFingerprint(locations),
  );

  final plan = input.places.length > kIsolateThresholdPlaces
      ? await compute(computePlan, input)
      : computePlan(input);
  return plan;
});

/// Display label for a cluster centroid — reverse-geocoded, Hive-cached,
/// null when offline/unknown (callers show "Around <place>" instead).
final clusterLabelProvider =
    FutureProvider.family<String?, ({double lat, double lng})>(
        (ref, c) => CityLabelService.instance.labelFor(c.lat, c.lng));
