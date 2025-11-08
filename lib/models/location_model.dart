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
    this.scheduledDate,
  });

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
    };
  }

  factory LocationModel.fromJson(Map<String, dynamic> json) {
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
      stayDuration: json['stayDurationSeconds'] != null
          ? Duration(seconds: json['stayDurationSeconds'])
          : const Duration(minutes: 30),
      scheduledDate: json['scheduledDate'] != null
          ? DateTime.parse(json['scheduledDate'])
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
    DateTime? scheduledDate,
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
      scheduledDate: scheduledDate ?? this.scheduledDate,
    );
  }
}