import 'package:flutter/material.dart';

/// The fixed set of place tags. A stop stores its tag as [PlaceTagX.key];
/// the single-day map paints the pin in the tag's colour (status still
/// wins: done, skipped and the amber "might be closed" keep their own
/// treatment, and Entire-trip mode keeps its day colours).
///
/// Colours are chosen to stay clear of every colour that already means
/// something on the map: done green, skipped grey, warning amber, the coral
/// default pin and the cyan of routes and the arrival ring.
enum PlaceTag {
  food,
  sights,
  culture,
  nature,
  shopping,
  nightlife,
  transport,
  stay,
}

extension PlaceTagX on PlaceTag {
  /// Stored value (`locations.tag`).
  String get key => name;

  String get label => switch (this) {
        PlaceTag.food => 'Food & drink',
        PlaceTag.sights => 'Sights',
        PlaceTag.culture => 'Culture',
        PlaceTag.nature => 'Nature',
        PlaceTag.shopping => 'Shopping',
        PlaceTag.nightlife => 'Nightlife',
        PlaceTag.transport => 'Transport',
        PlaceTag.stay => 'Stay',
      };

  Color get color => switch (this) {
        PlaceTag.food => const Color(0xFFFF4FA3), // pink
        PlaceTag.sights => const Color(0xFF8E5CFF), // violet
        PlaceTag.culture => const Color(0xFFB07A3B), // bronze
        PlaceTag.nature => const Color(0xFF00B3A4), // teal
        PlaceTag.shopping => const Color(0xFFC0CA33), // lime
        PlaceTag.nightlife => const Color(0xFF7E1FA8), // deep purple
        PlaceTag.transport => const Color(0xFF4A90E2), // steel blue
        PlaceTag.stay => const Color(0xFF2B4C9E), // navy
      };

  IconData get icon => switch (this) {
        PlaceTag.food => Icons.restaurant_rounded,
        PlaceTag.sights => Icons.photo_camera_rounded,
        PlaceTag.culture => Icons.museum_rounded,
        PlaceTag.nature => Icons.park_rounded,
        PlaceTag.shopping => Icons.shopping_bag_rounded,
        PlaceTag.nightlife => Icons.nightlife_rounded,
        PlaceTag.transport => Icons.directions_transit_rounded,
        PlaceTag.stay => Icons.hotel_rounded,
      };
}

/// What kind of transport hub a Transport-tagged place is, read from its
/// Google types when it is shown. One tag — one colour on the map — but the
/// airport reads "Airport" with a plane, the station "Train" with a train.
/// Nothing new is stored, so existing rows and older app builds are
/// unaffected.
enum TransportMode { air, rail, bus, ferry, road, other }

extension TransportModeX on TransportMode {
  String get label => switch (this) {
        TransportMode.air => 'Airport',
        TransportMode.rail => 'Train',
        TransportMode.bus => 'Bus',
        TransportMode.ferry => 'Ferry',
        TransportMode.road => 'Taxi & car',
        TransportMode.other => 'Transport',
      };

  IconData get icon => switch (this) {
        TransportMode.air => Icons.flight_rounded,
        TransportMode.rail => Icons.train_rounded,
        TransportMode.bus => Icons.directions_bus_rounded,
        TransportMode.ferry => Icons.directions_boat_rounded,
        TransportMode.road => Icons.local_taxi_rounded,
        TransportMode.other => Icons.directions_transit_rounded,
      };
}

/// Most specific first: an airport with a bus stop is an airport, a ferry
/// pier that is also a "transit_station" is a ferry, an interchange with
/// trains and buses is a train station. A bare `transit_station` says
/// nothing about the mode.
const _modeRules = <(TransportMode, Set<String>)>[
  (
    TransportMode.air,
    {'airport', 'international_airport', 'heliport', 'airstrip'}
  ),
  (TransportMode.ferry, {'ferry_terminal'}),
  (
    TransportMode.rail,
    {'train_station', 'subway_station', 'light_rail_station'}
  ),
  (TransportMode.bus, {'bus_station', 'bus_stop'}),
  (TransportMode.road, {'taxi_stand', 'car_rental', 'park_and_ride'}),
];

/// A mode the traveller chose by hand is kept in the place's type list as
/// `voyza:mode:<name>`: it syncs and copies with the place like any type,
/// wins over Google's types, and older builds — which only ever look up
/// Google's names — simply ignore it. Needed for pins Google never
/// classified and for the odd interchange Google gets wrong.
const _modeOverridePrefix = 'voyza:mode:';

String transportModeOverrideToken(TransportMode mode) =>
    '$_modeOverridePrefix${mode.name}';

/// The hand-picked mode in [googleTypes], or null when the traveller has
/// not chosen one.
TransportMode? transportModeOverride(Iterable<String>? googleTypes) {
  if (googleTypes == null) return null;
  for (final t in googleTypes) {
    if (!t.startsWith(_modeOverridePrefix)) continue;
    final name = t.substring(_modeOverridePrefix.length);
    for (final m in TransportMode.values) {
      if (m.name == name && m != TransportMode.other) return m;
    }
  }
  return null;
}

/// [googleTypes] with the hand-picked mode set to [mode]; null removes any
/// previous choice so Google's own types decide again.
List<String> placeTypesWithModeOverride(
        Iterable<String>? googleTypes, TransportMode? mode) =>
    [
      for (final t in googleTypes ?? const <String>[])
        if (!t.startsWith(_modeOverridePrefix)) t,
      if (mode != null && mode != TransportMode.other)
        transportModeOverrideToken(mode),
    ];

/// The transport mode of a place: the traveller's own choice when there is
/// one, else what its Google types describe, else [TransportMode.other].
TransportMode transportModeFor(Iterable<String>? googleTypes) {
  if (googleTypes == null) return TransportMode.other;
  final chosen = transportModeOverride(googleTypes);
  if (chosen != null) return chosen;
  final types = {for (final t in googleTypes) t.trim().toLowerCase()};
  for (final (mode, members) in _modeRules) {
    if (types.any(members.contains)) return mode;
  }
  return TransportMode.other;
}

/// The icon to show for a place tagged [tag]: the transport mode's icon on
/// Transport, the tag's own icon otherwise.
IconData placeTagIcon(PlaceTag tag, Iterable<String>? googleTypes) =>
    tag == PlaceTag.transport ? transportModeFor(googleTypes).icon : tag.icon;

/// The label to show for a place tagged [tag]: "Airport", "Train", … on
/// Transport when the mode is known, the tag's label otherwise.
String placeTagLabel(PlaceTag tag, Iterable<String>? googleTypes) {
  if (tag != PlaceTag.transport) return tag.label;
  final mode = transportModeFor(googleTypes);
  return mode == TransportMode.other ? tag.label : mode.label;
}

/// The tag stored under [key], or null for an unknown / missing key.
PlaceTag? placeTagFromKey(String? key) {
  if (key == null) return null;
  for (final t in PlaceTag.values) {
    if (t.key == key) return t;
  }
  return null;
}

/// Pin colour for a stored tag key; null when untagged (or unknown).
Color? placeTagColor(String? key) => placeTagFromKey(key)?.color;

/// The tag Google's place [googleTypes] point to, or null when they say
/// nothing useful (`point_of_interest`, `establishment`, addresses…).
/// The rules run most-specific first, so a hotel bar suggests Stay, a
/// museum café suggests Culture, and a market that is also a tourist
/// attraction suggests Shopping.
PlaceTag? suggestPlaceTag(Iterable<String> googleTypes) {
  final types = {for (final t in googleTypes) t.trim().toLowerCase()};
  if (types.isEmpty) return null;
  for (final (tag, members) in _typeRules) {
    if (types.any(members.contains)) return tag;
  }
  return null;
}

/// Google place types (legacy and new API names) per tag, in precedence
/// order. A type listed under two tags belongs to the first.
const _typeRules = <(PlaceTag, Set<String>)>[
  (
    PlaceTag.stay,
    {
      'lodging',
      'hotel',
      'motel',
      'hostel',
      'guest_house',
      'bed_and_breakfast',
      'resort_hotel',
      'extended_stay_hotel',
      'inn',
      'campground',
      'rv_park',
    }
  ),
  (
    PlaceTag.transport,
    {
      'airport',
      'international_airport',
      'heliport',
      'train_station',
      'transit_station',
      'subway_station',
      'light_rail_station',
      'bus_station',
      'bus_stop',
      'ferry_terminal',
      'taxi_stand',
      'car_rental',
      'park_and_ride',
      'transit_depot',
    }
  ),
  (
    PlaceTag.nightlife,
    {
      'night_club',
      'bar',
      'pub',
      'wine_bar',
      'karaoke',
      'casino',
      'comedy_club',
      'dance_hall',
    }
  ),
  (
    PlaceTag.food,
    {
      'restaurant',
      'cafe',
      'coffee_shop',
      'bakery',
      'meal_takeaway',
      'meal_delivery',
      'food',
      'food_court',
      'ice_cream_shop',
      'dessert_shop',
      'tea_house',
      'fast_food_restaurant',
      'brunch_restaurant',
      'breakfast_restaurant',
      'juice_shop',
      'sandwich_shop',
      'pizza_restaurant',
      'sushi_restaurant',
      'ramen_restaurant',
      'steak_house',
      'seafood_restaurant',
      'vegan_restaurant',
      'vegetarian_restaurant',
      'diner',
      'bistro',
      'cafeteria',
      'candy_store',
      'chocolate_shop',
      'confectionery',
      'donut_shop',
    }
  ),
  (
    PlaceTag.culture,
    {
      'museum',
      'art_gallery',
      'art_studio',
      'library',
      'church',
      'hindu_temple',
      'mosque',
      'synagogue',
      'place_of_worship',
      'monastery',
      'performing_arts_theater',
      'cultural_center',
      'cultural_landmark',
      'historical_place',
      'opera_house',
      'concert_hall',
      'philharmonic_hall',
      'auditorium',
    }
  ),
  (
    PlaceTag.nature,
    {
      'park',
      'national_park',
      'state_park',
      'natural_feature',
      'beach',
      'garden',
      'botanical_garden',
      'hiking_area',
      'marina',
      'wildlife_park',
      'wildlife_refuge',
      'dog_park',
      'picnic_ground',
      'scenic_spot',
      'forest',
      'lake',
      'river',
      'mountain',
      'waterfall',
    }
  ),
  (
    PlaceTag.shopping,
    {
      'shopping_mall',
      'shopping_center',
      'store',
      'supermarket',
      'market',
      'market_place',
      'grocery_or_supermarket',
      'grocery_store',
      'clothing_store',
      'department_store',
      'convenience_store',
      'book_store',
      'electronics_store',
      'jewelry_store',
      'shoe_store',
      'gift_shop',
      'liquor_store',
      'florist',
      'home_goods_store',
      'furniture_store',
      'outlet',
      'discount_store',
      'sporting_goods_store',
      'pet_store',
      'warehouse_store',
    }
  ),
  (
    PlaceTag.sights,
    {
      'tourist_attraction',
      'landmark',
      'historical_landmark',
      'monument',
      'amusement_park',
      'theme_park',
      'water_park',
      'roller_coaster',
      'ferris_wheel',
      'zoo',
      'aquarium',
      'stadium',
      'observation_deck',
      'plaza',
      'town_square',
      'castle',
      'palace',
      'fortress',
      'bridge',
      'tower',
      'viewpoint',
      'sculpture',
      'planetarium',
      'visitor_center',
    }
  ),
];
