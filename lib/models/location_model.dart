import 'package:google_maps_flutter/google_maps_flutter.dart';

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
    );
  }
}