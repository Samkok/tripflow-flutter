import 'package:flutter_test/flutter_test.dart';
import 'package:voyza/models/saved_location.dart';
import 'package:voyza/services/subscription_limit_service.dart';

Map<String, dynamic> _row({String? handedOverFrom}) => {
      'id': 'loc1',
      'user_id': 'owner',
      'name': 'Tim Ho Wan',
      'lat': 22.3,
      'lng': 114.1,
      'created_at': '2026-09-01T00:00:00.000Z',
      'fingerprint': 'fp',
      'trip_id': 'trip1',
      if (handedOverFrom != null) 'handed_over_from': handedOverFrom,
    };

void main() {
  test('handed_over_from marks the row; its absence does not', () {
    expect(SavedLocation.fromJson(_row()).handedOver, isFalse);
    expect(SavedLocation.fromJson(_row(handedOverFrom: 'ex-member')).handedOver,
        isTrue);
  });

  test('the marker is server-owned: never sent back', () {
    final json =
        SavedLocation.fromJson(_row(handedOverFrom: 'ex-member')).toJson();
    expect(json.containsKey('handed_over_from'), isFalse);
    expect(json.containsKey('handed_over'), isFalse);
  });

  test('handed-over places do not count against the allowance', () {
    final own = SavedLocation.fromJson(_row());
    final inherited = SavedLocation.fromJson(_row(handedOverFrom: 'ex-member'));
    expect(SubscriptionLimitService.countsAsOwnPlace(own, 'owner'), isTrue);
    expect(
        SubscriptionLimitService.countsAsOwnPlace(inherited, 'owner'), isFalse);
    expect(SubscriptionLimitService.countsAsOwnPlace(own, 'someone'), isFalse);
  });

  test('copyWith keeps the marker', () {
    final inherited = SavedLocation.fromJson(_row(handedOverFrom: 'ex-member'));
    expect(inherited.copyWith(name: 'x').handedOver, isTrue);
  });
}
