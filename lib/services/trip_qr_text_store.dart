import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/trip_qr_text.dart';

/// A traveller's own headline for a trip's QR card.
typedef TripQrHeadline = ({String lead, String title});

/// Remembers, per trip and on this device, the headline a traveller wrote
/// for the trip's QR card, so the card opens the way they left it.
///
/// On the device only: the card is made where it is shared, and the words
/// on it are a matter of presentation, not part of the trip.
class TripQrTextStore {
  TripQrTextStore({Future<SharedPreferences> Function()? prefs})
      : _prefs = prefs ?? SharedPreferences.getInstance;

  final Future<SharedPreferences> Function() _prefs;

  static const String keyPrefix = 'trip_qr_headline_';

  static String _key(String tripId) => '$keyPrefix$tripId';

  /// The headline saved for [tripId], tidied the same way as when it was
  /// written. Null when none was saved or what is stored cannot be read.
  Future<TripQrHeadline?> load(String tripId) async {
    try {
      final raw = (await _prefs()).getString(_key(tripId));
      if (raw == null) return null;
      final json = jsonDecode(raw);
      if (json is! Map) return null;
      final title = cleanHeadlinePart(
        '${json['title'] ?? ''}',
        TripQrText.maxTitleLength,
      );
      if (title.isEmpty) return null;
      return (
        lead: cleanHeadlinePart(
          '${json['lead'] ?? ''}',
          TripQrText.maxLeadLength,
        ),
        title: title,
      );
    } catch (e) {
      debugPrint('TripQrTextStore.load: $e');
      return null;
    }
  }

  Future<void> save(String tripId, TripQrHeadline headline) async {
    try {
      await (await _prefs()).setString(
        _key(tripId),
        jsonEncode({'lead': headline.lead, 'title': headline.title}),
      );
    } catch (e) {
      debugPrint('TripQrTextStore.save: $e');
    }
  }

  /// Forgets the saved headline: the card goes back to the one made from
  /// the trip.
  Future<void> clear(String tripId) async {
    try {
      await (await _prefs()).remove(_key(tripId));
    } catch (e) {
      debugPrint('TripQrTextStore.clear: $e');
    }
  }
}
