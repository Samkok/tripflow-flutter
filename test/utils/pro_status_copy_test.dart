import 'package:flutter_test/flutter_test.dart';
import 'package:voyza/utils/pro_status_copy.dart';

String _d(DateTime d) => '${d.day}/${d.month}/${d.year}';

void main() {
  final now = DateTime(2026, 11, 9, 12);

  group('describeProRow', () {
    test('free sells, pro states the renewal, lifetime says so', () {
      expect(describeProRow(ProStatus.free, now: now, formatDate: _d),
          (title: 'VoyZa Pro', subtitle: 'Add places and Auto-plan your days'));
      final ends = DateTime(2027, 3, 9);
      expect(
          describeProRow(
                  ProStatus(
                      tier: ProTier.pro, expiresAt: ends, willRenew: true),
                  now: now,
                  formatDate: _d)
              .subtitle,
          'Renews 9/3/2027');
      expect(
          describeProRow(
                  ProStatus(
                      tier: ProTier.pro, expiresAt: ends, willRenew: false),
                  now: now,
                  formatDate: _d)
              .subtitle,
          'Expires 9/3/2027');
      expect(
          describeProRow(ProStatus(tier: ProTier.pro, expiresAt: ends),
                  now: now, formatDate: _d)
              .subtitle,
          'Active until 9/3/2027');
      expect(
          describeProRow(const ProStatus(tier: ProTier.pro),
              now: now, formatDate: _d),
          (title: 'VoyZa Pro', subtitle: 'Lifetime'));
    });

    test('a trial counts down in hours, then tomorrow, then days', () {
      ProStatus trial(Duration left) =>
          ProStatus(tier: ProTier.trial, expiresAt: now.add(left));
      String sub(Duration left) =>
          describeProRow(trial(left), now: now, formatDate: _d).subtitle;
      expect(
          describeProRow(trial(const Duration(days: 2)),
                  now: now, formatDate: _d)
              .title,
          'VoyZa Pro trial');
      expect(sub(const Duration(minutes: 20)), 'Ends in 1 hour');
      expect(sub(const Duration(hours: 5)), 'Ends in 5 hours');
      expect(sub(const Duration(hours: 30)), 'Ends tomorrow');
      expect(sub(const Duration(hours: 37)), 'Ends in 2 days');
      expect(sub(const Duration(days: 3)), 'Ends in 3 days');
      expect(sub(Duration.zero), 'Ends today');
    });
  });

  test('formatRemaining', () {
    expect(formatRemaining(const Duration(days: 2, hours: 3)),
        '2 days, 3 hr left');
    expect(formatRemaining(const Duration(days: 1)), '1 day left');
    expect(formatRemaining(const Duration(hours: 5)), '5 hours left');
    expect(formatRemaining(const Duration(minutes: 1)), '1 min left');
    expect(formatRemaining(Duration.zero), 'Ending now');
  });

  test('planNameFor reads the store id', () {
    expect(planNameFor('yearly'), 'Yearly plan');
    expect(planNameFor('voyza_pro_annual'), 'Yearly plan');
    expect(planNameFor('monthly'), 'Monthly plan');
    expect(planNameFor('weekly_pro'), 'Weekly plan');
    expect(planNameFor('lifetime_unlock'), 'Lifetime');
    expect(planNameFor(null), 'VoyZa Pro');
  });

  test('trialProgress needs a real span', () {
    final status = ProStatus(
        tier: ProTier.trial,
        startedAt: now.subtract(const Duration(days: 1)),
        expiresAt: now.add(const Duration(days: 3)));
    expect(trialProgress(status, now: now), closeTo(0.25, 0.001));
    expect(
        trialProgress(
            ProStatus(
                tier: ProTier.trial,
                expiresAt: now.add(const Duration(days: 1))),
            now: now),
        isNull);
  });

  test('trialEndsSentence says what the free plan keeps and what it lacks', () {
    final ends = DateTime(2026, 11, 12);
    final renewing = ProStatus(
        tier: ProTier.trial,
        expiresAt: ends,
        willRenew: true,
        productId: 'yearly');
    final lapsing =
        ProStatus(tier: ProTier.trial, expiresAt: ends, willRenew: false);
    final a = trialEndsSentence(renewing, now: now, formatDate: _d);
    final b = trialEndsSentence(lapsing, now: now, formatDate: _d);
    expect(a, contains('Yearly plan billing starts on 12/11/2026'));
    expect(a, contains('adding places needs VoyZa Pro'));
    expect(b, contains('The trial ends on 12/11/2026'));
    expect(b, contains('You keep every trip'));
    expect(b, contains('adding places needs VoyZa Pro'));
  });
}
