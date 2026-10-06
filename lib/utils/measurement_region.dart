/// Where a person is, as far as consent to measurement is concerned.
enum MeasurementRegion {
  /// EEA, UK or Switzerland: nothing non-essential runs before an opt-in.
  consentRequired,

  /// Anywhere else: on by default, with a way to switch it off.
  open,

  /// We cannot tell. Treated like [consentRequired] for what runs (nothing),
  /// but nobody is asked anything until we can tell.
  unknown,
}

/// Countries where analytics and ads measurement need an opt-in: the EU
/// member states, the rest of the EEA (IS, LI, NO), the United Kingdom and
/// Switzerland — plus the parts of member states that carry their own
/// country code but sit inside EU data-protection law (the French overseas
/// departments and Saint-Martin, and Åland), which is what a connection
/// from there reports.
const Set<String> consentRegionCountries = {
  'AT', 'BE', 'BG', 'HR', 'CY', 'CZ', 'DK', 'EE', 'FI', 'FR', 'DE', 'GR',
  'HU', 'IE', 'IT', 'LV', 'LT', 'LU', 'MT', 'NL', 'PL', 'PT', 'RO', 'SK',
  'SI', 'ES', 'SE', //
  'IS', 'LI', 'NO', //
  'GB', 'CH', //
  'GF', 'GP', 'MQ', 'RE', 'YT', 'MF', 'AX',
};

final RegExp _twoLetters = RegExp(r'^[A-Z]{2}$');

/// A two-letter country code, upper-cased, or null when [raw] does not name
/// a country. Cloudflare reports `XX` for "unknown" and `T1` for Tor; both
/// mean we do not know.
String? normalizeCountryCode(String? raw) {
  final code = raw?.trim().toUpperCase();
  if (code == null || !_twoLetters.hasMatch(code)) return null;
  if (code == 'XX' || code == 'ZZ') return null;
  return code;
}

/// The region from the signals we have: the country the device is set to,
/// and the country the network connection comes from.
///
/// The device gives up to two answers. [deviceCountry] is the country in
/// the language the app runs in ("en-KH"). [deviceRegion] is the platform's
/// own region setting where it has one. On an iPhone these differ: set the
/// Region to France and the language stays "English (Cambodia)", so only
/// the region setting says France.
///
/// Any one signal pointing at a consent country is enough — a traveller in
/// Paris with a US phone is in France. The device alone never clears
/// anyone: a phone set to "United States" says nothing about where it is.
/// So without a connection country the answer is [unknown], unless the
/// device already says consent is required.
MeasurementRegion measurementRegionFor({
  String? deviceCountry,
  String? deviceRegion,
  String? connectionCountry,
}) {
  final connection = normalizeCountryCode(connectionCountry);
  final signals = [
    normalizeCountryCode(deviceCountry),
    normalizeCountryCode(deviceRegion),
    connection,
  ];
  if (signals.any((c) => c != null && consentRegionCountries.contains(c))) {
    return MeasurementRegion.consentRequired;
  }
  return connection == null
      ? MeasurementRegion.unknown
      : MeasurementRegion.open;
}
