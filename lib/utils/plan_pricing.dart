/// Pure pricing math for the paywall's plan cards.
///
/// Kept free of widget state so the store-price arithmetic (savings %, the
/// per-week anchor line) is unit-testable — a wrong number here is a
/// misleading-pricing store rejection, not a cosmetic bug. All inputs come
/// from live StoreProduct prices, never hardcoded amounts.
library;

import 'dart:math' as math;

import 'package:intl/intl.dart';

/// Percent saved by the annual plan versus the cheapest way to cover a year
/// with the shorter plans on offer (12 × monthly and/or 52 × weekly).
///
/// Comparing against the CHEAPEST alternative keeps the claim defensible.
/// Null when no baseline exists or the annual plan isn't actually cheaper.
int? annualSavingsPercent({
  required double annualPrice,
  double? monthlyPrice,
  double? weeklyPrice,
}) {
  if (annualPrice <= 0) return null;
  final baselines = <double>[
    if (monthlyPrice != null && monthlyPrice > 0) monthlyPrice * 12,
    if (weeklyPrice != null && weeklyPrice > 0) weeklyPrice * 52,
  ];
  if (baselines.isEmpty) return null;
  final baseline = baselines.reduce(math.min);
  final pct = ((baseline - annualPrice) / baseline * 100).round();
  return pct > 0 ? pct : null;
}

/// The annual price expressed per week (e.g. "\$0.77"), or null when it
/// can't be formatted safely. Used to anchor the yearly plan against the
/// weekly Trip Pass's headline price.
String? perWeekOfAnnual({
  required double annualPrice,
  required String currencyCode,
}) =>
    _perPeriod(annualPrice, 52, currencyCode);

/// The annual price expressed per month (e.g. "\$3.33"), or null when it
/// can't be formatted safely.
String? perMonthOfAnnual({
  required double annualPrice,
  required String currencyCode,
}) =>
    _perPeriod(annualPrice, 12, currencyCode);

String? _perPeriod(double annualPrice, int divisor, String currencyCode) {
  if (annualPrice <= 0 || currencyCode.isEmpty) return null;
  try {
    return NumberFormat.simpleCurrency(name: currencyCode)
        .format(annualPrice / divisor);
  } catch (_) {
    return null;
  }
}
