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
}
