import 'dart:isolate';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../models/location_model.dart';
import 'zone_utils.dart';

/// OPTIMIZATION: Run heavy computations on an isolate to prevent UI blocking
class IsolateUtils {
  /// Message structure for isolate clustering computation
  static Future<Map<String, dynamic>> clusterLocationsIsolate(
    List<LocationModel> locations,
    double proximityThreshold,
  ) async {
    // Run clustering on a background isolate
    return await Isolate.run(
      () => _performClustering(locations, proximityThreshold),
    );
  }

  /// Static method that runs in the isolate
  static Map<String, dynamic> _performClustering(
    List<LocationModel> locations,
    double proximityThreshold,
  ) {
    // Perform the clustering computation
    final clusters = ZoneUtils.clusterLocations(locations, proximityThreshold);
    
    // Return the clusters as a serializable format
    return {
      'clusterCount': clusters.length,
      'clusters': clusters.map((cluster) {
        return cluster
            .map((loc) => {
                  'id': loc.id,
                  'name': loc.name,
                  'lat': loc.coordinates.latitude,
                  'lng': loc.coordinates.longitude,
                })
            .toList();
      }).toList(),
    };
  }

  /// OPTIMIZATION: Run expensive location ordering calculation on isolate
  static Future<List<LocationModel>> orderLocationsOptimally(
    List<LocationModel> clusters,
    LatLng startPoint,
  ) async {
    return await Isolate.run(
      () => _orderClusters(clusters, startPoint),
    );
  }

  static List<LocationModel> _orderClusters(
    List<LocationModel> locations,
    LatLng startPoint,
  ) {
    final ordered = <LocationModel>[];
    final remaining = List<LocationModel>.from(locations);
    var currentPoint = startPoint;

    while (remaining.isNotEmpty) {
      // Find nearest location
      LocationModel? nearest;
      double minDistance = double.infinity;

      for (final loc in remaining) {
        final distance = Geolocator.distanceBetween(
          currentPoint.latitude,
          currentPoint.longitude,
          loc.coordinates.latitude,
          loc.coordinates.longitude,
        );

        if (distance < minDistance) {
          minDistance = distance;
          nearest = loc;
        }
      }

      if (nearest != null) {
        ordered.add(nearest);
        remaining.remove(nearest);
        currentPoint = nearest.coordinates;
      } else {
        break;
      }
    }

    return ordered;
  }
}
