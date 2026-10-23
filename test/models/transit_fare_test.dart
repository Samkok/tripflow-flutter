import 'package:flutter_test/flutter_test.dart';
import 'package:voyza/models/transit_fare.dart';

void main() {
  test('the API Money shape parses, with units as string or number', () {
    expect(
        TransitFare.parseMoney(
            {'currencyCode': 'HKD', 'units': '6', 'nanos': 500000000}),
        const TransitFare(currency: 'HKD', amount: 6.5));
    expect(TransitFare.parseMoney({'currencyCode': 'JPY', 'units': 230}),
        const TransitFare(currency: 'JPY', amount: 230));
    expect(TransitFare.parseMoney({'currencyCode': 'EUR', 'nanos': 900000000}),
        const TransitFare(currency: 'EUR', amount: 0.9));
  });

  test('absent, blank or malformed money is no fare', () {
    expect(TransitFare.parseMoney(null), isNull);
    expect(TransitFare.parseMoney({}), isNull);
    expect(TransitFare.parseMoney({'currencyCode': '', 'units': '3'}), isNull);
    expect(TransitFare.parseMoney('HKD 6.5'), isNull);
    expect(
        TransitFare.parseMoney({'currencyCode': 'HKD', 'units': '-1'}), isNull);
  });

  test('labels use the currency\'s own symbol and digits', () {
    expect(const TransitFare(currency: 'HKD', amount: 6.5).label, 'HK\$6.50');
    expect(const TransitFare(currency: 'JPY', amount: 230).label, '¥230');
    expect(const TransitFare(currency: 'USD', amount: 2.75).label, '\$2.75');
  });

  test('round-trips through the leg details map', () {
    const fare = TransitFare(currency: 'HKD', amount: 11);
    expect(TransitFare.fromJson(fare.toJson()), fare);
    expect(TransitFare.fromJson(fare), fare);
    expect(TransitFare.fromJson(null), isNull);
    expect(TransitFare.fromJson({'currency': 'HKD'}), isNull);
  });

  group('totalLabel', () {
    Map<String, dynamic> leg(String mode, [TransitFare? fare]) => {
          'mode': mode,
          if (fare != null) 'fare': fare.toJson(),
        };

    test('adds the day up per currency', () {
      expect(
          TransitFare.totalLabel([
            leg('transit', const TransitFare(currency: 'HKD', amount: 6.5)),
            leg('walk'),
            leg('transit', const TransitFare(currency: 'HKD', amount: 11)),
            leg('drive'),
          ]),
          'HK\$17.50');
      expect(
          TransitFare.totalLabel([
            leg('transit', const TransitFare(currency: 'HKD', amount: 6.5)),
            leg('transit', const TransitFare(currency: 'JPY', amount: 230)),
          ]),
          'HK\$6.50 + ¥230');
    });

    test('an unpriced ride makes the total a floor; no fares, no label', () {
      expect(
          TransitFare.totalLabel([
            leg('transit', const TransitFare(currency: 'HKD', amount: 6.5)),
            leg('transit'),
          ]),
          'HK\$6.50+');
      expect(TransitFare.totalLabel([leg('walk'), leg('drive')]), isNull);
      expect(TransitFare.totalLabel([leg('transit')]), isNull);
    });
  });
}
