import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/places_service.dart';

final placesSearchProvider = FutureProvider.family<List<PlacePrediction>, String>(
  (ref, query) async {
    if (query.isEmpty) return [];
    return await PlacesService.searchPlaces(query);
  },
);

final placeFromUrlProvider = FutureProvider.family<PlaceDetails?, String>(
  (ref, url) async {
    if (url.isEmpty) return null;
    return await PlacesService.getPlaceFromGoogleMapsUrl(url);
  },
);