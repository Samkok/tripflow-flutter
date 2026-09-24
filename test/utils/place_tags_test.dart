import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyza/core/theme.dart';
import 'package:voyza/utils/marker_utils.dart';
import 'package:voyza/utils/place_tags.dart';

void main() {
  group('suggestPlaceTag', () {
    test('maps the common Google types', () {
      expect(suggestPlaceTag(['restaurant', 'food', 'point_of_interest']),
          PlaceTag.food);
      expect(
          suggestPlaceTag(['museum', 'tourist_attraction']), PlaceTag.culture);
      expect(suggestPlaceTag(['park']), PlaceTag.nature);
      expect(suggestPlaceTag(['shopping_mall']), PlaceTag.shopping);
      expect(suggestPlaceTag(['night_club', 'bar']), PlaceTag.nightlife);
      expect(suggestPlaceTag(['transit_station']), PlaceTag.transport);
      expect(suggestPlaceTag(['lodging']), PlaceTag.stay);
      expect(suggestPlaceTag(['tourist_attraction']), PlaceTag.sights);
    });

    test('most specific rule wins when types overlap', () {
      // A hotel bar is a place to stay; a market that is also an attraction
      // is a shop; a bar that also serves food is nightlife.
      expect(suggestPlaceTag(['bar', 'lodging']), PlaceTag.stay);
      expect(
          suggestPlaceTag(['tourist_attraction', 'market']), PlaceTag.shopping);
      expect(suggestPlaceTag(['restaurant', 'bar']), PlaceTag.nightlife);
    });

    test('generic types suggest nothing', () {
      expect(suggestPlaceTag(['point_of_interest', 'establishment']), isNull);
      expect(suggestPlaceTag(const []), isNull);
      expect(suggestPlaceTag(['locality', 'political']), isNull);
    });

    test('is case- and whitespace-tolerant', () {
      expect(suggestPlaceTag([' Cafe ']), PlaceTag.food);
    });
  });

  group('keys and colours', () {
    test('every tag round-trips through its key', () {
      for (final t in PlaceTag.values) {
        expect(placeTagFromKey(t.key), t);
        expect(placeTagColor(t.key), t.color);
      }
      expect(placeTagFromKey('bogus'), isNull);
      expect(placeTagFromKey(null), isNull);
      expect(placeTagColor(null), isNull);
    });

    test('tag colours are distinct from each other and from status colours',
        () {
      final reserved = <Color>{
        Colors.green.shade500, // done
        Colors.green.shade600, // start
        MarkerUtils.warningAmber, // might be closed
        AppTheme.accentColor, // untagged default pin
        AppTheme.primaryColor, // routes + arrival ring
      };
      final seen = <int>{};
      for (final t in PlaceTag.values) {
        expect(reserved.contains(t.color), isFalse,
            reason: '${t.label} reuses a status colour');
        expect(seen.add(t.color.toARGB32()), isTrue,
            reason: '${t.label} shares a colour with another tag');
      }
    });
  });

  group('transport modes', () {
    test('the mode comes from the place types, most specific first', () {
      expect(transportModeFor(['airport', 'bus_station', 'establishment']),
          TransportMode.air);
      expect(transportModeFor(['ferry_terminal', 'transit_station']),
          TransportMode.ferry);
      expect(transportModeFor(['train_station', 'bus_station']),
          TransportMode.rail);
      expect(transportModeFor(['subway_station']), TransportMode.rail);
      expect(transportModeFor(['bus_stop']), TransportMode.bus);
      expect(transportModeFor(['car_rental']), TransportMode.road);
      expect(transportModeFor(['transit_station']), TransportMode.other,
          reason: 'a bare transit_station says nothing about the mode');
      expect(transportModeFor(null), TransportMode.other);
      expect(transportModeFor(const []), TransportMode.other);
      expect(transportModeFor([' AIRPORT ']), TransportMode.air);
    });

    test('a Transport place shows its mode; other tags are unchanged', () {
      const airport = ['airport', 'point_of_interest'];
      expect(placeTagLabel(PlaceTag.transport, airport), 'Airport');
      expect(placeTagIcon(PlaceTag.transport, airport), Icons.flight_rounded);
      expect(placeTagLabel(PlaceTag.transport, ['train_station']), 'Train');
      expect(
          placeTagLabel(PlaceTag.transport, ['transit_station']), 'Transport');
      expect(placeTagLabel(PlaceTag.transport, null), 'Transport');
      expect(placeTagIcon(PlaceTag.transport, null),
          Icons.directions_transit_rounded);
      // A museum next to a station is still Culture.
      expect(placeTagLabel(PlaceTag.culture, ['train_station']), 'Culture');
      expect(placeTagIcon(PlaceTag.culture, ['train_station']),
          PlaceTag.culture.icon);
    });

    test('a hand-picked mode wins over Google and can be handed back', () {
      const google = ['transit_station', 'point_of_interest'];
      // Google says nothing useful → the traveller picks Train.
      final picked = placeTypesWithModeOverride(google, TransportMode.rail);
      expect(picked, [...google, 'voyza:mode:rail']);
      expect(transportModeFor(picked), TransportMode.rail);
      expect(transportModeOverride(picked), TransportMode.rail);
      expect(placeTagLabel(PlaceTag.transport, picked), 'Train');
      // Google's own suggestion is untouched by the marker.
      expect(suggestPlaceTag(picked), PlaceTag.transport);
      // Picking again replaces, not stacks.
      final repicked = placeTypesWithModeOverride(picked, TransportMode.bus);
      expect(repicked.where((t) => t.startsWith('voyza:mode:')).length, 1);
      expect(transportModeFor(repicked), TransportMode.bus);
      // The choice beats a Google type that disagrees.
      expect(transportModeFor(['airport', 'voyza:mode:ferry']),
          TransportMode.ferry);
      // Handing back: Google decides again; a pin with no types is plain.
      expect(transportModeFor(placeTypesWithModeOverride(repicked, null)),
          TransportMode.other);
      expect(placeTypesWithModeOverride(null, TransportMode.air),
          ['voyza:mode:air']);
      expect(transportModeFor(['voyza:mode:other']), TransportMode.other);
    });

    test('every mode has its own label and icon', () {
      final labels = {for (final m in TransportMode.values) m.label};
      final icons = {for (final m in TransportMode.values) m.icon};
      expect(labels.length, TransportMode.values.length);
      expect(icons.length, TransportMode.values.length);
    });
  });
}
