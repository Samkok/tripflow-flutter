import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import '../models/location_model.dart';

class ZoneUtils {
  // A palette of distinct, visually appealing colors for the zones.
  static final List<Color> _zoneColors = [
    Colors.blue.shade300,
    Colors.green.shade300,
    Colors.purple.shade300,
    Colors.orange.shade300,
    Colors.teal.shade300,
    Colors.pink.shade300,
  ];

  /// Generates zone polygons around clusters of nearby locations
  static Set<Circle> getZoneCircles(
    List<LocationModel> locations,
    double proximityThreshold,
  ) {
    if (locations.isEmpty) return {};

    // Group locations into clusters based on proximity
    final clusters = clusterLocations(locations, proximityThreshold);

    // Generate circles for clusters with 1 or more locations
    final Set<Circle> circles = {};

    for (int i = 0; i < clusters.length; i++) {
      final cluster = clusters[i];
      if (cluster.isNotEmpty) {
        final circle = _createZoneCircle(cluster, i);
        if (circle != null) {
          circles.add(circle);
        }
      }
    }

    return circles;
  }

  /// Clusters locations based on proximity threshold using a simple distance-based algorithm
  static List<List<LocationModel>> clusterLocations(
    List<LocationModel> locations,
    double proximityThreshold,
  ) {
    final List<List<LocationModel>> clusters = [];
    final Set<String> processedIds = {};

    for (final location in locations) {
      if (processedIds.contains(location.id)) continue;

      // Start a new cluster with this location
      final List<LocationModel> cluster = [location];
      processedIds.add(location.id);

      // Find all locations within proximity threshold of any location in the cluster
      bool foundNewLocation = true;
      while (foundNewLocation) {
        foundNewLocation = false;
        
        for (final unprocessedLocation in locations) {
          if (processedIds.contains(unprocessedLocation.id)) continue;

          // Check if this location is close to any location in the current cluster
          bool isCloseToCluster = false;
          for (final clusterLocation in cluster) {
            final distance = Geolocator.distanceBetween(
              clusterLocation.coordinates.latitude,
              clusterLocation.coordinates.longitude,
              unprocessedLocation.coordinates.latitude,
              unprocessedLocation.coordinates.longitude,
            );

            if (distance <= proximityThreshold) {
              isCloseToCluster = true;
              break;
            }
          }

          if (isCloseToCluster) {
            cluster.add(unprocessedLocation);
            processedIds.add(unprocessedLocation.id);
            foundNewLocation = true;
          }
        }
      }

      clusters.add(cluster);
    }

    return clusters;
  }

  /// Creates a circle that encloses a cluster of locations.
  static Circle? _createZoneCircle(List<LocationModel> cluster, int index) {
    if (cluster.isEmpty) return null;

    final points = cluster.map((loc) => loc.coordinates).toList();

    // Calculate the center of the cluster (centroid)
    double sumLat = 0, sumLng = 0;
    for (final point in points) {
      sumLat += point.latitude;
      sumLng += point.longitude;
    }
    final center = LatLng(sumLat / points.length, sumLng / points.length);

    // Find the farthest point from the center to determine the radius
    double maxDistance = 0;
    for (final point in points) {
      final distance = Geolocator.distanceBetween(
          center.latitude, center.longitude, point.latitude, point.longitude);
      if (distance > maxDistance) {
        maxDistance = distance;
      }
    }

    // Add padding to the radius
    final radius = maxDistance + 100; // Reduced 50m padding for a tighter fit

    // Select a color from the palette based on the index, cycling through if needed.
    final color = _zoneColors[index % _zoneColors.length];

    return Circle(
      circleId: CircleId('zone_$index'),
      center: center,
      radius: radius,
      fillColor: color.withOpacity(0.25), // Softer fill
      strokeColor: color.withOpacity(0.8), // Stronger stroke
      strokeWidth: 4,
    );
  }

  /// Converts a Circle's center and radius into a list of LatLng points for a Polygon.
  static List<LatLng> circleToPolygon(LatLng center, double radius, {int points = 64}) {
    final List<LatLng> polygonPoints = [];
    const double earthRadius = 6378137.0; // Earth's radius in meters

    // Convert center latitude to radians
    final double lat = center.latitude * (math.pi / 180);
    final double lng = center.longitude * (math.pi / 180);

    for (int i = 0; i < points; i++) {
      final double angle = (i / points) * 2 * math.pi;

      // Calculate the new point's coordinates
      final double pointLat = math.asin(math.sin(lat) * math.cos(radius / earthRadius) +
          math.cos(lat) * math.sin(radius / earthRadius) * math.cos(angle));
      final double pointLng = lng + math.atan2(math.sin(angle) * math.sin(radius / earthRadius) * math.cos(lat),
          math.cos(radius / earthRadius) - math.sin(lat) * math.sin(pointLat));

      polygonPoints.add(LatLng(pointLat * (180 / math.pi), pointLng * (180 / math.pi)));
    }
    return polygonPoints;
  }
}