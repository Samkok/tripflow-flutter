import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';

/// What a transit itinerary costs, as the Routes API reports it
/// (`routes.travelAdvisory.transitFare`, a Money of currency + units +
/// nanos). Google publishes it for some agencies only — a route without
/// one simply shows no price.
@immutable
class TransitFare {
  const TransitFare({required this.currency, required this.amount});

  /// ISO 4217 code, e.g. "HKD".
  final String currency;
  final double amount;

  /// "HK$6.50", "¥230", "€2.90" — the currency's own symbol and digits.
  /// Dollar currencies keep their prefix (HK$, NT$, S$…): a traveller who
  /// just flew in must never read a Hong Kong fare as US dollars.
  String get label {
    try {
      final symbol = _symbols[currency];
      if (symbol != null) {
        return NumberFormat.currency(name: currency, symbol: symbol)
            .format(amount);
      }
      final simple = NumberFormat.simpleCurrency(name: currency);
      if (simple.currencySymbol == r'$' && currency != 'USD') {
        return NumberFormat.currency(name: currency, symbol: '$currency ')
            .format(amount);
      }
      return simple.format(amount);
    } catch (_) {
      return '$currency ${amount.toStringAsFixed(2)}';
    }
  }

  static const Map<String, String> _symbols = {
    'HKD': r'HK$',
    'TWD': r'NT$',
    'SGD': r'S$',
    'AUD': r'A$',
    'NZD': r'NZ$',
    'CAD': r'C$',
    'MXN': r'MX$',
    'CNY': 'CN¥',
    'JPY': '¥',
    'KRW': '₩',
    'THB': '฿',
    'VND': '₫',
    'PHP': '₱',
    'IDR': 'Rp ',
    'MYR': 'RM ',
    'INR': '₹',
    'GBP': '£',
    'EUR': '€',
    'USD': r'$',
  };

  /// The API's Money shape → a fare; null when absent or malformed.
  static TransitFare? parseMoney(Object? raw) {
    if (raw is! Map) return null;
    final currency = (raw['currencyCode'] as String? ?? '').trim();
    if (currency.isEmpty) return null;
    final units = raw['units'];
    final unitsNum = units is num
        ? units.toDouble()
        : units is String
            ? double.tryParse(units) ?? 0
            : 0.0;
    final nanos = (raw['nanos'] as num?)?.toDouble() ?? 0;
    final amount = unitsNum + nanos / 1e9;
    if (amount < 0) return null;
    return TransitFare(currency: currency, amount: amount);
  }

  Map<String, dynamic> toJson() => {'currency': currency, 'amount': amount};

  /// The fare a leg's details carry, if any.
  static TransitFare? ofLeg(Map? leg) => fromJson(leg?['fare']);

  /// The day's fares added up, per currency — "HK\$24", or "HK\$24 + ¥230"
  /// across currencies. A trailing "+" says the sum is a floor: at least
  /// one transit leg rides a line whose price Google does not publish.
  /// Null when no leg has a fare (nothing to claim).
  static String? totalLabel(Iterable<Map> legs) {
    final sums = <String, double>{};
    var partial = false;
    for (final leg in legs) {
      final fare = ofLeg(leg);
      if (fare == null) {
        if (leg['mode'] == 'transit') partial = true;
        continue;
      }
      sums[fare.currency] = (sums[fare.currency] ?? 0) + fare.amount;
    }
    if (sums.isEmpty) return null;
    final label = sums.entries
        .map((e) => TransitFare(currency: e.key, amount: e.value).label)
        .join(' + ');
    return partial ? '$label+' : label;
  }

  static TransitFare? fromJson(Object? raw) {
    if (raw is TransitFare) return raw;
    if (raw is! Map) return null;
    final currency = raw['currency'] as String?;
    final amount = (raw['amount'] as num?)?.toDouble();
    if (currency == null || currency.isEmpty || amount == null) return null;
    return TransitFare(currency: currency, amount: amount);
  }

  @override
  bool operator ==(Object other) =>
      other is TransitFare &&
      other.currency == currency &&
      other.amount == amount;

  @override
  int get hashCode => Object.hash(currency, amount);

  @override
  String toString() => 'TransitFare($label)';
}
