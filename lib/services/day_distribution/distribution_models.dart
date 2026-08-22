/// Pure-Dart value types for the day-distribution engine. NO Flutter or
/// plugin imports — the engine must run under `compute()` and in plain VM
/// unit tests.
library;

/// One place, reduced to exactly what distribution needs. Built by the
/// provider from SavedLocation/LocationModel; `placeKey` is the same-day
/// duplicate identity string (same_day_place_guard's key, stringified).
class EnginePlace {
  final String id;
  final String name;
  final String placeKey;
  final double lat;
  final double lng;

  /// Stay in minutes as SAVED (0 = user never set one → engine substitutes
  /// [kDefaultStayMinutes]).
  final int stayMinutes;

  /// Local day (y/m/d at midnight) or null = Unscheduled bucket.
  final DateTime? scheduledDay;

  /// Inclusive span end for multi-day stays; null for single-day rows.
  final DateTime? scheduledEndDay;

  final bool isDone;
  final bool isSkipped;
  final bool isAccommodation;

  /// Google-convention weekdays (0=Sun..6=Sat) with any open period; null =
  /// hours unknown, empty = never open (data quirk — treated as unknown).
  final Set<int>? openWeekdays;

  const EnginePlace({
    required this.id,
    required this.name,
    required this.placeKey,
    required this.lat,
    required this.lng,
    this.stayMinutes = 0,
    this.scheduledDay,
    this.scheduledEndDay,
    this.isDone = false,
    this.isSkipped = false,
    this.isAccommodation = false,
    this.openWeekdays,
  });
}

/// A detected city-scale group of places.
class CityCluster {
  final List<EnginePlace> members;
  final double centroidLat;
  final double centroidLng;

  /// Display label, resolved asynchronously AFTER planning (reverse
  /// geocode); the engine leaves it null.
  final String? label;

  const CityCluster({
    required this.members,
    required this.centroidLat,
    required this.centroidLng,
    this.label,
  });

  CityCluster withLabel(String? label) => CityCluster(
        members: members,
        centroidLat: centroidLat,
        centroidLng: centroidLng,
        label: label,
      );
}

/// One planned day of the proposal.
class PlannedDay {
  final DateTime day;

  /// Index into [DistributionPlan.clusterOrder]; -1 for days that carry
  /// only pinned rows outside any surviving cluster.
  final int clusterIndex;

  /// MOVABLE stop ids assigned to this day, in visit (NN) order.
  final List<String> stopIds;

  /// Minutes consumed: stays + estimated travel + inter-city hop.
  final int usedMinutes;

  /// Inter-city hop minutes charged to this day (block's first day).
  final int hopMinutes;

  /// The accommodation active this night, when there is one — it fixed
  /// this day's city and seeds the day's route.
  final String? accommodationId;

  const PlannedDay({
    required this.day,
    required this.clusterIndex,
    required this.stopIds,
    required this.usedMinutes,
    required this.hopMinutes,
    this.accommodationId,
  });
}

enum DistributionWarningKind {
  /// `count` places didn't fit; `minutes` = capacity deficit.
  overflow,

  /// A planned day uses well under the budget.
  lightDay,

  /// A place landed on a weekday its opening hours say it's closed.
  closedOnDay,

  /// A pinned (unmovable) row sits on a day assigned to a different city.
  pinnedMismatch,

  /// A day's stops sit far from that night's accommodation.
  accommodationFar,

  /// A single stop's stay exceeds a whole day's budget.
  longStay,

  /// Under a user place-count cap, a day's stays + travel exceed the time
  /// budget (count ruled; time is advisory). `amount` = minutes.
  overBudgetDay,
}

class DistributionWarning {
  final DistributionWarningKind kind;

  /// The place this warns about, when applicable.
  final String? placeId;

  /// The day this warns about, when applicable.
  final DateTime? day;

  /// overflow: unfitted count. lightDay: used minutes. longStay: stay
  /// minutes. accommodationFar: distance in meters.
  final int? amount;

  const DistributionWarning(this.kind, {this.placeId, this.day, this.amount});
}

/// One proposed change: [newDay] null = move to the Unscheduled bucket.
class PlannedChange {
  final String id;
  final DateTime? oldDay;
  final DateTime? newDay;
  const PlannedChange(this.id, this.oldDay, this.newDay);
}

/// How days are filled when there's room to spare.
enum FillStyle {
  /// Even counts across the days available (14 places / 3 days → 5/5/4).
  balanced,

  /// Fill each day up to the limit first; leftover days stay free
  /// (14 places, limit 8, 3 days → 8/6/free). Requires a limit.
  pack,
}

/// Terminal states that preempt a plan.
enum DistributionGate {
  ok,

  /// Trip has no start/end dates — ask the user to set them first.
  needsTripDates,

  /// Every trip day is in the past — nothing left to plan.
  allDaysPast,

  /// Nothing movable (all done/pinned/empty).
  nothingMovable,
}

class DistributionPlan {
  final DistributionGate gate;
  final List<PlannedDay> perDay;
  final List<PlannedChange> changes;
  final List<String> unscheduledIds;
  final List<CityCluster> clusterOrder;
  final List<DistributionWarning> warnings;

  /// Editable trip days the plan leaves EMPTY (pack style spares them).
  final List<DateTime> freeDays;

  /// Fingerprint of the input rows — apply-time staleness check.
  final String inputFingerprint;

  const DistributionPlan({
    required this.gate,
    this.perDay = const [],
    this.changes = const [],
    this.unscheduledIds = const [],
    this.clusterOrder = const [],
    this.warnings = const [],
    this.freeDays = const [],
    this.inputFingerprint = '',
  });

  bool get isNoOp => gate == DistributionGate.ok && changes.isEmpty;

  DistributionPlan withClusterOrder(List<CityCluster> labeled) =>
      DistributionPlan(
        gate: gate,
        perDay: perDay,
        changes: changes,
        unscheduledIds: unscheduledIds,
        clusterOrder: labeled,
        warnings: warnings,
        freeDays: freeDays,
        inputFingerprint: inputFingerprint,
      );
}

/// Everything the engine needs — assembled by the provider so the engine
/// itself never touches Riverpod, Hive, or the clock.
class DistributionInput {
  final List<EnginePlace> places;
  final DateTime? tripStart;
  final DateTime? tripEnd;

  /// Local today (y/m/d) — passed in for determinism/testability.
  final DateTime today;

  /// 'auto' | 'walk' | 'transit' | 'drive' (LegModePrefs.travelProfile).
  final String travelStyle;

  /// User's hard cap on places per day (null = capacity-only). A day never
  /// receives more than this many MOVABLE stops, and day quotas grow to
  /// fit `count / cap` days per city.
  final int? maxStopsPerDay;

  /// Balanced (default) or pack-to-the-limit. Pack is only meaningful with
  /// a cap; without one it behaves as balanced.
  final FillStyle fillStyle;

  /// true (default): minimal disruption — a place stays on its current day
  /// whenever that day belongs to its city block and has room. false:
  /// plan from scratch — the engine proposes its ideal arrangement
  /// (geographic grouping per day, balanced counts) regardless of where
  /// places sit today.
  final bool keepCurrentDays;

  final String fingerprint;

  const DistributionInput({
    required this.places,
    required this.tripStart,
    required this.tripEnd,
    required this.today,
    this.travelStyle = 'auto',
    this.maxStopsPerDay,
    this.fillStyle = FillStyle.balanced,
    this.keepCurrentDays = true,
    this.fingerprint = '',
  });
}
