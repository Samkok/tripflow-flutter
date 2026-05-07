import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/trip.dart';
import 'countries.dart';

enum TripDateCheckResult {
  ok,
  beforeStart,
  afterEnd,
}

DateTime _atMidnight(DateTime d) => DateTime(d.year, d.month, d.day);

/// Compares a candidate scheduled date against a trip's planned range.
/// Returns [TripDateCheckResult.ok] when the trip has no range, the date is
/// missing, or the date falls within the range.
TripDateCheckResult checkScheduledDate(Trip? trip, DateTime? scheduled) {
  if (trip == null || scheduled == null) return TripDateCheckResult.ok;
  final start = trip.startDate;
  final end = trip.endDate;
  if (start == null && end == null) return TripDateCheckResult.ok;

  final s = _atMidnight(scheduled);
  if (start != null && s.isBefore(_atMidnight(start))) {
    return TripDateCheckResult.beforeStart;
  }
  if (end != null && s.isAfter(_atMidnight(end))) {
    return TripDateCheckResult.afterEnd;
  }
  return TripDateCheckResult.ok;
}

/// Outcome of [confirmScheduledDate]. When [allowExtension] was true on the
/// call and the user confirmed, [extendedStart]/[extendedEnd] hold the new
/// trip dates the caller should persist; otherwise both are null.
class TripDateConfirmResult {
  final bool proceed;
  final DateTime? extendedStart;
  final DateTime? extendedEnd;

  const TripDateConfirmResult({
    required this.proceed,
    this.extendedStart,
    this.extendedEnd,
  });

  bool get didExtend => extendedStart != null || extendedEnd != null;

  static const cancelled = TripDateConfirmResult(proceed: false);
  static const allowed = TripDateConfirmResult(proceed: true);
}

/// Confirms an out-of-range scheduled date with the user. When
/// [allowExtension] is true, the modal also tells the user that proceeding
/// will extend the trip dates to fit, and the returned result carries the
/// new dates so the caller can persist the extension.
Future<TripDateConfirmResult> confirmScheduledDate(
  BuildContext context,
  Trip? trip,
  DateTime? scheduled, {
  String actionLabel = 'Add anyway',
  bool allowExtension = false,
}) async {
  final result = checkScheduledDate(trip, scheduled);
  if (result == TripDateCheckResult.ok) return TripDateConfirmResult.allowed;

  final fmt = DateFormat('MMM d, y');
  final scheduledStr = fmt.format(scheduled!);
  final tripName = trip!.name;
  final scheduledDay = _atMidnight(scheduled);

  String body;
  DateTime? extStart;
  DateTime? extEnd;

  if (result == TripDateCheckResult.beforeStart) {
    final startStr = fmt.format(trip.startDate!);
    body = '$scheduledStr is before "$tripName" starts on $startStr.';
    if (allowExtension) {
      extStart = scheduledDay;
      extEnd = trip.endDate;
    }
  } else {
    final endStr = fmt.format(trip.endDate!);
    body = '$scheduledStr is after "$tripName" ends on $endStr.';
    if (allowExtension) {
      extStart = trip.startDate;
      extEnd = scheduledDay;
    }
  }

  if (allowExtension) {
    final newStart = extStart ?? trip.startDate ?? scheduledDay;
    final newEnd = extEnd ?? trip.endDate ?? scheduledDay;
    body +=
        '\n\nIf you continue, the trip dates will update to ${fmt.format(newStart)} - ${fmt.format(newEnd)}.';
  }

  final proceed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Row(
        children: [
          Icon(Icons.event_busy_rounded, color: Colors.orange),
          SizedBox(width: 12),
          Expanded(child: Text('Outside trip dates')),
        ],
      ),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(actionLabel),
        ),
      ],
    ),
  );

  if (proceed != true) return TripDateConfirmResult.cancelled;

  if (!allowExtension) return TripDateConfirmResult.allowed;

  return TripDateConfirmResult(
    proceed: true,
    extendedStart: result == TripDateCheckResult.beforeStart ? scheduledDay : null,
    extendedEnd: result == TripDateCheckResult.afterEnd ? scheduledDay : null,
  );
}

/// Convenience wrapper for callers that don't want to extend the trip — they
/// only need a yes/no answer.
Future<bool> ensureScheduledDateAllowed(
  BuildContext context,
  Trip? trip,
  DateTime? scheduled, {
  String actionLabel = 'Add anyway',
}) async {
  final r = await confirmScheduledDate(
    context,
    trip,
    scheduled,
    actionLabel: actionLabel,
    allowExtension: false,
  );
  return r.proceed;
}

/// Confirms with the user before applying a trip date range that excludes
/// some of the trip's existing locations. Returns true when there is nothing
/// to flag or the user chose to proceed.
Future<bool> ensureLocationsFitNewTripRange(
  BuildContext context, {
  required String tripName,
  required DateTime? newStart,
  required DateTime? newEnd,
  required Iterable<DateTime> existingScheduledDates,
}) async {
  if (newStart == null && newEnd == null) return true;
  final s = newStart != null ? _atMidnight(newStart) : null;
  final e = newEnd != null ? _atMidnight(newEnd) : null;

  final outside = existingScheduledDates.where((d) {
    final day = _atMidnight(d);
    if (s != null && day.isBefore(s)) return true;
    if (e != null && day.isAfter(e)) return true;
    return false;
  }).toList();

  if (outside.isEmpty) return true;

  final fmt = DateFormat('MMM d, y');
  final rangeStr = (s != null && e != null)
      ? '${fmt.format(s)} - ${fmt.format(e)}'
      : (s != null ? 'starting ${fmt.format(s)}' : 'ending ${fmt.format(e!)}');

  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: Colors.orange),
          SizedBox(width: 12),
          Expanded(child: Text('Locations outside new dates')),
        ],
      ),
      content: Text(
        '${outside.length} location${outside.length == 1 ? '' : 's'} '
        'in "$tripName" ${outside.length == 1 ? 'is' : 'are'} scheduled '
        'outside the new range ($rangeStr). They will stay on their current '
        'dates. Update anyway?',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Update anyway'),
        ),
      ],
    ),
  );
  return result == true;
}

/// Confirms with the user when an added location is in a different country
/// than the trip's tagged country. Returns true when no check is needed
/// (trip has no country, location has no detected country, or they match)
/// or the user chose to proceed.
/// Strict country guard for the active trip. Returns true when the
/// location may be added (no trip context, the trip has no tagged country,
/// the location's country is unknown, or the two match), false when the
/// add must be blocked because of a known cross-country mismatch.
///
/// On a known mismatch this surfaces a single-button informational dialog —
/// there is no "Add anyway" path, since the requirement is to forbid
/// cross-country adds outright.
Future<bool> assertLocationInTripCountry(
  BuildContext context,
  Trip? trip,
  String? locationCountryCode,
) async {
  if (trip == null) return true;
  final tripCode = trip.countryCode;
  if (tripCode == null) return true;
  // Unknown location-side country: allow rather than block, otherwise the
  // manual-coord paths (no place_id, no reverse-geocode hit) would be
  // unreachable. We only block on a *known* mismatch.
  if (locationCountryCode == null) return true;
  if (locationCountryCode.toUpperCase() == tripCode.toUpperCase()) return true;

  final tripCountry = findCountryByCode(tripCode);
  final locationCountry = findCountryByCode(locationCountryCode);
  final tripDisplay = tripCountry != null
      ? '${tripCountry.flagEmoji} ${tripCountry.name}'
      : tripCode.toUpperCase();
  final locationDisplay = locationCountry != null
      ? '${locationCountry.flagEmoji} ${locationCountry.name}'
      : locationCountryCode.toUpperCase();

  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Row(
        children: [
          Icon(Icons.public_off_rounded, color: Colors.red),
          SizedBox(width: 12),
          Expanded(child: Text('Different country')),
        ],
      ),
      content: Text(
        'This location is in $locationDisplay, but "${trip.name}" is tagged '
        'for $tripDisplay. Locations from a different country can\'t be '
        'added to this trip.',
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('OK'),
        ),
      ],
    ),
  );
  return false;
}
