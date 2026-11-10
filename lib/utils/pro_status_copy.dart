/// Pure copy for the one subscription surface: what the Settings row says
/// and what the trial block says. No Flutter here, so every branch is a
/// unit test.
library;

enum ProTier { free, trial, pro }

/// Free, in the trial, or paying — with the dates the copy needs.
class ProStatus {
  const ProStatus({
    required this.tier,
    this.expiresAt,
    this.startedAt,
    this.willRenew,
    this.productId,
  });

  final ProTier tier;

  /// When the entitlement ends; null for a lifetime unlock.
  final DateTime? expiresAt;

  /// When the current period (the trial) began; null when unknown.
  final DateTime? startedAt;

  final bool? willRenew;
  final String? productId;

  static const free = ProStatus(tier: ProTier.free);

  bool get isLifetime => tier == ProTier.pro && expiresAt == null;
}

typedef FormatDate = String Function(DateTime date);

/// Title and subtitle of the Settings row.
({String title, String subtitle}) describeProRow(
  ProStatus status, {
  required DateTime now,
  required FormatDate formatDate,
}) {
  switch (status.tier) {
    case ProTier.free:
      return (
        title: 'VoyZa Pro',
        subtitle: 'Add places and Auto-plan your days'
      );
    case ProTier.trial:
      final ends = status.expiresAt;
      if (ends == null) return (title: 'VoyZa Pro trial', subtitle: 'Active');
      return (
        title: 'VoyZa Pro trial',
        subtitle: _trialEndsIn(ends.difference(now)),
      );
    case ProTier.pro:
      final ends = status.expiresAt;
      if (ends == null) return (title: 'VoyZa Pro', subtitle: 'Lifetime');
      final date = formatDate(ends);
      return (
        title: 'VoyZa Pro',
        subtitle: switch (status.willRenew) {
          true => 'Renews $date',
          false => 'Expires $date',
          null => 'Active until $date',
        },
      );
  }
}

String _trialEndsIn(Duration remaining) {
  if (remaining <= Duration.zero) return 'Ends today';
  if (remaining < const Duration(hours: 24)) {
    final hours = remaining.inHours < 1 ? 1 : remaining.inHours;
    return 'Ends in $hours hour${hours == 1 ? '' : 's'}';
  }
  if (remaining <= const Duration(hours: 36)) return 'Ends tomorrow';
  final days = (remaining.inMinutes / Duration.minutesPerDay).ceil();
  return 'Ends in $days days';
}

/// The countdown the banner and the subscription screen share:
/// "2 days, 3 hr left", "5 hours left", "12 mins left".
String formatRemaining(Duration d) {
  if (d <= Duration.zero) return 'Ending now';
  final days = d.inDays;
  if (days >= 1) {
    final hours = d.inHours.remainder(24);
    return hours > 0
        ? '$days day${days == 1 ? '' : 's'}, $hours hr left'
        : '$days day${days == 1 ? '' : 's'} left';
  }
  if (d.inHours >= 1) {
    final hours = d.inHours;
    return '$hours hour${hours == 1 ? '' : 's'} left';
  }
  final minutes = d.inMinutes;
  return '$minutes min${minutes == 1 ? '' : 's'} left';
}

/// The plan a store product id stands for.
String planNameFor(String? productId) {
  final id = (productId ?? '').toLowerCase();
  if (id.contains('lifetime')) return 'Lifetime';
  if (id.contains('year') || id.contains('annual')) return 'Yearly plan';
  if (id.contains('month')) return 'Monthly plan';
  if (id.contains('week')) return 'Weekly plan';
  return 'VoyZa Pro';
}

/// How far through the trial we are, 0–1; null when the start is unknown,
/// so a bar is never drawn from a guessed length.
double? trialProgress(ProStatus status, {required DateTime now}) {
  final start = status.startedAt;
  final end = status.expiresAt;
  if (start == null || end == null || !end.isAfter(start)) return null;
  final span = end.difference(start).inSeconds;
  return (now.difference(start).inSeconds / span).clamp(0.0, 1.0);
}

/// One sentence on what happens when the trial ends: either billing
/// starts, or the person is back on the free plan, where trips stay but
/// adding places needs Pro.
String trialEndsSentence(
  ProStatus status, {
  required DateTime now,
  required FormatDate formatDate,
}) {
  final ends = status.expiresAt;
  final when = ends == null ? 'when the trial ends' : 'on ${formatDate(ends)}';
  if (status.willRenew == true) {
    return '${planNameFor(status.productId)} billing starts $when. Cancel '
        'before then and you keep every trip; adding places needs VoyZa Pro.';
  }
  return 'The trial ends $when. You keep every trip; adding places needs '
      'VoyZa Pro.';
}
