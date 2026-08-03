import 'package:flutter/material.dart';

class AppTheme {
  // Common Colors
  static const Color primaryColor = Color(0xFF00D4FF);
  static const Color secondaryColor = Color(0xFF7C3AED);
  static const Color accentColor = Color(0xFFFF6B6B);

  // Dark Theme Specific Colors
  static const Color darkBackgroundColor = Color(0xFF17263c);
  static const Color darkSurfaceColor = Color(0xFF242f3e);
  static const Color darkCardColor = Color(0xFF242f3e);

  // Light Theme Specific Colors
  static const Color lightBackgroundColor = Color(0xFFF2F2F7);
  static const Color lightSurfaceColor = Colors.white;
  static const Color lightCardColor = Colors.white;

  // ── Glass sheets ───────────────────────────────────────────────────────
  // ONE source of truth for every see-through surface (trip plan, search for
  // location, collaborators, and the cards inside them) so their glass can't
  // drift apart.
  static const double sheetBlurSigma = 12;

  /// Sheet fill opacity.
  ///
  /// Light mode is the tricky one: a white card over a white pane over a pale
  /// map composites to ~73% white at the "readable" alphas, which buries the
  /// blur completely — the glass just looks like flat white. Keeping BOTH
  /// layers thin lets the blurred backdrop actually show, and the 12px blur
  /// still smooths it enough for dark text to sit on top.
  static double sheetFillAlpha(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? 0.25 : 0.32;

  /// Fill for cards sitting INSIDE a glass sheet — translucent enough that
  /// the blurred backdrop reads through, opaque enough to group content.
  static double sheetCardAlpha(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? 0.30 : 0.28;

  /// Hairline edge of a glass pane. White reads as a lit edge on dark; on
  /// light it just disappears, so use a soft dark line instead.
  static Color sheetBorderColor(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? Colors.white.withValues(alpha: 0.08)
          : Colors.black.withValues(alpha: 0.08);

  /// Scrim behind a glass sheet. Light mode needs a touch more so the pane
  /// separates from the page instead of blending into it.
  static Color sheetBarrierColor(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? Colors.black.withValues(alpha: 0.15)
          : Colors.black.withValues(alpha: 0.25);
  static ThemeData darkTheme = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    primaryColor: primaryColor,
    scaffoldBackgroundColor: darkBackgroundColor,
    // Headers are COMPLETELY transparent app-wide: no fill, no shadow, and
    // no Material-3 scrolled-under surface tint (that tint is what made
    // "transparent" app bars regain a background once content scrolled).
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
    ),
    colorScheme: const ColorScheme.dark(
      primary: primaryColor,
      secondary: secondaryColor,
      surface: darkSurfaceColor,
      onPrimary: Colors.black,
      onSecondary: Colors.white,
      onSurface: Colors.white,
    ),
    cardTheme: CardThemeData(
      color: darkCardColor,
      elevation: 8,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: primaryColor,
        foregroundColor: Colors.black,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: darkSurfaceColor,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    ),
    textTheme: const TextTheme(
      headlineLarge: TextStyle(
        fontSize: 28,
        fontWeight: FontWeight.bold,
        color: Colors.white,
      ),
      headlineMedium: TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.w600,
        color: Colors.white,
      ),
      titleLarge: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: Colors.white,
      ),
      bodyLarge: TextStyle(
        fontSize: 16,
        color: Colors.white,
      ),
      bodyMedium: TextStyle(
        fontSize: 14,
        color: Colors.white70,
      ),
    ),
  );

  static ThemeData lightTheme = ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    primaryColor: primaryColor,
    scaffoldBackgroundColor: lightBackgroundColor,
    // Headers are COMPLETELY transparent app-wide: no fill, no shadow, and
    // no Material-3 scrolled-under surface tint (that tint is what made
    // "transparent" app bars regain a background once content scrolled).
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
    ),
    colorScheme: const ColorScheme.light(
      primary: primaryColor,
      secondary: secondaryColor,
      surface: lightSurfaceColor,
      onPrimary: Colors.black,
      onSecondary: Colors.black,
      onSurface: Colors.black,
    ),
    cardTheme: CardThemeData(
      color: lightCardColor,
      elevation: 8,
      shadowColor: Colors.grey.withValues(alpha: 0.2),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: primaryColor,
        foregroundColor: Colors.black,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: lightSurfaceColor,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    ),
    textTheme: const TextTheme(
      headlineLarge: TextStyle(
        fontSize: 28,
        fontWeight: FontWeight.bold,
        color: Colors.black,
      ),
      headlineMedium: TextStyle(
        fontSize: 24,
        fontWeight: FontWeight.w600,
        color: Colors.black,
      ),
      titleLarge: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        color: Colors.black,
      ),
      bodyLarge: TextStyle(fontSize: 16, color: Colors.black87),
      bodyMedium: TextStyle(fontSize: 14, color: Colors.black54),
    ),
  );
}
