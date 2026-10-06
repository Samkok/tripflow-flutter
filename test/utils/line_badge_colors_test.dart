import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyza/utils/line_badge_colors.dart';

/// WCAG contrast ratio, written out here so the tests do not lean on the
/// code they check.
double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

void main() {
  // Hong Kong buses from the recording that showed the bug: N619 and N680
  // are red, N11 is yellow — and its white label could not be read.
  const red = Color(0xFFE60012);
  const yellow = Color(0xFFE9F10C);

  group('no text colour from the feed', () {
    test('a light badge gets black text', () {
      const light = [
        yellow,
        Color(0xFFFFD300), // London Circle line
        Color(0xFFBAC429), // lime
        Color(0xFFF7943E), // orange
        Color(0xFF53B7E8), // light blue
        Color(0xFFC0C0C0), // light grey
        Color(0xFFFFFFFF), // a feed with no line colour at all
        Color(0xFF00D4FF), // the app's own cyan, used when the line has none
      ];
      for (final badge in light) {
        expect(lineBadgeTextColor(badge), Colors.black, reason: '$badge');
      }
    });

    test('a dark badge keeps white text, exactly as before', () {
      const dark = [
        red,
        Color(0xFFE2231A), // red
        Color(0xFF003DA5), // navy
        Color(0xFF007DC5), // blue
        Color(0xFF00A651), // green
        Color(0xFF00888A), // teal
        Color(0xFF7D499D), // purple
        Color(0xFFEC008C), // magenta
        Color(0xFF923011), // brown
        Color(0xFF000000),
      ];
      for (final badge in dark) {
        expect(lineBadgeTextColor(badge), Colors.white, reason: '$badge');
      }
    });
  });

  group("the feed's own text colour", () {
    test('is used when it is readable and the same kind as the default', () {
      const navy = Color(0xFF113B92);
      expect(
          lineBadgeTextColor(const Color(0xFFFFD300), preferred: navy), navy);
      const paleYellow = Color(0xFFFFE600);
      expect(lineBadgeTextColor(const Color(0xFF003DA5), preferred: paleYellow),
          paleYellow);
    });

    test('black on a dark badge is ignored — a blank feed reads as black', () {
      expect(lineBadgeTextColor(red, preferred: Colors.black), Colors.white);
      expect(
          lineBadgeTextColor(const Color(0xFF003DA5), preferred: Colors.black),
          Colors.white);
    });

    test('white on a light badge is ignored', () {
      expect(lineBadgeTextColor(yellow, preferred: Colors.white), Colors.black);
    });

    test('is dropped when it is too close to the badge to read', () {
      // Olive on yellow-green: both "dark on light", but only 2:1 apart.
      expect(
          lineBadgeTextColor(const Color(0xFF9ACD32),
              preferred: const Color(0xFF6B8E23)),
          Colors.black);
      // Pale blue-grey on slate: both "light on dark", under 3:1 apart.
      expect(
          lineBadgeTextColor(const Color(0xFF5A6E8C),
              preferred: const Color(0xFF9FB0C8)),
          Colors.white);
    });
  });

  test('text stays readable on every badge, whatever the feed asks for', () {
    // 2.71 is the lowest the default can reach: white on the lightest
    // colour that still counts as dark. A feed colour must beat 3.
    final shades = [0, 51, 102, 153, 204, 255];
    final colours = [
      for (final r in shades)
        for (final g in shades)
          for (final b in shades) Color.fromARGB(255, r, g, b),
    ];
    for (final badge in colours) {
      expect(_contrast(lineBadgeTextColor(badge), badge),
          greaterThanOrEqualTo(2.7),
          reason: 'default text on $badge');
      for (final asked in colours) {
        final text = lineBadgeTextColor(badge, preferred: asked);
        expect(_contrast(text, badge), greaterThanOrEqualTo(2.7),
            reason: '$asked asked for on $badge');
      }
    }
  });
}
