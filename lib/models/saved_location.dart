import 'package:hive/hive.dart';

part 'saved_location.g.dart';

/// One contiguous open→close interval for a place, mirroring a single entry
/// in Google Places `regular_opening_hours.periods`. Days follow Google's
/// convention: 0 = Sunday … 6 = Saturday (NOT Dart's `DateTime.weekday`).
/// Times are stored as minutes since midnight on [openDay] / [closeDay] so
/// comparisons and arithmetic don't need TimeOfDay around.
///
/// A 24/7 place is represented by a single period with [closeDay] and
/// [closeMinutes] both null. After-midnight closes (bar closes 02:00) are
/// represented by [closeDay] = openDay + 1 (mod 7).
@HiveType(typeId: 2)
class OpeningPeriod {
  @HiveField(0)
  final int openDay;
  @HiveField(1)
  final int openMinutes;
  @HiveField(2)
  final int? closeDay;
  @HiveField(3)
  final int? closeMinutes;

  const OpeningPeriod({
    required this.openDay,
    required this.openMinutes,
    this.closeDay,
    this.closeMinutes,
  });

  bool get isAlwaysOpen => closeDay == null && closeMinutes == null;

  Map<String, dynamic> toJson() => {
        'open_day': openDay,
        'open_minutes': openMinutes,
        'close_day': closeDay,
        'close_minutes': closeMinutes,
      };

  factory OpeningPeriod.fromJson(Map<String, dynamic> json) => OpeningPeriod(
        openDay: json['open_day'] as int,
        openMinutes: json['open_minutes'] as int,
        closeDay: json['close_day'] as int?,
        closeMinutes: json['close_minutes'] as int?,
      );
}

@HiveType(typeId: 1)
class SavedLocation extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  final String userId;

  @HiveField(2)
  final String name;

  @HiveField(3)
  final double lat;

  @HiveField(4)
  final double lng;

  @HiveField(5)
  final DateTime createdAt;

  @HiveField(6)
  final DateTime? lastSyncedAt;

  @HiveField(7)
  final bool isSynced;

  @HiveField(8)
  final String source; // 'local' or 'synced'

  @HiveField(9)
  final String fingerprint;

  @HiveField(10)
  final bool isSkipped;

  @HiveField(11)
  final int stayDuration; // in seconds

  @HiveField(12)
  final DateTime? scheduledDate;

  @HiveField(13)
  final String? tripId; // UUID of associated trip

  @HiveField(14)
  final String? photoReference;

  @HiveField(15)
  final List<String>? photoAttributions;

  @HiveField(16)
  final bool isDone;

  /// Up to 5 photo references for the in-card gallery. The first item is
  /// also stored in [photoReference] for back-compat with older clients.
  @HiveField(17)
  final List<String>? photoReferences;

  /// Google Places `place_id` for this location, captured at add time when
  /// the place came from a Places API result (search, nearby, reverse
  /// geocode). Null for older rows and for the manual-coord add path.
  /// When present, used to anchor external-app handoff (Google Maps, Grab)
  /// to the exact place rather than a coordinate, which avoids name-search
  /// ambiguity for renamed entries.
  @HiveField(18)
  final String? placeId;

  /// The Google place name as returned by the Places API at add time. We
  /// keep this separate from [name] so that even after a user edits the
  /// in-app label, we still have the canonical name to send to external
  /// apps. Null for older rows and rows that never had a Places result.
  @HiveField(19)
  final String? originalName;

  /// Per-day opening periods captured from Google Places at add time (or
  /// last refresh). Null for places with no hours data and for older rows
  /// captured before this column existed. Read-only — never overwritten by
  /// user edits; the user-facing override lives in [userClosingMinuteOverride].
  @HiveField(20)
  final List<OpeningPeriod>? googleOpeningHours;

  /// User-supplied closing time, in minutes since midnight (0–1439). When
  /// set, the optimizer's timing simulation treats this as the effective
  /// closing time regardless of what Google says — useful when the user
  /// knows local hours better, or wants a self-imposed cutoff. Null means
  /// "use Google's hours."
  @HiveField(21)
  final int? userClosingMinuteOverride;

  /// When [googleOpeningHours] was last fetched. Surfaced in the UI as
  /// "last refreshed N days ago" so users know whether to refresh before
  /// trusting the warnings.
  @HiveField(22)
  final DateTime? hoursLastRefreshedAt;

  /// Last day this location is "active" on the trip — inclusive, paired with
  /// [scheduledDate] as the start. Lets the user mark a hotel/accommodation
  /// as spanning multiple days so it appears on every day in `[start..end]`.
  /// Null means single-day (legacy behavior). When non-null, must be
  /// on-or-after [scheduledDate].
  @HiveField(23)
  final DateTime? scheduledEndDate;

  /// True when this location is the accommodation (hotel/stay) for the
  /// day(s) it spans. Business rule: at most ONE accommodation per trip-day —
  /// enforced client-side with a replace flow and by the DB exclusion
  /// constraint `locations_one_accommodation_per_day`.
  @HiveField(24, defaultValue: false)
  final bool isAccommodation;

  SavedLocation({
    required this.id,
    required this.userId,
    required this.name,
    required this.lat,
    required this.lng,
    required this.createdAt,
    this.lastSyncedAt,
    this.isSynced = false,
    this.source = 'local',
    required this.fingerprint,
    this.isSkipped = false,
    this.isDone = false,
    this.stayDuration = 0,
    this.scheduledDate,
    this.tripId,
    this.photoReference,
    this.photoReferences,
    this.photoAttributions,
    this.placeId,
    this.originalName,
    this.googleOpeningHours,
    this.userClosingMinuteOverride,
    this.hoursLastRefreshedAt,
    this.scheduledEndDate,
    this.isAccommodation = false,
  });

  /// Effective gallery list: prefers [photoReferences]; falls back to a
  /// single-item list built from [photoReference] for rows written by older
  /// clients.
  List<String> get effectivePhotoReferences {
    if (photoReferences != null && photoReferences!.isNotEmpty) {
      return photoReferences!;
    }
    if (photoReference != null && photoReference!.isNotEmpty) {
      return [photoReference!];
    }
    return const [];
  }

  // Sentinel used to distinguish "caller passed null" from "caller omitted the param".
  // Required because `param ?? this.field` silently ignores an explicit null.
  static const _unset = Object();

  SavedLocation copyWith({
    String? id,
    String? userId,
    String? name,
    double? lat,
    double? lng,
    DateTime? createdAt,
    DateTime? lastSyncedAt,
    bool? isSynced,
    String? source,
    String? fingerprint,
    bool? isSkipped,
    bool? isDone,
    int? stayDuration,
    DateTime? scheduledDate,
    Object? tripId = _unset,
    String? photoReference,
    List<String>? photoReferences,
    List<String>? photoAttributions,
    String? placeId,
    String? originalName,
    List<OpeningPeriod>? googleOpeningHours,
    Object? userClosingMinuteOverride = _unset,
    DateTime? hoursLastRefreshedAt,
    Object? scheduledEndDate = _unset,
    bool? isAccommodation,
  }) {
    return SavedLocation(
      id: id ?? this.id,
      userId: userId ?? this.userId,
      name: name ?? this.name,
      lat: lat ?? this.lat,
      lng: lng ?? this.lng,
      createdAt: createdAt ?? this.createdAt,
      lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
      isSynced: isSynced ?? this.isSynced,
      source: source ?? this.source,
      fingerprint: fingerprint ?? this.fingerprint,
      isSkipped: isSkipped ?? this.isSkipped,
      isDone: isDone ?? this.isDone,
      stayDuration: stayDuration ?? this.stayDuration,
      scheduledDate: scheduledDate ?? this.scheduledDate,
      tripId: identical(tripId, _unset) ? this.tripId : tripId as String?,
      photoReference: photoReference ?? this.photoReference,
      photoReferences: photoReferences ?? this.photoReferences,
      photoAttributions: photoAttributions ?? this.photoAttributions,
      placeId: placeId ?? this.placeId,
      originalName: originalName ?? this.originalName,
      googleOpeningHours: googleOpeningHours ?? this.googleOpeningHours,
      userClosingMinuteOverride: identical(userClosingMinuteOverride, _unset)
          ? this.userClosingMinuteOverride
          : userClosingMinuteOverride as int?,
      hoursLastRefreshedAt: hoursLastRefreshedAt ?? this.hoursLastRefreshedAt,
      scheduledEndDate: identical(scheduledEndDate, _unset)
          ? this.scheduledEndDate
          : scheduledEndDate as DateTime?,
      isAccommodation: isAccommodation ?? this.isAccommodation,
    );
  }

  factory SavedLocation.fromJson(Map<String, dynamic> json) {
    final refs = json['photo_references'];
    return SavedLocation(
      id: json['id'],
      userId: json['user_id'] ?? '',
      name: json['name'],
      lat: (json['lat'] as num).toDouble(),
      lng: (json['lng'] as num).toDouble(),
      createdAt: DateTime.parse(json['created_at']),
      lastSyncedAt: json['last_synced_at'] != null
          ? DateTime.parse(json['last_synced_at'])
          : null,
      isSynced: json['is_synced'] ?? true, // Assume synced if from remote
      source: json['source'] ?? 'synced',
      fingerprint: json['fingerprint'] ?? '',
      isSkipped: json['is_skipped'] ?? false,
      isDone: json['is_done'] ?? false,
      stayDuration: json['stay_duration'] ?? 0,
      scheduledDate: json['scheduled_date'] != null
          ? DateTime.parse(json['scheduled_date'])
          : null,
      tripId: json['trip_id'],
      photoReference: json['photo_reference'],
      photoReferences: refs is List ? List<String>.from(refs) : null,
      photoAttributions: json['photo_attributions'] != null
          ? List<String>.from(json['photo_attributions'])
          : null,
      placeId: json['place_id'] as String?,
      originalName: json['original_name'] as String?,
      googleOpeningHours: (json['google_opening_hours'] as List?)
          ?.map((e) => OpeningPeriod.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      userClosingMinuteOverride: json['user_closing_minute_override'] as int?,
      hoursLastRefreshedAt: json['hours_last_refreshed_at'] != null
          ? DateTime.parse(json['hours_last_refreshed_at'])
          : null,
      scheduledEndDate: json['scheduled_end_date'] != null
          ? DateTime.parse(json['scheduled_end_date'])
          : null,
      isAccommodation: json['is_accommodation'] ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'user_id': userId,
      'trip_id': tripId,
      'name': name,
      'lat': lat,
      'lng': lng,
      'created_at': createdAt.toIso8601String(),
      'last_synced_at': lastSyncedAt?.toIso8601String(),
      'is_synced': isSynced,
      'source': source,
      'fingerprint': fingerprint,
      'is_skipped': isSkipped,
      'is_done': isDone,
      'stay_duration': stayDuration,
      // Calendar day, never a timestamp: a raw now() slipping in here once
      // stranded rows under phantom dates (Hong Kong trip, Jul 2026).
      'scheduled_date': scheduledDate == null
          ? null
          : DateTime(
                  scheduledDate!.year, scheduledDate!.month, scheduledDate!.day)
              .toIso8601String(),
      'photo_reference': photoReference,
      'photo_references': photoReferences,
      'photo_attributions': photoAttributions,
      'place_id': placeId,
      'original_name': originalName,
      'google_opening_hours':
          googleOpeningHours?.map((p) => p.toJson()).toList(),
      'user_closing_minute_override': userClosingMinuteOverride,
      'hours_last_refreshed_at': hoursLastRefreshedAt?.toIso8601String(),
      'scheduled_end_date': scheduledEndDate == null
          ? null
          : DateTime(scheduledEndDate!.year, scheduledEndDate!.month,
                  scheduledEndDate!.day)
              .toIso8601String(),
      'is_accommodation': isAccommodation,
    };
  }

  /// True when [day] falls within this location's active range, inclusive
  /// on both ends. For single-day rows (no [scheduledEndDate]) returns true
  /// only on the matching day; for legacy rows with no [scheduledDate] at
  /// all, falls back to [createdAt] so they still appear somewhere.
  bool isActiveOnDate(DateTime day) {
    final startRaw = scheduledDate ?? createdAt;
    final start = DateTime(startRaw.year, startRaw.month, startRaw.day);
    final endRaw = scheduledEndDate ?? startRaw;
    final end = DateTime(endRaw.year, endRaw.month, endRaw.day);
    final target = DateTime(day.year, day.month, day.day);
    return !target.isBefore(start) && !target.isAfter(end);
  }

  /// True iff the location explicitly spans more than one day.
  bool get isMultiDay {
    if (scheduledEndDate == null || scheduledDate == null) return false;
    final s =
        DateTime(scheduledDate!.year, scheduledDate!.month, scheduledDate!.day);
    final e = DateTime(
        scheduledEndDate!.year, scheduledEndDate!.month, scheduledEndDate!.day);
    return e.isAfter(s);
  }
}
