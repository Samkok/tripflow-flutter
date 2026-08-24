import 'package:flutter_test/flutter_test.dart';
import 'package:voyza/utils/plan_pricing.dart';

void main() {
  group('annualSavingsPercent', () {
    test('uses 12x monthly as the baseline', () {
      // 5.99*12 = 71.88 -> (71.88-39.99)/71.88 = 44.36% -> 44
      expect(
        annualSavingsPercent(annualPrice: 39.99, monthlyPrice: 5.99),
        44,
      );
    });

    test('uses 52x weekly when monthly is absent', () {
      // 4.99*52 = 259.48 -> (259.48-39.99)/259.48 = 84.6% -> 85
      expect(
        annualSavingsPercent(annualPrice: 39.99, weeklyPrice: 4.99),
        85,
      );
    });

    test('compares against the CHEAPEST alternative when both exist', () {
      // monthly baseline 71.88 < weekly baseline 259.48 -> 44, not 85
      expect(
        annualSavingsPercent(
            annualPrice: 39.99, monthlyPrice: 5.99, weeklyPrice: 4.99),
        44,
      );
    });

    test('null when annual is not actually cheaper', () {
      expect(
        annualSavingsPercent(annualPrice: 79.99, monthlyPrice: 5.99),
        null,
      );
      // Exactly equal -> 0% -> null, never "Save 0%".
      expect(
        annualSavingsPercent(annualPrice: 71.88, monthlyPrice: 5.99),
        null,
      );
    });

    test('null without any baseline or with junk prices', () {
      expect(annualSavingsPercent(annualPrice: 39.99), null);
      expect(
        annualSavingsPercent(annualPrice: 39.99, monthlyPrice: 0),
        null,
      );
      expect(
        annualSavingsPercent(annualPrice: 0, monthlyPrice: 5.99),
        null,
      );
    });
  });

  group('perWeekOfAnnual / perMonthOfAnnual', () {
    test('formats the divided price in the product currency', () {
      expect(
        perWeekOfAnnual(annualPrice: 39.99, currencyCode: 'USD'),
        '\$0.77',
      );
      expect(
        perMonthOfAnnual(annualPrice: 39.99, currencyCode: 'USD'),
        '\$3.33',
      );
    });

    test('null on junk input', () {
      expect(perWeekOfAnnual(annualPrice: 0, currencyCode: 'USD'), null);
      expect(perWeekOfAnnual(annualPrice: -1, currencyCode: 'USD'), null);
      expect(perWeekOfAnnual(annualPrice: 39.99, currencyCode: ''), null);
    });

    test('unknown currency codes still format rather than crash', () {
      final label = perWeekOfAnnual(annualPrice: 39.99, currencyCode: 'KHR');
      expect(label, isNotNull);
      expect(label, contains('0.77'));
    });
  });
}
