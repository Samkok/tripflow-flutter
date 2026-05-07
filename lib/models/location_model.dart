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
      'googleOpeningHours':
          googleOpeningHours?.map((p) => p.toJson()).toList(),
      'userClosingMinuteOverride': userClosingMinuteOverride,
      'hoursLastRefreshedAt': hoursLastRefreshedAt?.toIso8601String(),
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
    );
  }

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
    DateTime? scheduledDate,
    String? photoReference,
    List<String>? photoReferences,
    List<String>? photoAttributions,
    String? placeId,
    String? originalName,
    List<OpeningPeriod>? googleOpeningHours,
    int? userClosingMinuteOverride,
    DateTime? hoursLastRefreshedAt,
  }) {
    return LocationModel(
      id: id ?? this.id,
      name: name ?? this.name,
      address: address ?? this.address,
      coordinates: coordinates ?? this.coordinates,
      addedAt: addedAt ?? this.addedAt,
      travelTimeFromPrevious: travelTimeFromPrevious ?? this.travelTimeFromPrevious,
      distanceFromPrevious: distanceFromPrevious ?? this.distanceFromPrevious,
      stayDuration: stayDuration ?? this.stayDuration,
      isSkipped: isSkipped ?? this.isSkipped,
      isDone: isDone ?? this.isDone,
      scheduledDate: scheduledDate ?? this.scheduledDate,
      photoReference: photoReference ?? this.photoReference,
      photoReferences: photoReferences ?? this.photoReferences,
      photoAttributions: photoAttributions ?? this.photoAttributions,
      placeId: placeId ?? this.placeId,
      originalName: originalName ?? this.originalName,
      googleOpeningHours: googleOpeningHours ?? this.googleOpeningHours,
      userClosingMinuteOverride:
          userClosingMinuteOverride ?? this.userClosingMinuteOverride,
      hoursLastRefreshedAt: hoursLastRefreshedAt ?? this.hoursLastRefreshedAt,
    );
  }

  /// Best label to send to external apps (Google Maps, Grab) for handoff.
  /// Prefers [originalName] (canonical Google label captured at add time)
  /// over [name] (which the user may have renamed). Falls back to [name]
  /// for legacy rows that don't have an originalName recorded.
  String get externalHandoffName =>
      (originalName != null && originalName!.isNotEmpty)
          ? originalName!
          : name;
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
    );
  }
}
