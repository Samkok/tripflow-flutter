import 'package:flutter/material.dart';

import '../models/trip.dart';
import '../services/day_distribution/day_window.dart';
import '../services/day_distribution/distribution_constants.dart';
import 'trip_dates.dart';

/// A trip's arrival time (first day) and departure time (last day), as the
/// screens say them. The rules behind the words — the hour kept free after
/// arriving, the three before leaving — live with Auto-plan in
/// day_distribution/day_window.dart; nothing here repeats a number.

/// The two times a trip can carry.
enum TripTimeField { arrival, departure }

/// [minute] after midnight the way the device shows times: "3:00 PM", or
/// "15:00" where the 24-hour clock is on.
String formatMinuteOfDay(BuildContext context, int minute) {
  final m = minute.clamp(0, 1439);
  return MaterialLocalizations.of(context).formatTimeOfDay(
    TimeOfDay(hour: m ~/ 60, minute: m % 60),
    alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
  );
}

/// True when the trip's first day is also its last: arrival and departure
/// then share one day.
bool tripIsOneDay(Trip trip) {
  final start = trip.startDate;
  final end = trip.endDate;
  return start != null && end != null && dayKey(start) == dayKey(end);
}

/// "Arrive 3:00 PM · Leave 2:00 PM" — whichever of the two is set, or null
/// when neither is. [time] formats a minute of the day.
String? tripTimesSummary(Trip trip, String Function(int minute) time) {
  final arrival = trip.arrivalMinute;
  final departure = trip.departureMinute;
  if (arrival == null && departure == null) return null;
  return [
    if (arrival != null) 'Arrive ${time(arrival)}',
    if (departure != null) 'Leave ${time(departure)}',
  ].join(' · ');
}

String _span(int minutes) {
  if (minutes % 60 != 0) return '$minutes minutes';
  final hours = minutes ~/ 60;
  return hours == 1 ? '1 hour' : '$hours hours';
}

/// What an arrival at [arrivalMinute] means for the first day.
String arrivalEffect(int arrivalMinute, String Function(int minute) time) {
  final window = dayWindowFor(
    isFirstDay: true,
    isLastDay: false,
    arrivalMinute: arrivalMinute,
  );
  if (window == null) return 'Early enough: you have the whole day.';
  if (!window.usable) {
    return 'Too late to plan visits that day. Auto-plan keeps it free.';
  }
  return 'Auto-plan starts this day at ${time(window.start)}, '
      '${_span(kArrivalBufferMinutes)} after you arrive.';
}

/// What a departure at [departureMinute] means for the last day.
String departureEffect(int departureMinute, String Function(int minute) time) {
  final window = dayWindowFor(
    isFirstDay: false,
    isLastDay: true,
    departureMinute: departureMinute,
  )!;
  if (!window.usable) {
    return 'Too early to plan visits that day. Auto-plan keeps it free.';
  }
  return 'Auto-plan ends this day at ${time(window.end)}, '
      '${_span(kDepartureBufferMinutes)} before you leave.';
}

/// On a one-day trip, true when the two times leave no time for a visit
/// between them even though each would on its own.
bool oneDayTripHasNoTime(int? arrivalMinute, int? departureMinute) {
  final window = dayWindowFor(
    isFirstDay: true,
    isLastDay: true,
    arrivalMinute: arrivalMinute,
    departureMinute: departureMinute,
  );
  return window != null && !window.usable;
}
