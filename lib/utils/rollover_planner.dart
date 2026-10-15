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
///
/// A leftover ALWAYS moves. When the same place is already planned on
/// [today] — same place id, or the same name within a kilometre
/// ([isLikelySamePlace]) — the moved row replaces that copy: an OPEN copy
/// (not done, not skipped, not a stay, single-day) is deleted so today
/// still plans the place once. When today's copy is already decided
/// (done, skipped, or a stay spanning today) it stays the plan and the
/// leftover is deleted instead — a visit that happened, or a choice
/// already made, is never replaced by an open stop from an earlier day.
/// Two leftovers of one place from different past days: the older moves
/// first, the newer replaces it like any other open copy.
RolloverPlan planRollover({
  required String tripId,
  required Iterable<SavedLocation> rows,
  required DateTime today,
}) {
  final day = dayKey(today);
  final mine = rows.where((l) => l.tripId == tripId).toList();
  final occupants = <_Occupant>[
    for (final l in mine)
      if (l.scheduledDate != null && l.isActiveOnDate(day))
        _Occupant(
          id: l.id,
          key: placeKeyOfSaved(l),
          open:
              !l.isDone && !l.isSkipped && !l.isAccommodation && !l.isMultiDay,
        ),
  ];
  final move = <String>[];
  final delete = <String>[];
  for (final l in mine) {
    final start = l.scheduledDate;
    if (start == null || !dayKey(start).isBefore(day)) continue;
    if (l.isDone || l.isSkipped || l.isAccommodation || l.isMultiDay) continue;
    final key = placeKeyOfSaved(l);
    final matches =
        occupants.where((o) => isLikelySamePlace(o.key, key)).toList();
    if (matches.isNotEmpty) {
      if (matches.any((o) => !o.open)) {
        delete.add(l.id);
        continue;
      }
      for (final o in matches) {
        delete.add(o.id);
        move.remove(o.id); // an earlier leftover of this run: replaced too
        occupants.remove(o);
      }
    }
    occupants.add(_Occupant(id: l.id, key: key, open: true));
    move.add(l.id);
  }
  return RolloverPlan(move: move, delete: delete);
}

class _Occupant {
  const _Occupant({required this.id, required this.key, required this.open});
  final String id;
  final PlaceKey key;
  final bool open;
}

/// What one carry-forward run does to a trip's rows.
class RolloverPlan {
  const RolloverPlan({required this.move, required this.delete});

  /// Rows to put on today.
  final List<String> move;

  /// Rows that go: today's open copies replaced by a moved leftover, and
  /// leftovers whose place today has already been decided.
  final List<String> delete;

  bool get isEmpty => move.isEmpty && delete.isEmpty;
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
