import 'package:intl/intl.dart';

import '../models/saved_location.dart';
import 'same_day_place_guard.dart';
import 'trip_dates.dart';

/// Decides which rows of one trip the "carry unvisited places forward"
/// setting moves to [today]. Pure: no I/O, so it's unit-testable and the
/// service around it only does the write.
///
/// A row moves when it belongs to [tripId], sits on a day BEFORE [today],
/// and is still an ordinary active stop — not done, not skipped, not an
/// accommodation (it defines its own nights) and not a multi-day stay.
/// A row whose place is already planned on [today] — same place id, or the
/// same name within a kilometre ([isLikelySamePlace]) — is left where it
/// is rather than creating a same-day duplicate; two such leftovers from
/// different past days move only once.
List<String> planRollover({
  required String tripId,
  required Iterable<SavedLocation> rows,
  required DateTime today,
}) {
  final day = dayKey(today);
  final mine = rows.where((l) => l.tripId == tripId).toList();
  final occupants = <PlaceKey>[
    for (final l in mine)
      if (l.scheduledDate != null && l.isActiveOnDate(day)) placeKeyOfSaved(l),
  ];
  final out = <String>[];
  for (final l in mine) {
    final start = l.scheduledDate;
    if (start == null || !dayKey(start).isBefore(day)) continue;
    if (l.isDone || l.isSkipped || l.isAccommodation || l.isMultiDay) continue;
    final key = placeKeyOfSaved(l);
    if (occupants.any((o) => isLikelySamePlace(o, key))) continue;
    occupants.add(key);
    out.add(l.id);
  }
  return out;
}

/// Wording for the ONE notice a carry-forward run produces — "3 places
/// from yesterday moved to today". [fromDays] are the days the moved rows
/// came from: "yesterday" when they all came from the day before [today],
/// that day's short date ("Sep 9") when they all share one other day, and
/// "earlier days" when they came from several days (or are unknown).
/// Mirrored server-side by notify_trip_rollover(), which builds the same
/// sentence for the members' push.
String rolloverFromLabel(Iterable<DateTime> fromDays, DateTime today) {
  final distinct = fromDays.map(dayKey).toSet().toList()..sort();
  if (distinct.length != 1) return 'earlier days';
  final day = distinct.single;
  final t = dayKey(today);
  final yesterday = DateTime(t.year, t.month, t.day - 1);
  if (day == yesterday) return 'yesterday';
  return DateFormat('MMM d').format(day);
}

/// The sentence shared by the owner's toast and the members' push.
String rolloverMessage({
  required int moved,
  required String fromLabel,
  required String tripName,
}) =>
    '$moved place${moved == 1 ? '' : 's'} from $fromLabel moved to today '
    'in "$tripName"';
