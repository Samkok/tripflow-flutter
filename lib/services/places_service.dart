import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:dio/dio.dart';
import 'package:geolocator/geolocator.dart';
import '../utils/countries.dart';
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
  /// Cover photo reference — equal to the first item of [photoReferences]
  /// when any photos are present. Kept as a separate field so older code
  /// paths and database columns that only carry one reference keep working.
  final String? photoReference;
  /// All available photo references for the in-card gallery.
  /// Empty when the place has no photos.
  final List<String> photoReferences;
  final int? photoWidth;
  final int? photoHeight;
  /// Combined HTML attributions across every fetched photo. Google's terms
  /// require attributions to be displayed alongside any photo we render.
  final List<String>? photoAttributions;
  /// ISO 3166-1 alpha-2 country code parsed from address_components, when
  /// available. Used to flag cross-country adds against a trip's tagged
  /// country.
  final String? countryCode;

  PlaceDetails({
    required this.name,
    required this.address,
    required this.coordinates,
    this.photoReference,
    List<String>? photoReferences,
    this.photoWidth,
    this.photoHeight,
    this.photoAttributions,
    this.countryCode,
  }) : photoReferences = photoReferences ?? const [];

  factory PlaceDetails.fromJson(Map<String, dynamic> json) {
    final geometry = json['geometry']['location'];
    final photos = json['photos'] as List?;

    final photoRefs = <String>[];
    final attributions = <String>[];
    int? photoWidth;
    int? photoHeight;

    if (photos != null) {
      for (final photo in photos) {
        if (photo is! Map) continue;
        final ref = photo['photo_reference'];
        if (ref is! String || ref.isEmpty) continue;
        photoRefs.add(ref);
        if (photoWidth == null) {
          photoWidth = photo['width'] as int?;
          photoHeight = photo['height'] as int?;
        }
        final attrs = photo['html_attributions'] as List?;
        if (attrs != null) {
          for (final a in attrs) {
            attributions.add(a.toString());
          }
        }
      }
    }

    return PlaceDetails(
      name: json['name'] ?? '',
      address: json['formatted_address'] ?? '',
      coordinates: LatLng(
        geometry['lat'].toDouble(),
        geometry['lng'].toDouble(),
      ),
      photoReference: photoRefs.isNotEmpty ? photoRefs.first : null,
      photoReferences: photoRefs,
      photoWidth: photoWidth,
      photoHeight: photoHeight,
      photoAttributions: attributions.isEmpty ? null : attributions,
      countryCode: _extractCountryCode(json['address_components']),
    );
  }
}

/// Lightweight summary returned by Google Places Nearby Search. Carries
/// just enough to render a picker row (name, photo, distance, type) without
/// the per-place follow-up call that full [PlaceDetails] would require.
class NearbyPlace {
  final String placeId;
  final String name;
  final String vicinity;
  final LatLng coordinates;
  final String? photoReference;
  final List<String> photoReferences;
  final List<String>? photoAttributions;
  /// Primary type from Google's `types` array (e.g. "restaurant"). Useful
  /// for a one-line subtitle alongside the distance.
  final String? primaryType;
  /// Haversine distance from the long-press coordinate, in meters.
  final double distanceMeters;

  const NearbyPlace({
    required this.placeId,
    required this.name,
    required this.vicinity,
    required this.coordinates,
    required this.distanceMeters,
    this.photoReference,
    this.photoReferences = const [],
    this.photoAttributions,
    this.primaryType,
  });

  static NearbyPlace? fromJson(
    Map<String, dynamic> json, {
    required LatLng origin,
  }) {
    final placeId = json['place_id'];
    final geometry = json['geometry'];
    if (placeId is! String || placeId.isEmpty || geometry is! Map) return null;
    final loc = geometry['location'];
    if (loc is! Map) return null;
    final lat = (loc['lat'] as num?)?.toDouble();
    final lng = (loc['lng'] as num?)?.toDouble();
    if (lat == null || lng == null) return null;

    final photoRefs = <String>[];
    final attributions = <String>[];
    final photos = json['photos'];
    if (photos is List) {
      for (final p in photos) {
        if (p is! Map) continue;
        final ref = p['photo_reference'];
        if (ref is String && ref.isNotEmpty) photoRefs.add(ref);
        final attrs = p['html_attributions'];
        if (attrs is List) {
          for (final a in attrs) {
            attributions.add(a.toString());
          }
        }
      }
    }

    String? primaryType;
    final types = json['types'];
    if (types is List && types.isNotEmpty) {
      // Skip the generic catch-all types so the subtitle is informative.
      const generic = {'point_of_interest', 'establishment', 'place'};
      for (final t in types) {
        if (t is String && !generic.contains(t)) {
          primaryType = t;
          break;
        }
      }
      primaryType ??= types.first is String ? types.first as String : null;
    }

    return NearbyPlace(
      placeId: placeId,
      name: (json['name'] as String?) ?? 'Unnamed place',
      vicinity: (json['vicinity'] as String?) ?? '',
      coordinates: LatLng(lat, lng),
      distanceMeters: _haversineMeters(origin, LatLng(lat, lng)),
      photoReference: photoRefs.isNotEmpty ? photoRefs.first : null,
      photoReferences: photoRefs,
      photoAttributions: attributions.isEmpty ? null : attributions,
      primaryType: primaryType,
    );
  }
}

double _haversineMeters(LatLng a, LatLng b) {
  const earthRadius = 6371000.0;
  double toRad(double d) => d * math.pi / 180.0;
  final lat1 = toRad(a.latitude);
  final lat2 = toRad(b.latitude);
  final dLat = toRad(b.latitude - a.latitude);
  final dLng = toRad(b.longitude - a.longitude);
  final sLat = math.sin(dLat / 2);
  final sLng = math.sin(dLng / 2);
  final h = sLat * sLat + math.cos(lat1) * math.cos(lat2) * sLng * sLng;
  return 2 * earthRadius * math.atan2(math.sqrt(h), math.sqrt(1 - h));
}

/// Pulls the ISO-2 country code (e.g. "KH") out of a Google Places
/// address_components array. Returns null when the array is missing or
/// contains no entry of type "country".
String? _extractCountryCode(dynamic addressComponents) {
  if (addressComponents is! List) return null;
  for (final component in addressComponents) {
    if (component is! Map) continue;
    final types = component['types'];
    if (types is! List) continue;
    if (types.contains('country')) {
      final shortName = component['short_name'];
      if (shortName is String && shortName.isNotEmpty) {
        return shortName.toUpperCase();
      }
    }
  }
  return null;
}

class PlacesService {
  static Future<List<PlacePrediction>> searchPlaces(
    String query, {
    String? countryCodeOverride,
  }) async {
    if (query.isEmpty) return [];

    try {
      // Get current location to bias results and calculate distances
      final currentLocation = await LocationService.getCurrentLocation();
      // A trip-tagged country (override) takes precedence over the device
      // country so users planning a trip ahead of time see the destination
      // country first.
      final countryCode = countryCodeOverride?.toLowerCase() ??
          await LocationService.getCurrentCountryCode();

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
              debugPrint('Error calculating distance for ${prediction.placeId}: $e');
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
      debugPrint('Error searching places: $e');
      return [];
    }
  }

  /// Search places with pagination support
  /// Uses Text Search API for better pagination control
  static Future<List<PlacePrediction>> searchPlacesPaginated(
    String query, {
    int offset = 0,
    int limit = 5,
    String? countryCodeOverride,
  }) async {
    if (query.isEmpty) return [];

    try {
      // Get current location and country for filtering
      final currentLocation = await LocationService.getCurrentLocation();
      // A trip-tagged country (override) takes precedence over the device
      // country so users planning a trip ahead of time see the destination
      // country first.
      final countryCode = countryCodeOverride?.toLowerCase() ??
          await LocationService.getCurrentCountryCode();

      // Text Search's `region` parameter is only a soft bias — Google may
      // still return results from other countries. To make the override
      // actually prioritize the chosen country, we fold the country *name*
      // into the query string itself when an override is provided. This is
      // what users do manually ("pizza Cambodia") and gets a strong bias.
      final overrideCountry = countryCodeOverride == null
          ? null
          : findCountryByCode(countryCodeOverride);
      final effectiveQuery = overrideCountry != null
          ? '$query ${overrideCountry.name}'
          : query;

      // Use Text Search API which supports better pagination
      String url =
          'https://maps.googleapis.com/maps/api/place/textsearch/json'
          '?query=${Uri.encodeComponent(effectiveQuery)}'
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
          debugPrint('Error parsing search result: $e');
          continue;
        }
      }

      // Sort: when a country override is set, results whose address contains
      // the country name come first; within each group, sort by distance.
      // This is a belt-and-suspenders pass on top of the query-string trick
      // above — Google still occasionally interleaves out-of-country hits
      // when its name matches strongly.
      final countryName = overrideCountry?.name.toLowerCase();
      int distanceCompare(PlacePrediction a, PlacePrediction b) {
        if (a.distanceMeters == null && b.distanceMeters == null) return 0;
        if (a.distanceMeters == null) return 1;
        if (b.distanceMeters == null) return -1;
        return a.distanceMeters!.compareTo(b.distanceMeters!);
      }

      bool matchesCountry(PlacePrediction p) {
        if (countryName == null) return false;
        return p.secondaryText.toLowerCase().contains(countryName);
      }

      predictions.sort((a, b) {
        if (countryName != null) {
          final aMatch = matchesCountry(a);
          final bMatch = matchesCountry(b);
          if (aMatch != bMatch) return aMatch ? -1 : 1;
        }
        return distanceCompare(a, b);
      });

      return predictions;
    } catch (e) {
      debugPrint('Error searching places (paginated): $e');
      return [];
    }
  }

  static Future<PlaceDetails?> getPlaceDetails(String placeId) async {
    try {
      final url = 'https://maps.googleapis.com/maps/api/place/details/json'
          '?place_id=$placeId'
          '&fields=name,formatted_address,geometry,photos,address_components'
          '&key=${ApiService.googlePlacesApiKey}';

      final response = await ApiService.dio.get(url);
      final data = response.data;

      if (data['status'] != 'OK') return null;

      return PlaceDetails.fromJson(data['result']);
    } catch (e) {
      debugPrint('Error getting place details: $e');
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

      // Best-effort enrichment: pull photo references via Place Details when
      // the geocode hit carries a place_id. The geocoding endpoint itself
      // never returns photos.
      final placeId = result['place_id'] as String?;
      final enriched =
          placeId == null ? null : await _safeGetPlaceDetails(placeId);

      return PlaceDetails(
        name: name,
        address: result['formatted_address'] ?? address,
        coordinates: LatLng(lat, lng),
        countryCode: _extractCountryCode(addressComponents),
        photoReference: enriched?.photoReference,
        photoReferences: enriched?.photoReferences,
        photoWidth: enriched?.photoWidth,
        photoHeight: enriched?.photoHeight,
        photoAttributions: enriched?.photoAttributions,
      );
    } catch (e) {
      debugPrint('Error geocoding address: $e');
      return null;
    }
  }

  /// Wraps [getPlaceDetails] so callers can opportunistically enrich a
  /// geocoded result with photos without aborting the whole flow on failure.
  static Future<PlaceDetails?> _safeGetPlaceDetails(String placeId) async {
    try {
      return await getPlaceDetails(placeId);
    } catch (_) {
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
      debugPrint('Error parsing Google Maps URL: $e');
      // Re-throw the exception so the UI can handle it.
      rethrow;
    }
  }

  /// Returns up to 20 POIs (Google Places Nearby Search caps a single page
   /// at 20) within [radiusMeters] of [center]. Each result carries a
   /// `distanceMeters` derived from the haversine distance to [center] so
   /// callers can sort/display proximity without an extra round trip.
   ///
   /// We deliberately do NOT call `getPlaceDetails` per-result here — that
   /// would be 20× the cost of the single Nearby Search call. Photo refs
   /// returned by Nearby Search work directly with the Photos endpoint, so
   /// the picker UI can render thumbnails without follow-up requests; the
   /// per-place enrichment (full address, more photos, country code) only
   /// happens when the user actually selects a POI to add.
  static Future<List<NearbyPlace>> searchNearbyPlaces(
    LatLng center, {
    required int radiusMeters,
  }) async {
    try {
      final url =
          'https://maps.googleapis.com/maps/api/place/nearbysearch/json'
          '?location=${center.latitude},${center.longitude}'
          '&radius=$radiusMeters'
          '&key=${ApiService.googlePlacesApiKey}';

      final response = await ApiService.dio.get(url);
      final data = response.data;
      final status = data['status'];
      if (status != 'OK' && status != 'ZERO_RESULTS') {
        debugPrint('searchNearbyPlaces: non-OK status $status');
        return const [];
      }
      final results = data['results'] as List? ?? const [];
      final out = <NearbyPlace>[];
      for (final r in results) {
        if (r is! Map) continue;
        final place = NearbyPlace.fromJson(
          Map<String, dynamic>.from(r),
          origin: center,
        );
        if (place != null) out.add(place);
      }
      out.sort((a, b) => a.distanceMeters.compareTo(b.distanceMeters));
      return out;
    } catch (e) {
      debugPrint('searchNearbyPlaces failed: $e');
      return const [];
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

      // Best-effort: enrich with photos via Place Details lookup.
      final placeId = result['place_id'] as String?;
      final enriched =
          placeId == null ? null : await _safeGetPlaceDetails(placeId);

      return PlaceDetails(
        name: name,
        address: result['formatted_address'] ?? '',
        coordinates: coordinates,
        countryCode: _extractCountryCode(addressComponents),
        photoReference: enriched?.photoReference,
        photoReferences: enriched?.photoReferences,
        photoWidth: enriched?.photoWidth,
        photoHeight: enriched?.photoHeight,
        photoAttributions: enriched?.photoAttributions,
      );
    } catch (e) {
      debugPrint('Error getting place from coordinates: $e');
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