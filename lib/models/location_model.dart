import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:voyza/models/saved_location.dart';

class LocationModel {
  final String id;
  final String name;
  final String address;
  final LatLng coordinates;
  final DateTime addedAt;
  final Duration? travelTimeFromPrevious;
  final double? distanceFromPrevious;
  final DateTime? scheduledDate;
  final Duration stayDuration;
  final bool isSkipped;
  final bool isDone;

  /// Cover photo reference. Equal to the first item of [photoReferences]
  /// when any photos are present.
  final String? photoReference;

  /// Up to 5 photo references for the in-card gallery.
  final List<String> photoReferences;
  final List<String>? photoAttributions;

  /// Google Places place_id. See [SavedLocation.placeId] — used for the
  /// external-app handoff so renamed entries still resolve to the exact
  /// Google place.
  final String? placeId;

  /// Original Google name at add time. Preserved across in-app renames so
  /// external handoff doesn't lose the canonical label.
  final String? originalName;

  /// Per-day opening periods. See [SavedLocation.googleOpeningHours].
  final List<OpeningPeriod>? googleOpeningHours;

  /// User-supplied closing time, in minutes since midnight (0–1439).
  /// See [SavedLocation.userClosingMinuteOverride].
  final int? userClosingMinuteOverride;

  /// When [googleOpeningHours] was last fetched.
  final DateTime? hoursLastRefreshedAt;

  /// Last day this location is active on the trip — inclusive, paired with
  /// [scheduledDate]. Null = single-day stop (default). When set, the
  /// location appears on every day in `[scheduledDate..scheduledEndDate]`.
  final DateTime? scheduledEndDate;

  /// Trip id this location is attached to (null = unassigned). Mirrors
  /// [SavedLocation.tripId] and propagates through the sync listener so
  /// UIs (e.g. the "Remove from trip" affordance in LocationDetailSheet)
  /// can read it without doing their own Hive lookup.
  final String? tripId;

  /// True when this location is the accommodation for the day(s) it spans.
  /// Mirrors [SavedLocation.isAccommodation]; at most one per trip-day.
  final bool isAccommodation;

  LocationModel({
    required this.id,
    required this.name,
    required this.address,
    required this.coordinates,
    required this.addedAt,
    this.travelTimeFromPrevious,
    this.distanceFromPrevious,
    this.stayDuration = const Duration(minutes: 30),
    this.isSkipped = false,
    this.isDone = false,
    this.scheduledDate,
    this.photoReference,
    List<String>? photoReferences,
    this.photoAttributions,
    this.placeId,
    this.originalName,
    this.googleOpeningHours,
    this.userClosingMinuteOverride,
    this.hoursLastRefreshedAt,
    this.scheduledEndDate,
    this.tripId,
    this.isAccommodation = false,
  }) : photoReferences = photoReferences ??
            (photoReference != null && photoReference.isNotEmpty
                ? [photoReference]
                : const []);

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'address': address,
      'latitude': coordinates.latitude,
      'longitude': coordinates.longitude,
      'addedAt': addedAt.toIso8601String(),
      'travelTimeFromPreviousSeconds': travelTimeFromPrevious?.inSeconds,
      'distanceFromPrevious': distanceFromPrevious,
      'stayDurationSeconds': stayDuration.inSeconds,
      'scheduledDate': scheduledDate?.toIso8601String(),
      'isSkipped': isSkipped,
      'isDone': isDone,
      'photoReference': photoReference,
      'photoReferences': photoReferences,
      'photoAttributions': photoAttributions,
      'placeId': placeId,
      'originalName': originalName,
      'googleOpeningHours': googleOpeningHours?.map((p) => p.toJson()).toList(),
      'userClosingMinuteOverride': userClosingMinuteOverride,
      'hoursLastRefreshedAt': hoursLastRefreshedAt?.toIso8601String(),
      'scheduledEndDate': scheduledEndDate?.toIso8601String(),
      'tripId': tripId,
      'isAccommodation': isAccommodation,
    };
  }

  factory LocationModel.fromJson(Map<String, dynamic> json) {
    final refs = json['photoReferences'];
    return LocationModel(
      id: json['id'],
      name: json['name'],
      address: json['address'],
      coordinates: LatLng(json['latitude'], json['longitude']),
      addedAt: DateTime.parse(json['addedAt']),
      travelTimeFromPrevious: json['travelTimeFromPreviousSeconds'] != null
          ? Duration(seconds: json['travelTimeFromPreviousSeconds'])
          : null,
      distanceFromPrevious: json['distanceFromPrevious']?.toDouble(),
      isSkipped: json['isSkipped'] ?? false,
      isDone: json['isDone'] ?? false,
      stayDuration: json['stayDurationSeconds'] != null
          ? Duration(seconds: json['stayDurationSeconds'])
          : const Duration(minutes: 30),
      scheduledDate: json['scheduledDate'] != null
          ? DateTime.parse(json['scheduledDate'])
          : null,
      photoReference: json['photoReference'],
      photoReferences: refs is List ? List<String>.from(refs) : null,
      photoAttributions: json['photoAttributions'] != null
          ? List<String>.from(json['photoAttributions'])
          : null,
      placeId: json['placeId'] as String?,
      originalName: json['originalName'] as String?,
      googleOpeningHours: (json['googleOpeningHours'] as List?)
          ?.map((e) => OpeningPeriod.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      userClosingMinuteOverride: json['userClosingMinuteOverride'] as int?,
      hoursLastRefreshedAt: json['hoursLastRefreshedAt'] != null
          ? DateTime.parse(json['hoursLastRefreshedAt'])
          : null,
      scheduledEndDate: json['scheduledEndDate'] != null
          ? DateTime.parse(json['scheduledEndDate'])
          : null,
      tripId: json['tripId'] as String?,
      isAccommodation: json['isAccommodation'] ?? false,
    );
  }

  // Sentinel used to distinguish "caller passed null" from "caller omitted
  // the param" for nullable fields where clearing is meaningful.
  static const _unset = Object();

  LocationModel copyWith({
    String? id,
    String? name,
    String? address,
    LatLng? coordinates,
    DateTime? addedAt,
    Duration? travelTimeFromPrevious,
    double? distanceFromPrevious,
    Duration? stayDuration,
    bool? isSkipped,
    bool? isDone,
    // Sentinel-nullable: `copyWith(scheduledDate: null)` really CLEARS the
    // date (→ the Unscheduled bucket); omitting the param keeps it.
    Object? scheduledDate = _unset,
    String? photoReference,
    List<String>? photoReferences,
    List<String>? photoAttributions,
    String? placeId,
    String? originalName,
    List<OpeningPeriod>? googleOpeningHours,
    int? userClosingMinuteOverride,
    DateTime? hoursLastRefreshedAt,
    Object? scheduledEndDate = _unset,
    Object? tripId = _unset,
    bool? isAccommodation,
  }) {
    return LocationModel(
      id: id ?? this.id,
      name: name ?? this.name,
      address: address ?? this.address,
      coordinates: coordinates ?? this.coordinates,
      addedAt: addedAt ?? this.addedAt,
      travelTimeFromPrevious:
          travelTimeFromPrevious ?? this.travelTimeFromPrevious,
      distanceFromPrevious: distanceFromPrevious ?? this.distanceFromPrevious,
      stayDuration: stayDuration ?? this.stayDuration,
      isSkipped: isSkipped ?? this.isSkipped,
      isDone: isDone ?? this.isDone,
      scheduledDate: identical(scheduledDate, _unset)
          ? this.scheduledDate
          : scheduledDate as DateTime?,
      photoReference: photoReference ?? this.photoReference,
      photoReferences: photoReferences ?? this.photoReferences,
      photoAttributions: photoAttributions ?? this.photoAttributions,
      placeId: placeId ?? this.placeId,
      originalName: originalName ?? this.originalName,
      googleOpeningHours: googleOpeningHours ?? this.googleOpeningHours,
      userClosingMinuteOverride:
          userClosingMinuteOverride ?? this.userClosingMinuteOverride,
      hoursLastRefreshedAt: hoursLastRefreshedAt ?? this.hoursLastRefreshedAt,
      scheduledEndDate: identical(scheduledEndDate, _unset)
          ? this.scheduledEndDate
          : scheduledEndDate as DateTime?,
      tripId: identical(tripId, _unset) ? this.tripId : tripId as String?,
      isAccommodation: isAccommodation ?? this.isAccommodation,
    );
  }

  /// Google's hours list no opening period on [day]'s weekday. Named
  /// "might" on purpose: Places hours are often stale or incomplete, so
  /// every surface must say "might be closed — please check", never a flat
  /// "closed". False when hours are unknown or the place is 24/7.
  bool mightBeClosedOn(DateTime day) {
    final hours = googleOpeningHours;
    if (hours == null || hours.isEmpty) return false;
    if (hours.any((p) => p.isAlwaysOpen)) return false;
    // Google weekday numbering: Sunday = 0 … Saturday = 6.
    final googleDay = day.weekday % 7;
    return !hours.any((p) => p.openDay == googleDay);
  }

  /// True iff this location is "active" on [day] — i.e. [day] is within
  /// `[scheduledDate..scheduledEndDate]` inclusive. A row with no
  /// [scheduledDate] is UNSCHEDULED (the trip's bucket): active on NO day.
  bool isActiveOnDate(DateTime day) {
    final startRaw = scheduledDate;
    if (startRaw == null) return false;
    final start = DateTime(startRaw.year, startRaw.month, startRaw.day);
    final endRaw = scheduledEndDate ?? startRaw;
    final end = DateTime(endRaw.year, endRaw.month, endRaw.day);
    final target = DateTime(day.year, day.month, day.day);
    return !target.isBefore(start) && !target.isAfter(end);
  }

  /// True iff this location explicitly spans more than one day.
  bool get isMultiDay {
    if (scheduledEndDate == null || scheduledDate == null) return false;
    final s =
        DateTime(scheduledDate!.year, scheduledDate!.month, scheduledDate!.day);
    final e = DateTime(
        scheduledEndDate!.year, scheduledEndDate!.month, scheduledEndDate!.day);
    return e.isAfter(s);
  }

  /// Best label to send to external apps (Google Maps, Grab) for handoff.
  /// Prefers [originalName] (canonical Google label captured at add time)
  /// over [name] (which the user may have renamed). Falls back to [name]
  /// for legacy rows that don't have an originalName recorded.
  String get externalHandoffName =>
      (originalName != null && originalName!.isNotEmpty) ? originalName! : name;
}

/// Converts a [SavedLocation] (Hive/Supabase storage type) to an in-memory
/// [LocationModel]. The optional [address] allows callers to supply a
/// human-readable address string; defaults to empty for contexts (e.g. the
/// trip-plan map state) where address is not displayed.
extension ToLocationModel on SavedLocation {
  LocationModel toLocationModel({String address = ''}) {
    final refs = effectivePhotoReferences;
    return LocationModel(
      id: id,
      name: name,
      address: address,
      coordinates: LatLng(lat, lng),
      addedAt: createdAt,
      stayDuration: Duration(seconds: stayDuration),
      isSkipped: isSkipped,
      isDone: isDone,
      scheduledDate: scheduledDate,
      photoReference: photoReference,
      photoReferences: refs.isEmpty ? null : refs,
      photoAttributions: photoAttributions,
      placeId: placeId,
      originalName: originalName,
      googleOpeningHours: googleOpeningHours,
      userClosingMinuteOverride: userClosingMinuteOverride,
      hoursLastRefreshedAt: hoursLastRefreshedAt,
      scheduledEndDate: scheduledEndDate,
      tripId: tripId,
      isAccommodation: isAccommodation,
    );
  }
}
