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
