import 'package:dio/dio.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'dart:async';
import '../models/location_model.dart';

class GoogleMapsService {
  static final Dio _dio = Dio(BaseOptions(
    // OPTIMIZATION: Set timeouts to prevent long waits
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 15),
  ));
  static String get _apiKey => dotenv.env['GOOGLE_DIRECTIONS_API_KEY'] ?? '';

  static Future<Map<String, dynamic>> getOptimizedRouteDetails({
    required LatLng origin,
    LocationModel? destination,
    List<LocationModel> waypoints = const [],
    bool optimizeWaypoints = true,
  }) async {
    final allDestinations = [...waypoints, if (destination != null) destination];
    if (allDestinations.isEmpty) {
      return {
        'routePoints': <LatLng>[],
        'waypointOrder': <int>[],
        'legDetails': <Map<String, dynamic>>[],
        'legPolylines': <List<LatLng>>[],
      };
    }

    try {
      String url;
      final finalDestination = destination?.coordinates ?? origin;

      if (waypoints.isEmpty && destination != null) {
        // Single destination - direct route
        url = 'https://maps.googleapis.com/maps/api/directions/json'
            '?origin=${origin.latitude},${origin.longitude}'
            '&destination=${finalDestination.latitude},${finalDestination.longitude}'
            '&key=$_apiKey';
      } else {
        // Multiple destinations
        final waypointsString = waypoints
            .map((loc) => '${loc.coordinates.latitude},${loc.coordinates.longitude}')
            .join('|');
        
       final waypointParam = optimizeWaypoints ? 'optimize:true|$waypointsString' : waypointsString;
       
        url = 'https://maps.googleapis.com/maps/api/directions/json'
            '?origin=${origin.latitude},${origin.longitude}'
            '&destination=${finalDestination.latitude},${finalDestination.longitude}'
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
      final List<int> waypointOrder = [];
      final List<Map<String, dynamic>> legDetails = [];

      // Extract waypoint order for multiple destinations
     if (waypoints.isNotEmpty && route['waypoint_order'] != null && optimizeWaypoints) {
        waypointOrder.addAll((route['waypoint_order'] as List).cast<int>());
     } else if (waypoints.isNotEmpty) {
       // For custom ordering, waypoint order is sequential
       for (int i = 0; i < waypoints.length; i++) {
         waypointOrder.add(i);
       }
      } else if (destination != null) {
        // For single destination, there are no waypoints, so order is empty or just [0] if it's treated as one.
        waypointOrder.add(0);
      }

      // Extract leg details
      for (final leg in legs) {
        legDetails.add({
          'duration': Duration(seconds: leg['duration']['value']),
          'distance': (leg['distance']['value'] as int).toDouble(),
        });
      }

      // Extract complete polylines for each leg and flatten them for the overall route.
      final extractedLegPolylines = _extractLegPolylines(legs);
      final List<LatLng> fullRoutePoints = extractedLegPolylines.expand((leg) => leg).toList();

      return {
        'routePoints': fullRoutePoints,
        'waypointOrder': waypointOrder,
        'legDetails': legDetails,
        'legPolylines': extractedLegPolylines,
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

      // The start of the first step is the start of the leg.
      legPoints.add(LatLng(leg['start_location']['lat'], leg['start_location']['lng']));

      for (final step in steps) {
        final polyline = step['polyline']['points'];
        final decodedPoints = _decodePolyline(polyline);
        legPoints.addAll(decodedPoints);
      }
      
      // The decoded polyline doesn't always include the very last point. Add it explicitly.
      // legPoints.add(LatLng(leg['end_location']['lat'], leg['end_location']['lng']));

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