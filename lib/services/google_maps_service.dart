import 'package:dio/dio.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../models/location_model.dart';

class GoogleMapsService {
  static final Dio _dio = Dio();
  static String get _apiKey => dotenv.env['GOOGLE_DIRECTIONS_API_KEY'] ?? '';

  static Future<Map<String, dynamic>> getOptimizedRouteDetails({
    required LatLng origin,
    required List<LocationModel> destinations,
   bool optimizeWaypoints = true,
  }) async {
    if (destinations.isEmpty) return {
      'routePoints': <LatLng>[],
      'waypointOrder': <int>[],
      'legDetails': <Map<String, dynamic>>[],
    };

    try {
      String url;
      
      if (destinations.length == 1) {
        // Single destination - direct route
        final dest = destinations.first;
        url = 'https://maps.googleapis.com/maps/api/directions/json'
            '?origin=${origin.latitude},${origin.longitude}'
            '&destination=${dest.coordinates.latitude},${dest.coordinates.longitude}'
            '&key=$_apiKey';
      } else {
        // Multiple destinations - optimize waypoints and return to origin
        final waypoints = destinations
            .map((loc) => '${loc.coordinates.latitude},${loc.coordinates.longitude}')
            .join('|');
        
       final waypointParam = optimizeWaypoints ? 'optimize:true|$waypoints' : waypoints;
       
        url = 'https://maps.googleapis.com/maps/api/directions/json'
            '?origin=${origin.latitude},${origin.longitude}'
            '&destination=${origin.latitude},${origin.longitude}'
           '&waypoints=$waypointParam'
            '&key=$_apiKey';
      }

      final response = await _dio.get(url);
      final data = response.data;

      if (data['status'] != 'OK') {
        throw Exception('Directions API error: ${data['status']}');
      }

      final route = data['routes'][0];
      final legs = route['legs'] as List;
      final List<LatLng> routePoints = [];
      final List<int> waypointOrder = [];
      final List<Map<String, dynamic>> legDetails = [];

      // Extract waypoint order for multiple destinations
     if (destinations.length > 1 && route['waypoint_order'] != null && optimizeWaypoints) {
        waypointOrder.addAll((route['waypoint_order'] as List).cast<int>());
     } else if (destinations.length > 1 && !optimizeWaypoints) {
       // For custom ordering, waypoint order is sequential
       for (int i = 0; i < destinations.length; i++) {
         waypointOrder.add(i);
       }
      } else if (destinations.length == 1) {
        // For single destination, order is just [0]
        waypointOrder.add(0);
      }

      // Add origin
      routePoints.add(origin);

      // Process each leg for route points and details
      for (final leg in legs) {
        // Extract leg details
        legDetails.add({
          'duration': Duration(seconds: leg['duration']['value']),
          'distance': (leg['distance']['value'] as int).toDouble(),
        });
        
        final steps = leg['steps'] as List;
        for (final step in steps) {
          final polyline = step['polyline']['points'];
          final decodedPoints = _decodePolyline(polyline);
          routePoints.addAll(decodedPoints);
        }
      }

      return {
        'routePoints': routePoints,
        'waypointOrder': waypointOrder,
        'legDetails': legDetails,
        'legPolylines': _extractLegPolylines(legs),
      };
    } catch (e) {
      print('Error getting optimized route: $e');
      return {
        'routePoints': <LatLng>[],
        'waypointOrder': <int>[],
        'legDetails': <Map<String, dynamic>>[],
        'legPolylines': <List<LatLng>>[],
      };
    }
  }

  static List<List<LatLng>> _extractLegPolylines(List legs) {
    final List<List<LatLng>> legPolylines = [];
    
    for (final leg in legs) {
      final List<LatLng> legPoints = [];
      final steps = leg['steps'] as List;
      
      for (final step in steps) {
        final polyline = step['polyline']['points'];
        final decodedPoints = _decodePolyline(polyline);
        legPoints.addAll(decodedPoints);
      }
      
      legPolylines.add(legPoints);
    }
    
    return legPolylines;
  }

  static List<LatLng> _decodePolyline(String polyline) {
    final List<LatLng> points = [];
    int index = 0;
    final len = polyline.length;
    int lat = 0;
    int lng = 0;

    while (index < len) {
      int b;
      int shift = 0;
      int result = 0;
      do {
        b = polyline.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      final int dlat = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lat += dlat;

      shift = 0;
      result = 0;
      do {
        b = polyline.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      final int dlng = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lng += dlng;

      points.add(LatLng(lat / 1E5, lng / 1E5));
    }

    return points;
  }
}