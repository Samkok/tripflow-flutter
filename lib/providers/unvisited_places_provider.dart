import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/location_model.dart';
import 'trip_provider.dart';

/// Whether the map draws the ended trip's unvisited places. Off by default:
/// they left their days for the "Not visited" section and appear on the map
/// only when asked for, from that section's switch.
final showUnvisitedOnMapProvider = StateProvider<bool>((_) => false);

/// The day's places for the MAP. Normally the day list (the ended trip's
/// unvisited places already pulled out of it). While the "Not visited"
/// switch is on, ONLY those unvisited places: the preview shows what was
/// missed and nothing else, with a banner on the map saying so.
final mapLocationsForSelectedDateProvider =
    Provider<List<LocationModel>>((ref) {
  if (ref.watch(showUnvisitedOnMapProvider)) {
    final leftovers = ref.watch(endedTripUnvisitedProvider);
    if (leftovers.isNotEmpty) return leftovers;
  }
  return ref.watch(locationsForSelectedDateProvider);
});

/// True while the map previews the unvisited places — the day's route,
/// its chips, collars and stop names stand down for the duration.
final unvisitedPreviewActiveProvider = Provider<bool>((ref) =>
    ref.watch(showUnvisitedOnMapProvider) &&
    ref.watch(endedTripUnvisitedProvider.select((l) => l.isNotEmpty)));
