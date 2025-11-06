import 'package:dio/dio.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

class PlacePrediction {
  final String placeId;
  final String description;
  final String mainText;
  final String secondaryText;

  PlacePrediction({
    required this.placeId,
    required this.description,
    required this.mainText,
    required this.secondaryText,
  });

  factory PlacePrediction.fromJson(Map<String, dynamic> json) {
    return PlacePrediction(
      placeId: json['place_id'],
      description: json['description'],
      mainText: json['structured_formatting']['main_text'] ?? '',
      secondaryText: json['structured_formatting']['secondary_text'] ?? '',
    );
  }
}

class PlaceDetails {
  final String name;
  final String address;
  final LatLng coordinates;

  PlaceDetails({
    required this.name,
    required this.address,
    required this.coordinates,
  });

  factory PlaceDetails.fromJson(Map<String, dynamic> json) {
    final geometry = json['geometry']['location'];
    return PlaceDetails(
      name: json['name'] ?? '',
      address: json['formatted_address'] ?? '',
      coordinates: LatLng(
        geometry['lat'].toDouble(),
        geometry['lng'].toDouble(),
      ),
    );
  }
}

class PlacesService {
  static final Dio _dio = Dio();
  static String get _apiKey => dotenv.env['GOOGLE_PLACES_API_KEY'] ?? '';
  static String get _geocodingApiKey => dotenv.env['GOOGLE_MAPS_API_KEY'] ?? '';

  static Future<List<PlacePrediction>> searchPlaces(String query) async {
    if (query.isEmpty) return [];

    try {
      final url = 'https://maps.googleapis.com/maps/api/place/autocomplete/json'
          '?input=${Uri.encodeComponent(query)}'
          '&key=$_apiKey';

      final response = await _dio.get(url);
      final data = response.data;

      if (data['status'] != 'OK') return [];

      final predictions = data['predictions'] as List;
      return predictions
          .map((prediction) => PlacePrediction.fromJson(prediction))
          .toList();
    } catch (e) {
      print('Error searching places: $e');
      return [];
    }
  }

  static Future<PlaceDetails?> getPlaceDetails(String placeId) async {
    try {
      final url = 'https://maps.googleapis.com/maps/api/place/details/json'
          '?place_id=$placeId'
          '&fields=name,formatted_address,geometry'
          '&key=$_apiKey';

      final response = await _dio.get(url);
      final data = response.data;

      if (data['status'] != 'OK') return null;

      return PlaceDetails.fromJson(data['result']);
    } catch (e) {
      print('Error getting place details: $e');
      return null;
    }
  }

  static Future<PlaceDetails?> getPlaceFromCoordinates(LatLng coordinates) async {
    try {
      final url = 'https://maps.googleapis.com/maps/api/geocode/json'
          '?latlng=${coordinates.latitude},${coordinates.longitude}'
          '&key=$_geocodingApiKey';

      final response = await _dio.get(url);
      final data = response.data;

      if (data['status'] != 'OK' || data['results'].isEmpty) {
        // Return a generic location if geocoding fails
        return PlaceDetails(
          name: 'Pinned Location',
          address: '${coordinates.latitude.toStringAsFixed(6)}, ${coordinates.longitude.toStringAsFixed(6)}',
          coordinates: coordinates,
        );
      }

      final result = data['results'][0];
      String name = 'Pinned Location';
      
      // Try to get a meaningful name from the result
      final addressComponents = result['address_components'] as List;
      for (final component in addressComponents) {
        final types = component['types'] as List;
        if (types.contains('establishment') || 
            types.contains('point_of_interest') ||
            types.contains('premise')) {
          name = component['long_name'];
          break;
        }
      }
      
      // If no establishment name found, use the first address component
      if (name == 'Pinned Location' && addressComponents.isNotEmpty) {
        name = addressComponents[0]['long_name'] ?? 'Pinned Location';
      }

      return PlaceDetails(
        name: name,
        address: result['formatted_address'] ?? '',
        coordinates: coordinates,
      );
    } catch (e) {
      print('Error getting place from coordinates: $e');
      // Return a generic location if there's an error
      return PlaceDetails(
        name: 'Pinned Location',
        address: '${coordinates.latitude.toStringAsFixed(6)}, ${coordinates.longitude.toStringAsFixed(6)}',
        coordinates: coordinates,
      );
    }
  }
}