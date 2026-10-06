import 'measurement_region.dart';

/// What, if anything, to put in front of the person.
enum MeasurementAsk {
  nothing,

  /// The opt-in prompt with both purposes.
  consent,

  /// The one-time "how we measure our ads is changing" notice.
  notice,
}

/// What the person has said so far. Null means never asked — which is not
/// a no, and not a yes.
class MeasurementChoices {
  const MeasurementChoices(
      {this.analytics, this.ads, this.noticeShown = false});

  final bool? analytics;
  final bool? ads;

  /// Whether the notice for people outside the consent region was shown.
  final bool noticeShown;

  MeasurementChoices copyWith({
    bool? analytics,
    bool? ads,
    bool? noticeShown,
  }) =>
      MeasurementChoices(
        analytics: analytics ?? this.analytics,
        ads: ads ?? this.ads,
        noticeShown: noticeShown ?? this.noticeShown,
      );

  @override
  bool operator ==(Object other) =>
      other is MeasurementChoices &&
      other.analytics == analytics &&
      other.ads == ads &&
      other.noticeShown == noticeShown;

  @override
  int get hashCode => Object.hash(analytics, ads, noticeShown);
}

/// What may run right now, and what to ask.
class MeasurementDecision {
  const MeasurementDecision({
    required this.region,
    required this.analytics,
    required this.ads,
    required this.ask,
  });

  final MeasurementRegion region;

  /// Usage analytics may run.
  final bool analytics;

  /// Ads measurement may run.
  final bool ads;

  final MeasurementAsk ask;

  @override
  bool operator ==(Object other) =>
      other is MeasurementDecision &&
      other.region == region &&
      other.analytics == analytics &&
      other.ads == ads &&
      other.ask == ask;

  @override
  int get hashCode => Object.hash(region, analytics, ads, ask);

  @override
  String toString() =>
      'MeasurementDecision(${region.name}, analytics: $analytics, '
      'ads: $ads, ask: ${ask.name})';
}

/// The rules, in one place.
///
/// * A choice the person made stands, wherever they are.
/// * Consent region, no choice yet: nothing runs, and they are asked.
/// * Elsewhere, no choice yet: analytics runs; ads measurement runs only
///   once the notice has been shown, and the notice is what gets asked.
/// * Unknown region, no choice yet: nothing runs and nothing is asked —
///   the answer waits until we can tell where the person is.
MeasurementDecision decideMeasurement({
  required MeasurementChoices choices,
  required MeasurementRegion region,
}) {
  final open = region == MeasurementRegion.open;
  final analytics = choices.analytics ?? open;
  final ads = choices.ads ?? (open && choices.noticeShown);

  final MeasurementAsk ask;
  switch (region) {
    case MeasurementRegion.consentRequired:
      ask = choices.analytics == null || choices.ads == null
          ? MeasurementAsk.consent
          : MeasurementAsk.nothing;
    case MeasurementRegion.open:
      ask = choices.ads == null && !choices.noticeShown
          ? MeasurementAsk.notice
          : MeasurementAsk.nothing;
    case MeasurementRegion.unknown:
      ask = MeasurementAsk.nothing;
  }
  return MeasurementDecision(
    region: region,
    analytics: analytics,
    ads: ads,
    ask: ask,
  );
}
