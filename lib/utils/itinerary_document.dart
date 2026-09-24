import 'package:intl/intl.dart';

import '../models/saved_location.dart';
import '../models/trip.dart';
import 'countries.dart';
import 'place_tags.dart';
import 'trip_dates.dart';
import 'trip_day_labels.dart';

/// The whole trip laid out for export: what the itinerary document says,
/// independent of how it is drawn. Pure — built from the trip and its
/// places, so the grouping, ordering and wording are unit-tested without a
/// PDF in sight. Drawn by ItineraryPdfService.
class ItineraryDocument {
  final String tripName;
  final String? countryName;

  /// "Oct 5 – Oct 15, 2026", or "No dates yet" for a trip planned by day
  /// number.
  final String dateLine;
  final int dayCount;
  final int placeCount;
  final int stayCount;
  final List<ItineraryDay> days;

  /// Places that belong to the trip but sit on no day.
  final List<ItineraryStop> unscheduled;

  /// Tags that appear anywhere in the trip, in the fixed tag order — the
  /// colour key printed under the header.
  final List<PlaceTag> usedTags;
  final DateTime generatedAt;

  const ItineraryDocument({
    required this.tripName,
    required this.countryName,
    required this.dateLine,
    required this.dayCount,
    required this.placeCount,
    required this.stayCount,
    required this.days,
    required this.unscheduled,
    required this.usedTags,
    required this.generatedAt,
  });
}

class ItineraryDay {
  /// 1-based.
  final int number;

  /// "Day 3".
  final String title;

  /// "Tue, Oct 7, 2026" — null on a trip without dates.
  final String? subtitle;

  /// Where the traveller sleeps: the accommodation(s) covering this day.
  final List<ItineraryStop> stays;

  /// Everything else planned for the day, in visiting order as far as the
  /// app knows it: still-to-do first, then done, then skipped.
  final List<ItineraryStop> stops;

  const ItineraryDay({
    required this.number,
    required this.title,
    required this.subtitle,
    required this.stays,
    required this.stops,
  });
}

class ItineraryStop {
  final String name;
  final PlaceTag? tag;

  /// What the tag row says: the tag's name, or on Transport the place's
  /// mode ("Airport", "Train", …) when its Google types tell. Null when
  /// untagged. The colour key still lists the tag itself.
  final String? tagLabel;

  /// Planned time at the place; 0 = not set.
  final int stayMinutes;

  /// Opening hours for the day the stop is planned on ("09:00 – 18:00",
  /// "Open 24 hours", "May be closed this day"); null when unknown.
  final String? hoursLine;

  /// True when [hoursLine] is a warning rather than hours.
  final bool hoursCaution;
  final bool isDone;
  final bool isSkipped;

  /// "Oct 6 – Oct 8" / "Day 2 – Day 4" for a stop that spans days.
  final String? spanLabel;

  /// Opens the exact place in Google Maps.
  final String mapsUrl;

  const ItineraryStop({
    required this.name,
    required this.tag,
    required this.tagLabel,
    required this.stayMinutes,
    required this.hoursLine,
    required this.hoursCaution,
    required this.isDone,
    required this.isSkipped,
    required this.spanLabel,
    required this.mapsUrl,
  });
}

/// "1h 30m", "45m", "2h".
String formatStayMinutes(int minutes) {
  if (minutes <= 0) return '';
  final h = minutes ~/ 60;
  final m = minutes % 60;
  if (h == 0) return '${m}m';
  if (m == 0) return '${h}h';
  return '${h}h ${m}m';
}

String _clock(int minutes) {
  final h = (minutes ~/ 60) % 24;
  final m = minutes % 60;
  return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
}

String _periodsText(Iterable<OpeningPeriod> periods) => periods.map((p) {
      final close = p.closeMinutes;
      return close == null
          ? 'Opens ${_clock(p.openMinutes)}'
          : '${_clock(p.openMinutes)} – ${_clock(close)}';
    }).join(', ');

/// Hours for [day] (Google's weekday numbering: Sunday = 0). With no [day]
/// — a trip without dates — hours are shown only when every weekday shares
/// them. Returns the text and whether it is a caution.
({String text, bool caution})? openingHoursLine(
  List<OpeningPeriod>? hours, {
  required DateTime? day,
}) {
  if (hours == null || hours.isEmpty) return null;
  if (hours.length == 1 && hours.first.isAlwaysOpen) {
    return (text: 'Open 24 hours', caution: false);
  }
  if (day != null) {
    final googleDay = day.weekday % 7;
    final periods = hours.where((p) => p.openDay == googleDay);
    if (periods.isEmpty) {
      return (text: 'May be closed this day', caution: true);
    }
    return (text: _periodsText(periods), caution: false);
  }
  String? common;
  for (var d = 0; d < 7; d++) {
    final text = _periodsText(hours.where((p) => p.openDay == d));
    if (text.isEmpty) return null;
    if (common == null) {
      common = text;
    } else if (common != text) {
      return null;
    }
  }
  return common == null ? null : (text: common, caution: false);
}

/// Google Maps link that lands on the exact place when its place id is
/// known, on the coordinates otherwise.
String googleMapsUrlFor(SavedLocation l) {
  final placeId = l.placeId;
  return Uri.https('www.google.com', '/maps/search/', {
    'api': '1',
    'query': '${l.lat},${l.lng}',
    if (placeId != null && placeId.isNotEmpty) 'query_place_id': placeId,
  }).toString();
}

int _statusRank(SavedLocation l) => l.isSkipped ? 2 : (l.isDone ? 1 : 0);

int _byStatusThenAdded(SavedLocation a, SavedLocation b) {
  final s = _statusRank(a).compareTo(_statusRank(b));
  if (s != 0) return s;
  final c = a.createdAt.compareTo(b.createdAt);
  return c != 0 ? c : a.name.compareTo(b.name);
}

/// Lays [trip] and its [locations] out day by day. Every day the trip
/// spans gets a section — empty ones included, they are part of the plan.
ItineraryDocument buildItineraryDocument({
  required Trip trip,
  required List<SavedLocation> locations,
  DateTime? now,
}) {
  final labeler = DayLabeler.forTrip(trip);
  final axis = contiguousTripDates([
    trip.startDate,
    trip.endDate,
    for (final l in locations) ...[l.scheduledDate, l.scheduledEndDate],
  ]);

  ItineraryStop stopOf(SavedLocation l, DateTime? day) {
    final hours = openingHoursLine(
      l.googleOpeningHours,
      day: labeler.tbd ? null : day,
    );
    final start = l.scheduledDate;
    final end = l.scheduledEndDate;
    final spans = start != null &&
        end != null &&
        daySpanDays(dayKey(start), dayKey(end)) > 0;
    final tag = placeTagFromKey(l.tag);
    return ItineraryStop(
      name: l.name,
      tag: tag,
      tagLabel: tag == null ? null : placeTagLabel(tag, l.placeTypes),
      stayMinutes: l.stayDuration ~/ 60,
      hoursLine: hours?.text,
      hoursCaution: hours?.caution ?? false,
      isDone: l.isDone,
      isSkipped: l.isSkipped,
      spanLabel: spans ? labeler.range(start, end) : null,
      mapsUrl: googleMapsUrlFor(l),
    );
  }

  final days = <ItineraryDay>[];
  for (var i = 0; i < axis.length; i++) {
    final day = axis[i];
    final onDay = locations
        .where((l) => l.scheduledDate != null && l.isActiveOnDate(day))
        .toList()
      ..sort(_byStatusThenAdded);
    days.add(ItineraryDay(
      number: i + 1,
      title: 'Day ${i + 1}',
      subtitle: labeler.tbd ? null : DateFormat('EEE, MMM d, y').format(day),
      stays: [
        for (final l in onDay)
          if (l.isAccommodation) stopOf(l, day),
      ],
      stops: [
        for (final l in onDay)
          if (!l.isAccommodation) stopOf(l, day),
      ],
    ));
  }

  final unscheduled = (locations.where((l) => l.scheduledDate == null).toList()
        ..sort(_byStatusThenAdded))
      .map((l) => stopOf(l, null))
      .toList();

  final String dateLine;
  if (labeler.tbd || axis.isEmpty) {
    dateLine = 'No dates yet';
  } else if (axis.length == 1) {
    dateLine = DateFormat('MMM d, y').format(axis.first);
  } else {
    dateLine = '${DateFormat('MMM d').format(axis.first)} – '
        '${DateFormat('MMM d, y').format(axis.last)}';
  }

  final present = {
    for (final l in locations)
      if (placeTagFromKey(l.tag) case final t?) t,
  };

  return ItineraryDocument(
    tripName: trip.name,
    countryName: findCountryByCode(trip.countryCode)?.name,
    dateLine: dateLine,
    dayCount: axis.length,
    placeCount: locations.length,
    stayCount: locations.where((l) => l.isAccommodation).length,
    days: days,
    unscheduled: unscheduled,
    usedTags: PlaceTag.values.where(present.contains).toList(),
    generatedAt: now ?? DateTime.now(),
  );
}
