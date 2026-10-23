import '../models/location_model.dart';
import '../models/trip.dart';
import 'trip_dates.dart';

/// The places of a trip that were never ticked off: not done, not skipped
/// (a skip was a decision), and not the accommodation (a bed is not a
/// visit). Scheduled ones first, day by day, then the Unscheduled bucket;
/// by name within a day — the order a traveller reads them in.
List<LocationModel> unvisitedPlaces(Iterable<LocationModel> rows) {
  final out = rows
      .where((l) => !l.isDone && !l.isSkipped && !l.isAccommodation)
      .toList();
  out.sort((a, b) {
    final da = a.scheduledDate;
    final db = b.scheduledDate;
    if (da != null && db != null) {
      final c = dayKey(da).compareTo(dayKey(db));
      if (c != 0) return c;
    } else if (da != null) {
      return -1;
    } else if (db != null) {
      return 1;
    }
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return out;
}

/// Whether [trip] is due its "Not visited" review: its last day has passed
/// and [rows] still hold places that were never visited. A trip without
/// real dates never ends.
bool tripNeedsUnvisitedReview(
  Trip? trip,
  Iterable<LocationModel> rows, {
  DateTime? today,
}) {
  if (trip == null || trip.isUndated) return false;
  if (!tripHasEnded(trip.endDate ?? trip.startDate, today: today)) {
    return false;
  }
  return unvisitedPlaces(rows).isNotEmpty;
}
