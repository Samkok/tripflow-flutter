/// Forgiving text matching for the in-app "find a place I already saved"
/// searches (trip page filter, trip-plan sheet filter, trip list, nearby
/// picker).
///
/// Users type what they remember — usually plain ASCII — while the saved
/// name is whatever Google returned: "Chợ Bến Thành", "Phở Hòa Pasteur",
/// "Café de Flore". A raw `contains` demands the exact diacritics and the
/// exact word order, which makes Vietnamese (and Portuguese, French,
/// Turkish…) names practically unfindable from a phone keyboard.
///
/// [matchesSearchQuery] folds both sides to lowercase ASCII-ish letters
/// (diacritics stripped, đ → d, ß → ss …), splits the query into words and
/// requires every word to appear somewhere in the folded text. So
/// "ben thanh", "Bến Thành", "thanh ben" and "cho ben" all find
/// "Chợ Bến Thành".
library;

/// Lowercases [input] and strips Latin diacritics so accent-free typing
/// matches accented names. Non-Latin scripts (Thai, Khmer, CJK, …) pass
/// through untouched — they're compared as typed.
String normalizeSearchText(String input) {
  final lower = input.toLowerCase();
  final out = StringBuffer();
  for (final r in lower.runes) {
    // Vietnamese "Latin Extended Additional" block: U+1EA0–U+1EF9 is laid
    // out base-letter by base-letter, so ranges map straight to vowels.
    if (r >= 0x1EA0 && r <= 0x1EF9) {
      if (r <= 0x1EB7) {
        out.write('a');
      } else if (r <= 0x1EC7) {
        out.write('e');
      } else if (r <= 0x1ECB) {
        out.write('i');
      } else if (r <= 0x1EE3) {
        out.write('o');
      } else if (r <= 0x1EF1) {
        out.write('u');
      } else {
        out.write('y');
      }
      continue;
    }
    // Combining marks (already-decomposed input): drop them.
    if (r >= 0x0300 && r <= 0x036F) continue;
    final folded = _latinFold[r];
    if (folded != null) {
      out.write(folded);
      continue;
    }
    // Punctuation that commonly differs between what's typed and what's
    // stored ("Pho-Hoa" vs "Phở Hòa", "St." vs "St") → word break.
    if (r < 0x80 && !_isAsciiAlnum(r)) {
      out.write(' ');
      continue;
    }
    out.writeCharCode(r);
  }
  return out.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// True when every word of [query] occurs in [haystack], both compared after
/// [normalizeSearchText]. An empty / whitespace-only query matches everything.
bool matchesSearchQuery(String haystack, String query) {
  final q = normalizeSearchText(query);
  if (q.isEmpty) return true;
  return matchesNormalizedQuery(normalizeSearchText(haystack), q);
}

/// [matchesSearchQuery] for callers that normalise once and match many —
/// a list filter re-run per keystroke shouldn't fold every name again.
/// Both arguments must already be [normalizeSearchText] output.
bool matchesNormalizedQuery(String normalizedHaystack, String normalizedQuery) {
  if (normalizedQuery.isEmpty) return true;
  if (normalizedHaystack.contains(normalizedQuery)) return true;
  for (final word in normalizedQuery.split(' ')) {
    if (word.isEmpty) continue;
    if (!normalizedHaystack.contains(word)) return false;
  }
  return true;
}

bool _isAsciiAlnum(int r) =>
    (r >= 0x30 && r <= 0x39) || (r >= 0x61 && r <= 0x7A);

/// Lowercase Latin-1 Supplement + Latin Extended-A/B letters → ASCII base.
/// Built once from a compact "base ← variants" table.
final Map<int, String> _latinFold = _buildLatinFold();

Map<int, String> _buildLatinFold() {
  const groups = <String, String>{
    'a': 'àáâãäåāăąǎȁȃạả',
    'ae': 'æ',
    'c': 'çćĉċč',
    'd': 'ðďđ',
    'e': 'èéêëēĕėęěȅȇ',
    'g': 'ĝğġģ',
    'h': 'ĥħ',
    'i': 'ìíîïĩīĭįıǐ',
    'ij': 'ĳ',
    'j': 'ĵ',
    'k': 'ķĸ',
    'l': 'ĺļľŀł',
    'n': 'ñńņňŉŋ',
    'o': 'òóôõöøōŏőơǒȍȏ',
    'oe': 'œ',
    'r': 'ŕŗřȑȓ',
    's': 'śŝşšſș',
    'ss': 'ß',
    't': 'ţťŧț',
    'th': 'þ',
    'u': 'ùúûüũūŭůűųưǔ',
    'w': 'ŵ',
    'y': 'ýÿŷ',
    'z': 'źżž',
  };
  final map = <int, String>{};
  groups.forEach((base, variants) {
    for (final r in variants.runes) {
      map[r] = base;
    }
  });
  return map;
}
