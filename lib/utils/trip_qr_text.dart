import 'package:flutter/widgets.dart' show StringCharacters;

/// The words on the trip QR card.
///
/// The card reads as a destination: a small line ("Places to visit in")
/// over a big one (the country), with the trip's own name underneath. A
/// trip without a country leads with its name instead. The two headline
/// lines are the traveller's to rewrite — see [withHeadline].
class TripQrText {
  /// The small line above the title. Empty = the card shows no small line.
  final String lead;

  /// The big line: the country, the trip's name, or the traveller's own
  /// words.
  final String title;

  /// What the trip is called, whatever the headline says.
  final String sourceTripName;

  /// "12 places · 5 days". Null when neither number is known.
  final String? stats;

  /// Whether the headline is the traveller's own words rather than the one
  /// made from the trip.
  final bool isCustom;

  const TripQrText({
    required this.lead,
    required this.title,
    this.sourceTripName = '',
    this.stats,
    this.isCustom = false,
  });

  /// Longest small line and big line a traveller can write. The big line
  /// is set in large type on two lines; past this it would be cut off.
  static const int maxLeadLength = 40;
  static const int maxTitleLength = 40;

  /// The card's words for a trip called [tripName] in [countryName], with
  /// [placeCount] places over [dayCount] days (either may be unknown).
  factory TripQrText.forTrip({
    required String tripName,
    String? countryName,
    int? placeCount,
    int? dayCount,
  }) {
    final name = tripName.trim();
    final country = countryName?.trim() ?? '';
    final hasCountry = country.isNotEmpty;
    return TripQrText(
      lead: hasCountry ? 'Places to visit in' : 'Places to visit',
      title: hasCountry ? country : (name.isEmpty ? 'My trip' : name),
      sourceTripName: name,
      stats: _stats(placeCount, dayCount),
    );
  }

  /// The trip's name as printed under the headline. Null when the headline
  /// already says it (a trip simply called "Japan" under the big line
  /// "Japan"), or when the trip has no name.
  String? get tripName {
    if (sourceTripName.isEmpty) return null;
    return sourceTripName.toLowerCase() == title.toLowerCase()
        ? null
        : sourceTripName;
  }

  /// This card with the traveller's own headline: [lead] as the small line
  /// (may be empty) and [title] as the big one. Both are tidied — see
  /// [cleanHeadlinePart]. A blank [title] is not a headline: the card is
  /// returned unchanged.
  TripQrText withHeadline({required String lead, required String title}) {
    final bigLine = cleanHeadlinePart(title, maxTitleLength);
    if (bigLine.isEmpty) return this;
    return TripQrText(
      lead: cleanHeadlinePart(lead, maxLeadLength),
      title: bigLine,
      sourceTripName: sourceTripName,
      stats: stats,
      isCustom: true,
    );
  }

  /// The whole headline as one sentence — what a screen reader says and
  /// what travels as the caption of the shared image.
  String get sentence => lead.isEmpty ? title : '$lead $title';

  static String? _stats(int? places, int? days) {
    final parts = <String>[
      if (places != null && places > 0)
        '$places ${places == 1 ? 'place' : 'places'}',
      if (days != null && days > 0) '$days ${days == 1 ? 'day' : 'days'}',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }
}

final RegExp _whitespaceRun = RegExp(r'\s+');

/// One headline line as it goes on the card: line breaks and runs of spaces
/// become single spaces, the ends are trimmed, and it is cut to [maxLength]
/// whole characters (an emoji or an accented letter is never split).
String cleanHeadlinePart(String raw, int maxLength) {
  final tidy = raw.replaceAll(_whitespaceRun, ' ').trim();
  final characters = tidy.characters;
  if (characters.length <= maxLength) return tidy;
  return characters.take(maxLength).toString().trimRight();
}
