/// Tuning constants for the day-distribution engine. Every value is a
/// heuristic with a rationale — change deliberately, and keep the engine
/// tests' expectations in sync.
library;

/// Straight-line clustering threshold that separates "same city" from
/// "different base": intra-metro attraction spread tops out around 15 km
/// (Taipei, Osaka, Bangkok) while nearest-attraction gaps between distinct
/// bases start around 30 km (Tainan↔Kaohsiung ~35 km). 30-40 km would
/// single-link-chain adjacent metros (Kansai) into one blob.
const double kCityClusterThresholdMeters = 20000;

/// A cluster with less than this much content (stay minutes) and no
/// pinned-dated member is a day-trip satellite (Jiufen, a lone viewpoint):
/// it merges into its tour-order neighbor instead of owning days.
const int kSatelliteMaxLoadMinutes = 180;

/// …but only when that neighbor is within reach for a day trip.
const double kSatelliteAbsorbMaxMeters = 50000;

/// Sightseeing budget per day: a 9-10 h tourist day minus ~1 h of meals
/// that stayDuration doesn't represent.
const int kDayBudgetMinutes = 510;

/// Stops saved with no stay duration (the model default is 0) count as a
/// typical attraction visit.
const int kDefaultStayMinutes = 90;

/// Roads are longer than crow flight — standard urban detour ratio.
const double kDetourFactor = 1.35;

/// Door-to-door speeds (km/h) per travel style for intra-city hops.
/// Transit includes typical wait; drive is urban traffic, not highway.
const double kWalkKmh = 4.5;
const double kTransitKmh = 20;
const double kDriveKmh = 30;

/// In 'auto'/'transit' styles, hops under this are walked (mirrors the
/// router's transitFromMeters=1200 ladder).
const double kAutoWalkUnderMeters = 1200;

/// Inter-city hop (charged to each city block's first day): centroid
/// distance × detour ÷ intercity speed, clamped to something believable
/// for rail/highway travel.
const double kIntercityDetourFactor = 1.3;
const double kIntercityKmh = 60;
const int kIntercityHopMinMinutes = 45;
const int kIntercityHopMaxMinutes = 300;

/// A day using less than this is flagged light (40% of the budget).
const int kLightDayMinutes = 204;

/// An assigned day whose stops sit farther than this from that night's
/// accommodation gets a warning (we never move accommodations in v1).
const double kAccommodationFarMeters = 25000;

/// Above this many places the provider runs the engine in an isolate.
const int kIsolateThresholdPlaces = 40;

/// Held-Karp is exact up to this many clusters (2^12·12² ≈ 6·10⁵ ops);
/// beyond it (pathological trips) fall back to nearest-neighbor + 2-opt.
const int kExactTspMaxClusters = 12;

/// A night's accommodation anchors its day to the nearest city cluster
/// only within this radius — a hotel nowhere near any saved place (wrong
/// pin, airport stopover) must not hijack a day.
const double kAccommodationHomeMaxMeters = 60000;

/// Under a user place-count cap, a day is flagged "packed" only when it
/// overshoots the time budget by more than this (small overruns are the
/// user's call).
const int kOverBudgetToleranceMinutes = 60;
