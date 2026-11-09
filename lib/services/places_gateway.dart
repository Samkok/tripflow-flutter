import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:google_maps_url_extractor/google_maps_url_extractor.dart';

import 'places_service.dart';

/// The text was not a Google Maps link at all.
class InvalidMapsLink implements Exception {
  const InvalidMapsLink();
}

/// Everything the add-a-place flow asks Google, behind one seam.
///
/// [PlacesService] is static; this is the object a test can replace. The
/// link decoder lives here as a concrete method on top of the two
/// geocoding primitives, so a fake that answers those two exercises the
/// real branching.
abstract class PlacesGateway {
  const PlacesGateway();

  Future<List<PlacePrediction>> searchPaginated(
    String query, {
    required int offset,
    required int limit,
    String? countryCodeOverride,
  });

  Future<PlaceDetails?> details(String placeId);

  Future<PlaceDetails?> fromCoordinates(LatLng coordinates);

  Future<PlaceDetails?> fromAddress(String address);

  Future<List<NearbyPlace>> nearby(LatLng center, {required int radiusMeters});

  Future<List<NearbyPlace>> nearbyByText(
    String query,
    LatLng center, {
    required int radiusMeters,
  });

  /// A pasted Google Maps link → the place it points at.
  ///
  /// Coordinates in the link win (reverse-geocoded); otherwise the link's
  /// `q=` query is geocoded, after expanding a short `goo.gl` link. Throws
  /// [InvalidMapsLink] when the text is not a Maps link; returns null when
  /// it is one but names nothing we can resolve.
  Future<PlaceDetails?> fromMapsLink(String text) async {
    final link = text.trim();
    if (!GoogleMapsUrlExtractor.isValidGoogleMapsUrl(link)) {
      throw const InvalidMapsLink();
    }
    try {
      final coords = await GoogleMapsUrlExtractor.processGoogleMapsUrl(link);
      final lat = coords?['latitude'];
      final lng = coords?['longitude'];
      if (lat != null && lng != null) {
        final place = await fromCoordinates(LatLng(lat, lng));
        if (place != null) return place;
      }
    } catch (_) {
      // Fall through to the query parameter.
    }
    var url = link;
    if (link.contains('goo.gl')) {
      try {
        url = await GoogleMapsUrlExtractor.expandShortUrl(link) ?? link;
      } catch (_) {}
    }
    final query = Uri.tryParse(url)?.queryParameters['q'];
    if (query == null || query.isEmpty) return null;
    return fromAddress(query);
  }
}

/// The production gateway: straight through to [PlacesService].
class StaticPlacesGateway extends PlacesGateway {
  const StaticPlacesGateway();

  @override
  Future<List<PlacePrediction>> searchPaginated(
    String query, {
    required int offset,
    required int limit,
    String? countryCodeOverride,
  }) =>
      PlacesService.searchPlacesPaginated(
        query,
        offset: offset,
        limit: limit,
        countryCodeOverride: countryCodeOverride,
      );

  @override
  Future<PlaceDetails?> details(String placeId) =>
      PlacesService.getPlaceDetails(placeId);

  @override
  Future<PlaceDetails?> fromCoordinates(LatLng coordinates) =>
      PlacesService.getPlaceFromCoordinates(coordinates);

  @override
  Future<PlaceDetails?> fromAddress(String address) =>
      PlacesService.getPlaceFromAddress(address);

  @override
  Future<List<NearbyPlace>> nearby(LatLng center,
          {required int radiusMeters}) =>
      PlacesService.searchNearbyPlaces(center, radiusMeters: radiusMeters);

  @override
  Future<List<NearbyPlace>> nearbyByText(String query, LatLng center,
          {required int radiusMeters}) =>
      PlacesService.searchNearbyByText(query, center,
          radiusMeters: radiusMeters);
}

final placesGatewayProvider =
    Provider<PlacesGateway>((_) => const StaticPlacesGateway());
