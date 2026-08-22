import 'package:shared_preferences/shared_preferences.dart';

/// Persistence for the user's multi-modal routing choices:
///  • a per-trip travel profile ('auto' | 'walk' | 'drive') that picks the
///    anchor mode the optimizer routes the whole chain in, and
///  • per-leg mode overrides ("from Rialto to Grand Canal: always transit"),
///    keyed by the two stop ids so they survive re-optimizes and reorders.
///
/// Deliberately SharedPreferences, not Supabase: routes are derivable data —
/// only the user's *choices* persist, and they're device-local like the rest
/// of the planning preferences.
class LegModePrefs {
  static String _profileKey(String tripId) => 'trip_travel_profile_$tripId';
  static String _legKey(String tripId, String fromId, String toId) =>
      'legmode_${tripId}_$fromId>$toId';
  static String legOverrideKey(String fromId, String toId) => '$fromId>$toId';

  static Future<String> travelProfile(String tripId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_profileKey(tripId)) ?? 'auto';
  }

  static Future<void> setTravelProfile(String tripId, String profile) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_profileKey(tripId), profile);
  }

  /// All leg overrides for a trip as {'fromId>toId': mode}.
  static Future<Map<String, String>> overridesForTrip(String tripId) async {
    final prefs = await SharedPreferences.getInstance();
    final prefix = 'legmode_${tripId}_';
    final result = <String, String>{};
    for (final key in prefs.getKeys()) {
      if (!key.startsWith(prefix)) continue;
      final mode = prefs.getString(key);
      if (mode != null) result[key.substring(prefix.length)] = mode;
    }
    return result;
  }

  static Future<void> setLegMode(
      String tripId, String fromId, String toId, String mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_legKey(tripId, fromId, toId), mode);
  }

  static Future<void> clearLegMode(
      String tripId, String fromId, String toId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_legKey(tripId, fromId, toId));
  }

  // ── Travel preferences (GLOBAL — walking tolerance is a trait of the
  // traveller, not of one trip) ─────────────────────────────────────────

  static const int defaultMaxWalkMeters = 1000;
  static const int minMaxWalkMeters = 200;
  static const int maxMaxWalkMeters = 3000;

  /// The longest walk (routed meters) the user accepts between stops when
  /// their travel style ISN'T explicit walking. Feeds the router's ladder.
  static Future<int> maxWalkMeters() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getInt('pref_max_walk_meters') ?? defaultMaxWalkMeters;
    return v.clamp(minMaxWalkMeters, maxMaxWalkMeters);
  }

  static Future<void> setMaxWalkMeters(int meters) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('pref_max_walk_meters',
        meters.clamp(minMaxWalkMeters, maxMaxWalkMeters));
  }

  /// The Auto-plan choices for "places per day". null = Auto (capacity
  /// only); the rest are hard caps.
  static const List<int?> autoPlanMaxStopsChoices = [
    null, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15
  ];

  /// Auto-plan's per-day cap (see [autoPlanMaxStopsChoices]); a trait of
  /// the traveller, so global like max walk. null = Auto.
  static Future<int?> autoPlanMaxStops() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getInt('pref_auto_plan_max_stops');
    return v == null || v <= 0 ? null : v;
  }

  /// Whether a day's route should END at (return to) the day's
  /// accommodation. Per trip, default ON — you sleep where you end. OFF
  /// leaves the day open-ended: the accommodation becomes an ordinary stop
  /// (if it's in the list) or no return leg is added (if it's the start).
  static Future<bool> returnToAccommodation(String tripId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('pref_return_to_accommodation_$tripId') ?? true;
  }

  static Future<void> setReturnToAccommodation(String tripId, bool on) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('pref_return_to_accommodation_$tripId', on);
  }

  /// Auto-plan fill style: 'balanced' (even days) or 'pack' (fill each day
  /// to the limit, leave the rest free). Global like the cap.
  static Future<String> autoPlanFillStyle() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('pref_auto_plan_fill_style') ?? 'balanced';
  }

  static Future<void> setAutoPlanFillStyle(String style) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('pref_auto_plan_fill_style', style);
  }

  static Future<void> setAutoPlanMaxStops(int? cap) async {
    final prefs = await SharedPreferences.getInstance();
    if (cap == null || cap <= 0) {
      await prefs.remove('pref_auto_plan_max_stops');
    } else {
      await prefs.setInt('pref_auto_plan_max_stops', cap);
    }
  }

  /// Wipes every per-leg override for a trip. Called when the user changes
  /// the trip's TRAVEL STYLE: a style switch means "re-plan this trip that
  /// way", and stale manual leg choices silently overriding the new style
  /// everywhere read as the style picker being broken.
  static Future<void> clearAllLegModes(String tripId) async {
    final prefs = await SharedPreferences.getInstance();
    final prefix = 'legmode_${tripId}_';
    for (final key in prefs.getKeys().toList()) {
      if (key.startsWith(prefix)) await prefs.remove(key);
    }
  }
}
