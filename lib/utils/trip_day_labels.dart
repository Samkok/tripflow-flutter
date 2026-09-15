import 'package:intl/intl.dart';

import '../models/trip.dart';
import 'trip_dates.dart';

/// How a trip names its days: calendar dates, or "Day N" while the trip
/// has no dates yet (`Trip.datesTbd`, see [tripDatesTbdAnchor]). One
/// object per trip so headers, chips, toasts and pickers all agree.
class DayLabeler {
  /// True for a trip planned without dates: days are numbered.
  final bool tbd;

  /// Day 1 of a numbered trip (the anchor); null for dated trips.
  final DateTime? start;

  const DayLabeler({required this.tbd, this.start});

  /// Plain calendar labels.
  static const dated = DayLabeler(tbd: false);

  factory DayLabeler.forTrip(Trip? trip) {
    final start = trip?.startDate;
    if (trip != null && trip.isUndated && start != null) {
      return DayLabeler(tbd: true, start: dayKey(start));
    }
    return dated;
  }

  /// "Day 3", or [day] formatted with [pattern] (intl DateFormat).
  String call(DateTime day, {String pattern = 'MMM d'}) =>
      tbd ? tripDayLabel(start!, day) : DateFormat(pattern).format(day);

  /// "Day 2 – Day 4", or "Sep 14 – Sep 16" ([lastPattern] lets the second
  /// half carry the year, e.g. 'MMM d, y').
  String range(DateTime first, DateTime last,
          {String pattern = 'MMM d', String? lastPattern}) =>
      '${call(first, pattern: pattern)} – '
      '${call(last, pattern: lastPattern ?? pattern)}';

  /// "Today" only means something on a dated trip.
  bool isToday(DateTime day) =>
      !tbd && dayKey(day).isAtSameMomentAs(dayKey(DateTime.now()));

  /// 1-based number of [day] within a numbered trip; 0 for dated trips.
  int dayNumber(DateTime day) => start == null ? 0 : tripDayNumber(start!, day);

  @override
  bool operator ==(Object other) =>
      other is DayLabeler && other.tbd == tbd && other.start == start;

  @override
  int get hashCode => Object.hash(tbd, start);
}
