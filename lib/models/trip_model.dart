import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'location_model.dart';

class TripModel {
  final String id;
  final String name;
  final List<LocationModel> locations;
  final List<LatLng> optimizedRoute;
  final Duration totalDuration;
  final double totalDistance;
  final DateTime createdAt;

  TripModel({
    required this.id,
    required this.name,
    required this.locations,
    required this.optimizedRoute,
    required this.totalDuration,
    required this.totalDistance,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'locations': locations.map((l) => l.toJson()).toList(),
      'optimizedRoute': optimizedRoute.map((point) => {
        'latitude': point.latitude,
        'longitude': point.longitude,
      }).toList(),
      'totalDurationMinutes': totalDuration.inMinutes,
      'totalDistance': totalDistance,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  factory TripModel.fromJson(Map<String, dynamic> json) {
    return TripModel(
      id: json['id'],
      name: json['name'],
      locations: (json['locations'] as List)
          .map((l) => LocationModel.fromJson(l))
          .toList(),
      optimizedRoute: (json['optimizedRoute'] as List)
          .map((point) => LatLng(point['latitude'], point['longitude']))
          .toList(),
      totalDuration: Duration(minutes: json['totalDurationMinutes']),
      totalDistance: json['totalDistance'].toDouble(),
      createdAt: DateTime.parse(json['createdAt']),
    );
  }
}