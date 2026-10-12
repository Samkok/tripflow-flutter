import '../models/location_model.dart';

/// Place types whose Google place id names a destination someone can be
/// driven or walked to: the Routes API then ends the leg at the place's
/// access point, on the side of the road the entrance is on.
const Set<String> _destinationTypes = {
  'establishment',
  'point_of_interest',
  'premise',
  'subpremise',
  'street_address',
  'airport',
  'transit_station',
  'train_station',
  'bus_station',
  'subway_station',
  'lodging',
  'park',
  'tourist_attraction',
};

/// Place types whose id names an AREA or a ROAD. Routing to one of those
/// would end somewhere along or inside it, not at the pin: a place pasted
/// from a Maps link can carry such an id when the link's coordinates
/// reverse-geocoded to a street rather than a building.
const Set<String> _areaOrRoadTypes = {
  'route',
  'intersection',
  'street_number',
  'neighborhood',
  'colloquial_area',
  'locality',
  'sublocality',
  'sublocality_level_1',
  'sublocality_level_2',
  'sublocality_level_3',
  'sublocality_level_4',
  'sublocality_level_5',
  'administrative_area_level_1',
  'administrative_area_level_2',
  'administrative_area_level_3',
  'administrative_area_level_4',
  'administrative_area_level_5',
  'administrative_area_level_6',
  'administrative_area_level_7',
  'country',
  'continent',
  'archipelago',
  'postal_code',
  'postal_code_prefix',
  'postal_code_suffix',
  'postal_town',
  'plus_code',
  'natural_feature',
  'political',
};

/// The place id to route to for [place], or null to route to its
/// coordinates instead. Coordinates alone snap to the NEAREST road, which
/// for a place between two streets is as often the back street as the
/// front — the "route ends on the wrong side of the road" complaint. A
/// place id lets Google use the place's own access point. Unknown types
/// (older saved places) keep the id: nearly every saved place came from a
/// place search, whose ids are real destinations.
String? routingPlaceId(LocationModel place) {
  final id = place.placeId;
  if (id == null || id.isEmpty) return null;
  final types = place.placeTypes;
  if (types.any(_destinationTypes.contains)) return id;
  if (types.any(_areaOrRoadTypes.contains)) return null;
  return id;
}
