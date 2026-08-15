// Static list of ISO 3166-1 alpha-2 country codes with display names —
// every UN member and observer state plus inhabited territories and
// special regions travelers actually visit (Kosovo, Greenland, Bermuda,
// French Polynesia, …). Names match the short-form English names used by
// Google Places, which is what end users will see on tile subtitles.
//
// SEARCH: display names keep their proper spelling (Türkiye, Côte
// d'Ivoire, São Tomé) — matching happens through [foldForSearch], which
// lowercases and strips diacritics on BOTH sides, plus per-country
// [Country.aliases] for exonyms and old names ("Turkey", "Ivory Coast",
// "Burma", "UK"). Never rely on raw `name.contains(query)`.

class Country {
  final String code; // ISO 3166-1 alpha-2 (uppercase)
  final String name;

  /// Search-only alternative names: exonyms, former names, abbreviations.
  /// Never displayed.
  final List<String> aliases;

  const Country(this.code, this.name, [this.aliases = const []]);

  /// True when this country matches [foldedQuery] — which MUST already be
  /// passed through [foldForSearch]. Matches the code as a prefix and the
  /// folded name/aliases as substrings.
  bool matchesQuery(String foldedQuery) {
    if (foldedQuery.isEmpty) return true;
    if (code.toLowerCase().startsWith(foldedQuery)) return true;
    if (foldForSearch(name).contains(foldedQuery)) return true;
    for (final alias in aliases) {
      if (foldForSearch(alias).contains(foldedQuery)) return true;
    }
    return false;
  }

  /// Renders the country flag as a regional-indicator emoji from [code].
  /// Some platforms (notably Windows) fall back to letters — that's fine.
  String get flagEmoji {
    if (code.length != 2) return '';
    final upper = code.toUpperCase();
    final first = upper.codeUnitAt(0);
    final second = upper.codeUnitAt(1);
    if (first < 0x41 || first > 0x5A || second < 0x41 || second > 0x5A) {
      return '';
    }
    const base = 0x1F1E6 - 0x41; // regional indicator A − ASCII A
    return String.fromCharCodes([first + base, second + base]);
  }
}

/// Lowercases and strips the Latin diacritics that appear in country names
/// (and that users type), so "turkey"/"turkiye" find "Türkiye" and "cote"
/// finds "Côte d'Ivoire". Curly apostrophes normalize to the ASCII one.
String foldForSearch(String s) {
  const map = {
    'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a', 'ā': 'a',
    'ç': 'c', 'ć': 'c', 'č': 'c',
    'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e', 'ē': 'e',
    'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i', 'ī': 'i',
    'ñ': 'n', 'ň': 'n',
    'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o', 'ø': 'o', 'ō': 'o',
    'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u', 'ū': 'u',
    'ý': 'y', 'ÿ': 'y',
    'ß': 'ss', 'æ': 'ae', 'œ': 'oe',
    '’': "'", '‘': "'",
  };
  final lower = s.toLowerCase().trim();
  final buffer = StringBuffer();
  for (final rune in lower.runes) {
    final ch = String.fromCharCode(rune);
    buffer.write(map[ch] ?? ch);
  }
  return buffer.toString();
}

/// Look up a country by its alpha-2 code (case insensitive). Returns `null`
/// if the code isn't recognized — callers should treat that as "no country".
Country? findCountryByCode(String? code) {
  if (code == null || code.isEmpty) return null;
  final upper = code.toUpperCase();
  for (final c in kCountries) {
    if (c.code == upper) return c;
  }
  return null;
}

/// Alphabetical (by English name) list of countries and territories.
const List<Country> kCountries = [
  Country('AF', 'Afghanistan'),
  Country('AX', 'Åland Islands'),
  Country('AL', 'Albania'),
  Country('DZ', 'Algeria'),
  Country('AS', 'American Samoa'),
  Country('AD', 'Andorra'),
  Country('AO', 'Angola'),
  Country('AI', 'Anguilla'),
  Country('AQ', 'Antarctica'),
  Country('AG', 'Antigua and Barbuda'),
  Country('AR', 'Argentina'),
  Country('AM', 'Armenia'),
  Country('AW', 'Aruba'),
  Country('AU', 'Australia'),
  Country('AT', 'Austria'),
  Country('AZ', 'Azerbaijan'),
  Country('BS', 'Bahamas'),
  Country('BH', 'Bahrain'),
  Country('BD', 'Bangladesh'),
  Country('BB', 'Barbados'),
  Country('BY', 'Belarus'),
  Country('BE', 'Belgium'),
  Country('BZ', 'Belize'),
  Country('BJ', 'Benin'),
  Country('BM', 'Bermuda'),
  Country('BT', 'Bhutan'),
  Country('BO', 'Bolivia'),
  Country('BA', 'Bosnia and Herzegovina'),
  Country('BW', 'Botswana'),
  Country('BR', 'Brazil'),
  Country('VG', 'British Virgin Islands'),
  Country('BN', 'Brunei'),
  Country('BG', 'Bulgaria'),
  Country('BF', 'Burkina Faso'),
  Country('BI', 'Burundi'),
  Country('KH', 'Cambodia'),
  Country('CM', 'Cameroon'),
  Country('CA', 'Canada'),
  Country('CV', 'Cape Verde', ['Cabo Verde']),
  Country('KY', 'Cayman Islands'),
  Country('CF', 'Central African Republic'),
  Country('TD', 'Chad'),
  Country('CL', 'Chile'),
  Country('CN', 'China'),
  Country('CX', 'Christmas Island'),
  Country('CC', 'Cocos (Keeling) Islands'),
  Country('CO', 'Colombia'),
  Country('KM', 'Comoros'),
  Country('CG', 'Congo', ['Republic of the Congo', 'Congo-Brazzaville']),
  Country('CD', 'Congo (DRC)',
      ['Democratic Republic of the Congo', 'DR Congo', 'Zaire']),
  Country('CK', 'Cook Islands'),
  Country('CR', 'Costa Rica'),
  Country('CI', "Côte d'Ivoire", ['Ivory Coast']),
  Country('HR', 'Croatia'),
  Country('CU', 'Cuba'),
  Country('CW', 'Curaçao'),
  Country('CY', 'Cyprus'),
  Country('CZ', 'Czechia', ['Czech Republic']),
  Country('DK', 'Denmark'),
  Country('DJ', 'Djibouti'),
  Country('DM', 'Dominica'),
  Country('DO', 'Dominican Republic'),
  Country('EC', 'Ecuador'),
  Country('EG', 'Egypt'),
  Country('SV', 'El Salvador'),
  Country('GQ', 'Equatorial Guinea'),
  Country('ER', 'Eritrea'),
  Country('EE', 'Estonia'),
  Country('SZ', 'Eswatini', ['Swaziland']),
  Country('ET', 'Ethiopia'),
  Country('FK', 'Falkland Islands'),
  Country('FO', 'Faroe Islands'),
  Country('FJ', 'Fiji'),
  Country('FI', 'Finland'),
  Country('FR', 'France'),
  Country('GF', 'French Guiana'),
  Country('PF', 'French Polynesia', ['Tahiti', 'Bora Bora']),
  Country('GA', 'Gabon'),
  Country('GM', 'Gambia'),
  Country('GE', 'Georgia'),
  Country('DE', 'Germany', ['Deutschland']),
  Country('GH', 'Ghana'),
  Country('GI', 'Gibraltar'),
  Country('GR', 'Greece'),
  Country('GL', 'Greenland'),
  Country('GD', 'Grenada'),
  Country('GP', 'Guadeloupe'),
  Country('GU', 'Guam'),
  Country('GT', 'Guatemala'),
  Country('GG', 'Guernsey'),
  Country('GN', 'Guinea'),
  Country('GW', 'Guinea-Bissau'),
  Country('GY', 'Guyana'),
  Country('HT', 'Haiti'),
  Country('HN', 'Honduras'),
  Country('HK', 'Hong Kong'),
  Country('HU', 'Hungary'),
  Country('IS', 'Iceland'),
  Country('IN', 'India'),
  Country('ID', 'Indonesia'),
  Country('IR', 'Iran'),
  Country('IQ', 'Iraq'),
  Country('IE', 'Ireland'),
  Country('IM', 'Isle of Man'),
  Country('IL', 'Israel'),
  Country('IT', 'Italy'),
  Country('JM', 'Jamaica'),
  Country('JP', 'Japan'),
  Country('JE', 'Jersey'),
  Country('JO', 'Jordan'),
  Country('KZ', 'Kazakhstan'),
  Country('KE', 'Kenya'),
  Country('KI', 'Kiribati'),
  Country('XK', 'Kosovo'),
  Country('KW', 'Kuwait'),
  Country('KG', 'Kyrgyzstan'),
  Country('LA', 'Laos'),
  Country('LV', 'Latvia'),
  Country('LB', 'Lebanon'),
  Country('LS', 'Lesotho'),
  Country('LR', 'Liberia'),
  Country('LY', 'Libya'),
  Country('LI', 'Liechtenstein'),
  Country('LT', 'Lithuania'),
  Country('LU', 'Luxembourg'),
  Country('MO', 'Macau'),
  Country('MG', 'Madagascar'),
  Country('MW', 'Malawi'),
  Country('MY', 'Malaysia'),
  Country('MV', 'Maldives'),
  Country('ML', 'Mali'),
  Country('MT', 'Malta'),
  Country('MH', 'Marshall Islands'),
  Country('MQ', 'Martinique'),
  Country('MR', 'Mauritania'),
  Country('MU', 'Mauritius'),
  Country('YT', 'Mayotte'),
  Country('MX', 'Mexico'),
  Country('FM', 'Micronesia'),
  Country('MD', 'Moldova'),
  Country('MC', 'Monaco'),
  Country('MN', 'Mongolia'),
  Country('ME', 'Montenegro'),
  Country('MS', 'Montserrat'),
  Country('MA', 'Morocco'),
  Country('MZ', 'Mozambique'),
  Country('MM', 'Myanmar', ['Burma']),
  Country('NA', 'Namibia'),
  Country('NR', 'Nauru'),
  Country('NP', 'Nepal'),
  Country('NL', 'Netherlands', ['Holland']),
  Country('NC', 'New Caledonia'),
  Country('NZ', 'New Zealand'),
  Country('NI', 'Nicaragua'),
  Country('NE', 'Niger'),
  Country('NG', 'Nigeria'),
  Country('NU', 'Niue'),
  Country('NF', 'Norfolk Island'),
  Country('KP', 'North Korea', ['DPRK']),
  Country('MK', 'North Macedonia', ['Macedonia']),
  Country('MP', 'Northern Mariana Islands', ['Saipan']),
  Country('NO', 'Norway'),
  Country('OM', 'Oman'),
  Country('PK', 'Pakistan'),
  Country('PW', 'Palau'),
  Country('PS', 'Palestine'),
  Country('PA', 'Panama'),
  Country('PG', 'Papua New Guinea'),
  Country('PY', 'Paraguay'),
  Country('PE', 'Peru'),
  Country('PH', 'Philippines'),
  Country('PL', 'Poland'),
  Country('PT', 'Portugal'),
  Country('PR', 'Puerto Rico'),
  Country('QA', 'Qatar'),
  Country('RE', 'Réunion'),
  Country('RO', 'Romania'),
  Country('RU', 'Russia'),
  Country('RW', 'Rwanda'),
  Country('BL', 'Saint Barthélemy', ['St Barts']),
  Country('SH', 'Saint Helena'),
  Country('KN', 'Saint Kitts and Nevis', ['St Kitts']),
  Country('LC', 'Saint Lucia', ['St Lucia']),
  Country('MF', 'Saint Martin', ['St Martin']),
  Country('PM', 'Saint Pierre and Miquelon'),
  Country('VC', 'Saint Vincent and the Grenadines', ['St Vincent']),
  Country('WS', 'Samoa'),
  Country('SM', 'San Marino'),
  Country('ST', 'São Tomé and Príncipe'),
  Country('SA', 'Saudi Arabia'),
  Country('SN', 'Senegal'),
  Country('RS', 'Serbia'),
  Country('SC', 'Seychelles'),
  Country('SL', 'Sierra Leone'),
  Country('SG', 'Singapore'),
  Country('SX', 'Sint Maarten'),
  Country('SK', 'Slovakia'),
  Country('SI', 'Slovenia'),
  Country('SB', 'Solomon Islands'),
  Country('SO', 'Somalia'),
  Country('ZA', 'South Africa'),
  Country('KR', 'South Korea', ['Korea', 'Republic of Korea']),
  Country('SS', 'South Sudan'),
  Country('ES', 'Spain'),
  Country('LK', 'Sri Lanka'),
  Country('SD', 'Sudan'),
  Country('SR', 'Suriname'),
  Country('SJ', 'Svalbard and Jan Mayen', ['Svalbard']),
  Country('SE', 'Sweden'),
  Country('CH', 'Switzerland'),
  Country('SY', 'Syria'),
  Country('TW', 'Taiwan'),
  Country('TJ', 'Tajikistan'),
  Country('TZ', 'Tanzania'),
  Country('TH', 'Thailand'),
  Country('TL', 'Timor-Leste', ['East Timor']),
  Country('TG', 'Togo'),
  Country('TK', 'Tokelau'),
  Country('TO', 'Tonga'),
  Country('TT', 'Trinidad and Tobago'),
  Country('TN', 'Tunisia'),
  Country('TR', 'Türkiye', ['Turkey']),
  Country('TM', 'Turkmenistan'),
  Country('TC', 'Turks and Caicos Islands'),
  Country('TV', 'Tuvalu'),
  Country('VI', 'U.S. Virgin Islands', ['US Virgin Islands']),
  Country('UG', 'Uganda'),
  Country('UA', 'Ukraine'),
  Country('AE', 'United Arab Emirates', ['UAE', 'Dubai', 'Abu Dhabi']),
  Country('GB', 'United Kingdom',
      ['UK', 'Great Britain', 'England', 'Scotland', 'Wales']),
  Country('US', 'United States', ['USA', 'America', 'United States of America']),
  Country('UY', 'Uruguay'),
  Country('UZ', 'Uzbekistan'),
  Country('VU', 'Vanuatu'),
  Country('VA', 'Vatican City', ['Holy See']),
  Country('VE', 'Venezuela'),
  Country('VN', 'Vietnam'),
  Country('WF', 'Wallis and Futuna'),
  Country('EH', 'Western Sahara'),
  Country('YE', 'Yemen'),
  Country('ZM', 'Zambia'),
  Country('ZW', 'Zimbabwe'),
];
