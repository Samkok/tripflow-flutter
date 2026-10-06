/// Build switch for the two-purpose measurement consent ("Usage analytics"
/// and "Ads measurement") and everything that hangs off it: the prompts,
/// the two Settings switches, Meta's SDK and Apple's tracking prompt.
///
/// ON by default since the release that added Meta's SDK. That release goes
/// out together with the revised privacy policy, the `request_country`
/// database function and the updated store declarations (see
/// docs/meta-ads-playbook.md and legal/DRAFT-privacy-policy-meta-ads.md);
/// it must not ship without them.
///
/// The switch stays as a way back. This build behaves like the releases
/// before it (one analytics choice, decided from the device region, and
/// Meta's SDK never started):
///
///     flutter build ... --dart-define=VOYZA_ADS_MEASUREMENT=false
class MeasurementConfig {
  const MeasurementConfig._();

  static const bool adsMeasurement = bool.fromEnvironment(
    'VOYZA_ADS_MEASUREMENT',
    defaultValue: true,
  );
}
