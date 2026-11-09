import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/trip.dart';
import 'auth_provider.dart';
import 'local_active_trip_provider.dart';

/// Real-time active trip with Riverpod integration
/// Now uses LOCAL storage instead of database for trip activation
/// This allows each user to independently activate/deactivate trips
///
/// Uses currentUserIdProvider instead of authStateProvider so this provider
/// does NOT restart on every Supabase token refresh — only on login / logout.
final realtimeActiveTripProvider = StreamProvider<Trip?>((ref) async* {
  // currentUserIdProvider is a Provider<String?> whose value only changes on
  // login/logout (not on token refresh), preventing unnecessary stream restarts.
  // Guests flow through too: their active trip resolves from the local
  // trip store via localActiveTripProvider (userTripsProvider serves local
  // trips when signed out).
  ref.watch(currentUserIdProvider);

  // Watch the local active trip provider
  // This emits whenever the locally stored active trip ID changes
  final localActiveTripAsync = ref.watch(localActiveTripProvider);

  // valueOrNull: keep the previous trip through localActiveTripProvider
  // refreshes instead of yielding null for a frame.
  final activeTrip = localActiveTripAsync.valueOrNull;
  debugPrint(
      'realtimeActiveTripProvider: Local active trip - ${activeTrip?.id}');

  yield activeTrip;

  // Note: We no longer listen to trip events for activation/deactivation
  // since those are now purely local operations
  // The localActiveTripProvider will automatically update when changed
});

/// The active trip's declared start→end as a day-normalized range (null
/// when either end is missing). THE one source for the calendar band in
/// every date picker — a copy of this logic in one picker and not another
/// gave different calendars different bands.
DateTimeRange? activeTripDateRange(WidgetRef ref) {
  final trip = ref.read(realtimeActiveTripProvider).valueOrNull;
  final start = trip?.startDate;
  final end = trip?.endDate;
  if (start == null || end == null) return null;
  final s = DateTime(start.year, start.month, start.day);
  final e = DateTime(end.year, end.month, end.day);
  if (s.isAfter(e)) return null; // never hand DateTimeRange an inversion
  return DateTimeRange(start: s, end: e);
}
