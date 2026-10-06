import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The text colour for a transit line badge filled with [badge], the line's
/// official colour.
///
/// Badges used to print white text on every line, which vanished on light
/// ones (Hong Kong's yellow N11). Text is now white on a dark badge and
/// black on a light one — the same light/dark split Material uses for text
/// on a coloured surface, so dark lines look exactly as before.
///
/// [preferred] is the text colour the line's own feed asks for ("navy on
/// yellow"). It only refines the shade: it is used when it sits on the same
/// side as the default (dark text on a light badge, light text on a dark
/// one) and is still readable. It never flips the default, because GTFS
/// treats a blank text colour as black — honouring that would turn the text
/// on a red badge black for every feed that left the field empty.
Color lineBadgeTextColor(Color badge, {Color? preferred}) {
  final lightBadge =
      ThemeData.estimateBrightnessForColor(badge) == Brightness.light;
  final fallback = lightBadge ? Colors.black : Colors.white;
  if (preferred == null) return fallback;
  final darkText =
      ThemeData.estimateBrightnessForColor(preferred) == Brightness.dark;
  if (darkText != lightBadge) return fallback;
  return _contrast(preferred, badge) >= _minFeedContrast ? preferred : fallback;
}

/// WCAG's floor for bold text and interface parts. A feed's own text colour
/// below this is dropped in favour of plain black or white.
const double _minFeedContrast = 3.0;

/// WCAG contrast ratio between two colours: 1 (identical) to 21.
double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}
