import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:dio/dio.dart';
import 'package:geolocator/geolocator.dart';
import 'api_service.dart';
import 'location_service.dart';

class PlacePrediction {
  final String placeId;
  final String description;
  final String mainText;
  final String secondaryText;
  final int? distanceMeters;

  PlacePrediction({
    required this.placeId,
    required this.description,
    required this.mainText,
    required this.secondaryText,
    this.distanceMeters,
  });

  factory PlacePrediction.fromJson(Map<String, dynamic> json) {
    return PlacePrediction(
      placeId: json['place_id'],
      description: json['description'],
      mainText: json['structured_formatting']['main_text'] ?? '',
      secondaryText: json['structured_formatting']['secondary_text'] ?? '',
      distanceMeters: json['distance_meters'],
    );
  }
}

class PlaceDetails {
  final String name;
  final String address;
  final LatLng coordinates;
  final String? photoReference;
  final int? photoWidth;
  final int? photoHeight;
  final List<String>? photoAttributions;

  PlaceDetails({
    required this.name,
    required this.address,
    required this.coordinates,
    this.photoReference,
    this.photoWidth,
    this.photoHeight,
    this.photoAttributions,
  });

  factory PlaceDetails.fromJson(Map<String, dynamic> json) {
    final geometry = json['geometry']['location'];
    final photos = json['photos'] as List?;

    String? photoRef;
    int? photoWidth;
    int? photoHeight;
    List<String>? attributions;

    if (photos != null && photos.isNotEmpty) {
      final firstPhoto = photos[0];
      photoRef = firstPhoto['photo_reference'];
      photoWidth = firstPhoto['width'];
      photoHeight = firstPhoto['height'];
      attributions = (firstPhoto['html_attributions'] as List?)
          ?.map((e) => e.toString())
          .toList();
    }

    return PlaceDetails(
      name: json['name'] ?? '',
      address: json['formatted_address'] ?? '',
      coordinates: LatLng(
        geometry['lat'].toDouble(),
        geometry['lng'].toDouble(),
      ),
      photoReference: photoRef,
      photoWidth: photoWidth,
      photoHeight: photoHeight,
      photoAttributions: attributions,
    );
  }
}

class PlacesService {
  static Future<List<PlacePrediction>> searchPlaces(String query) async {
    if (query.isEmpty) return [];

    try {
      // Get current location to bias results and calculate distances
      final currentLocation = await LocationService.getCurrentLocation();
      final countryCode = await LocationService.getCurrentCountryCode();

      String url =
          'https://maps.googleapis.com/maps/api/place/autocomplete/json'
          '?input=${Uri.encodeComponent(query)}'
          '&key=${ApiService.googlePlacesApiKey}';

      // Add location bias to prioritize nearby results
      if (currentLocation != null) {
        url += '&location=${currentLocation.latitude},${currentLocation.longitude}';
        url += '&radius=50000'; // 50km radius
      }

      if (countryCode != null) {
        url += '&components=country:$countryCode';
      }

      final response = await ApiService.dio.get(url);
      final data = response.data;

      if (data['status'] != 'OK') return [];

      final predictions = data['predictions'] as List;
      final predictionsList = predictions
          .map((prediction) => PlacePrediction.fromJson(prediction))
          .toList();

      // If we have current location, fetch details for each prediction to calculate distance
      if (currentLocation != null && predictionsList.isNotEmpty) {
        final predictionsWithDistance = await Future.wait(
          predictionsList.map((prediction) async {
            try {
              final details = await getPlaceDetails(prediction.placeId);
              if (details != null) {
                // Calculate distance using Geolocator
                final distanceMeters = Geolocator.distanceBetween(
                  currentLocation.latitude,
                  currentLocation.longitude,
                  details.coordinates.latitude,
                  details.coordinates.longitude,
                ).round();

                return PlacePrediction(
                  placeId: prediction.placeId,
                  description: prediction.description,
                  mainText: prediction.mainText,
                  secondaryText: prediction.secondaryText,
                  distanceMeters: distanceMeters,
                );
              }
              return prediction;
            } catch (e) {
              print('Error calculating distance for ${prediction.placeId}: $e');
              return prediction;
            }
          }),
        );

        // Sort by distance (nearest first)
        predictionsWithDistance.sort((a, b) {
          if (a.distanceMeters == null && b.distanceMeters == null) return 0;
          if (a.distanceMeters == null) return 1;
          if (b.distanceMeters == null) return -1;
          return a.distanceMeters!.compareTo(b.distanceMeters!);
        });

        return predictionsWithDistance;
      }

      return predictionsList;
    } catch (e) {
      print('Error searching places: $e');
      return [];
    }
  }

  /// Search places with pagination support
  /// Uses Text Search API for better pagination control
  static Future<List<PlacePrediction>> searchPlacesPaginated(
    String query, {
    int offset = 0,
    int limit = 5,
  }) async {
    if (query.isEmpty) return [];

    try {
      // Get current location and country for filtering
      final currentLocation = await LocationService.getCurrentLocation();
      final countryCode = await LocationService.getCurrentCountryCode();

      // Use Text Search API which supports better pagination
      String url =
          'https://maps.googleapis.com/maps/api/place/textsearch/json'
          '?query=${Uri.encodeComponent(query)}'
          '&key=${ApiService.googlePlacesApiKey}';

      // Add location bias
      if (currentLocation != null) {
        url += '&location=${currentLocation.latitude},${currentLocation.longitude}';
        url += '&radius=50000'; // 50km radius
      }

      // Add country restriction
      if (countryCode != null) {
        url += '&region=$countryCode';
      }

      final response = await ApiService.dio.get(url);
      final data = response.data;

      if (data['status'] != 'OK' && data['status'] != 'ZERO_RESULTS') {
        return [];
      }

      final results = (data['results'] as List?) ?? [];

      // Apply pagination manually (skip offset, take limit)
      final paginatedResults = results
          .skip(offset)
          .take(limit)
          .toList();

      // Convert to PlacePrediction format
      final predictions = <PlacePrediction>[];

      for (final result in paginatedResults) {
        try {
          final placeId = result['place_id'] as String;
          final name = result['name'] as String? ?? '';
          final address = result['formatted_address'] as String? ?? '';
          final geometry = result['geometry'];
          final location = geometry?['location'];

          int? distanceMeters;
          if (currentLocation != null && location != null) {
            final lat = (location['lat'] as num?)?.toDouble();
            final lng = (location['lng'] as num?)?.toDouble();
            if (lat != null && lng != null) {
              distanceMeters = Geolocator.distanceBetween(
                currentLocation.latitude,
                currentLocation.longitude,
                lat,
                lng,
              ).round();
            }
          }

          predictions.add(PlacePrediction(
            placeId: placeId,
            description: '$name, $address',
            mainText: name,
            secondaryText: address,
            distanceMeters: distanceMeters,
          ));
        } catch (e) {
          print('Error parsing search result: $e');
          continue;
        }
      }

      // Sort by distance if available
      if (predictions.any((p) => p.distanceMeters != null)) {
        predictions.sort((a, b) {
          if (a.distanceMeters == null && b.distanceMeters == null) return 0;
          if (a.distanceMeters == null) return 1;
          if (b.distanceMeters == null) return -1;
          return a.distanceMeters!.compareTo(b.distanceMeters!);
        });
      }

      return predictions;
    } catch (e) {
      print('Error searching places (paginated): $e');
      return [];
    }
  }

  static Future<PlaceDetails?> getPlaceDetails(String placeId) async {
    try {
      final url = 'https://maps.googleapis.com/maps/api/place/details/json'
          '?place_id=$placeId'
          '&fields=name,formatted_address,geometry,photos'
          '&key=${ApiService.googlePlacesApiKey}';

      final response = await ApiService.dio.get(url);
      final data = response.data;

      if (data['status'] != 'OK') return null;

      return PlaceDetails.fromJson(data['result']);
    } catch (e) {
      print('Error getting place details: $e');
      return null;
    }
  }

  /// Geocode an address string to get PlaceDetails
  static Future<PlaceDetails?> getPlaceFromAddress(String address) async {
    try {
      final url = 'https://maps.googleapis.com/maps/api/geocode/json'
          '?address=${Uri.encodeComponent(address)}'
          '&key=${ApiService.googleMapsApiKey}';

      final response = await ApiService.dio.get(url);
      final data = response.data;

      if (data['status'] != 'OK' || data['results'].isEmpty) return null;

      final result = data['results'][0];
      final location = result['geometry']['location'];
      final lat = location['lat'] as double;
      final lng = location['lng'] as double;

      String name = address;
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

      return PlaceDetails(
        name: name,
        address: result['formatted_address'] ?? address,
        coordinates: LatLng(lat, lng),
      );
    } catch (e) {
      print('Error geocoding address: $e');
      return null;
    }
  }

  static Future<PlaceDetails?> getPlaceFromGoogleMapsUrl(String url) async {
    try {
      String finalUrl = url;
      // Handle shortened URLs (e.g., maps.app.goo.gl) by following redirects
      if (url.contains('goo.gl/maps') || url.contains('maps.app.goo.gl')) {
        // Configure Dio to not throw an error on redirect status codes.
        // This allows us to inspect the response headers for the new URL.
        final response = await ApiService.dio.get(
          url,
          options: Options(
            followRedirects: false, // We need to handle the redirect manually
            validateStatus: (status) =>
                status != null && status < 400, // Treat 3xx as success
          ),
        );

        if (response.statusCode == 301 || response.statusCode == 302) {
          final locationHeader = response.headers['location'];
          if (locationHeader != null && locationHeader.isNotEmpty) {
            finalUrl = locationHeader.first;
          } else {
            throw Exception('URL redirect did not provide a new location.');
          }
        }
      }

      // Regex to find coordinates in the format @lat,lng
      final regex = RegExp(r'@(-?\d+\.\d+),(-?\d+\.\d+)');
      final match = regex.firstMatch(finalUrl);

      if (match != null && match.groupCount >= 2) {
        final lat = double.tryParse(match.group(1)!);
        final lng = double.tryParse(match.group(2)!);

        if (lat != null && lng != null) {
          // We found coordinates, now use reverse geocoding to get details
          return await getPlaceFromCoordinates(LatLng(lat, lng));
        }
      }

      // If regex fails, throw an exception to be caught by the UI layer.
      throw Exception('Could not extract location coordinates from URL.');
    } catch (e) {
      print('Error parsing Google Maps URL: $e');
      // Re-throw the exception so the UI can handle it.
      rethrow;
    }
  }

  static Future<PlaceDetails?> getPlaceFromCoordinates(
      LatLng coordinates) async {
    try {
      final url = 'https://maps.googleapis.com/maps/api/geocode/json'
          '?latlng=${coordinates.latitude},${coordinates.longitude}'
          '&key=${ApiService.googleMapsApiKey}';

      final response = await ApiService.dio.get(url);
      final data = response.data;

      if (data['status'] != 'OK' || data['results'].isEmpty) {
        // Return a generic location if geocoding fails
        return PlaceDetails(
          name: 'Pinned Location',
          address:
              '${coordinates.latitude.toStringAsFixed(6)}, ${coordinates.longitude.toStringAsFixed(6)}',
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
        address:
            '${coordinates.latitude.toStringAsFixed(6)}, ${coordinates.longitude.toStringAsFixed(6)}',
        coordinates: coordinates,
      );
    }
  }
}