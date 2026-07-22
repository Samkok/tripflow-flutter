import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Lifetime "time saved" ledger — the compounding social-currency stat
/// ("VoyZa has saved you 3h 40m across 4 trips").
///
/// Credits are keyed per trip-day (`<tripId>|<yyyy-MM-dd>`, `local|...` for
/// anonymous) and the ledger keeps the MAX per key: re-optimizing the same
/// day never double-counts, and a better route upgrades that day's credit.
/// Device-scoped (SharedPreferences), mirroring ReviewPromptService's
/// per-install counters — the stat survives the anonymous→signup transition
/// on the same device, which is the honest scope for "your lifetime with
/// this app."
///
/// Every method swallows its own errors: a stats ledger must never break an
/// optimize flow.
class TimeSavedLedgerService {
  TimeSavedLedgerService._();
  static final instance = TimeSavedLedgerService._();

  static const _kEntries = 'time_saved_ledger_v1';

  Future<Map<String, int>> _entries(SharedPreferences prefs) async {
    try {
      final raw = prefs.getString(_kEntries);
      if (raw == null || raw.isEmpty) return {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return decoded.map((k, v) => MapEntry(k.toString(), (v as num).toInt()));
    } catch (_) {
      return {};
    }
  }

  /// Credit [saved] for [dayKey]. Keeps the max per key. Returns the new
  /// lifetime total (or the current one if nothing changed).
  Future<Duration> credit({
    required String dayKey,
    required Duration saved,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final entries = await _entries(prefs);
      final prior = entries[dayKey] ?? 0;
      if (saved.inSeconds > prior) {
        entries[dayKey] = saved.inSeconds;
        await prefs.setString(_kEntries, jsonEncode(entries));
      }
      return _sum(entries);
    } catch (e) {
      debugPrint('TimeSavedLedgerService.credit: $e');
      return Duration.zero;
    }
  }

  /// Lifetime total across every trip-day.
  Future<Duration> total() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return _sum(await _entries(prefs));
    } catch (e) {
      debugPrint('TimeSavedLedgerService.total: $e');
      return Duration.zero;
    }
  }

  /// Total credited to one trip's days (for the post-trip recap).
  Future<Duration> totalForTrip(String tripId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final entries = await _entries(prefs);
      var seconds = 0;
      entries.forEach((key, value) {
        if (key.startsWith('$tripId|')) seconds += value;
      });
      return Duration(seconds: seconds);
    } catch (e) {
      debugPrint('TimeSavedLedgerService.totalForTrip: $e');
      return Duration.zero;
    }
  }

  Duration _sum(Map<String, int> entries) =>
      Duration(seconds: entries.values.fold(0, (a, b) => a + b));
}
