import 'package:country_flags/country_flags.dart';
import 'package:flutter/material.dart';

/// Renders a country flag from an ISO 3166-1 alpha-2 [code] as a bundled SVG
/// image, sized to [height] (width is derived from the standard ~3:2 flag
/// aspect ratio unless [width] is given).
///
/// Use this instead of the regional-indicator emoji (`Country.flagEmoji`):
/// Android's system emoji font deliberately omits country-flag glyphs, so an
/// emoji flag renders as a "?" tofu box on Android (phones and tablets) while
/// rendering correctly on iOS. SVG flags look identical on every platform.
/// Unsupported codes fall back to the package's built-in not-found flag.
class CountryFlagIcon extends StatelessWidget {
  final String code;
  final double height;
  final double? width;
  final double borderRadius;

  const CountryFlagIcon(
    this.code, {
    super.key,
    this.height = 14,
    this.width,
    this.borderRadius = 3,
  });

  @override
  Widget build(BuildContext context) {
    return CountryFlag.fromCountryCode(
      code,
      theme: ImageTheme(
        height: height,
        width: width ?? height * 3 / 2,
        shape: RoundedRectangle(borderRadius),
      ),
    );
  }
}
