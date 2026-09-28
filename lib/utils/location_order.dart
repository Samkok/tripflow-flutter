import '../models/saved_location.dart';

/// Order for the trip page's lists: the place added last comes first, so
/// what was just added is the first card under its day's header.
///
/// Places added in the same instant (a batch) fall back to the id so the
/// order is the same on every rebuild.
int newestAddedFirst(SavedLocation a, SavedLocation b) {
  final byAdded = b.createdAt.compareTo(a.createdAt);
  return byAdded != 0 ? byAdded : a.id.compareTo(b.id);
}

/// [locations] as a new list, newest added first.
List<SavedLocation> sortedNewestAddedFirst(Iterable<SavedLocation> locations) =>
    locations.toList()..sort(newestAddedFirst);
