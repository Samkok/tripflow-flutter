import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/places_service.dart';

class PaginatedSearchState {
  final List<PlacePrediction> results;
  final bool isLoading;
  final bool hasMore;
  final String? error;
  final String currentQuery;

  const PaginatedSearchState({
    this.results = const [],
    this.isLoading = false,
    this.hasMore = true,
    this.error,
    this.currentQuery = '',
  });

  PaginatedSearchState copyWith({
    List<PlacePrediction>? results,
    bool? isLoading,
    bool? hasMore,
    String? error,
    String? currentQuery,
  }) {
    return PaginatedSearchState(
      results: results ?? this.results,
      isLoading: isLoading ?? this.isLoading,
      hasMore: hasMore ?? this.hasMore,
      error: error,
      currentQuery: currentQuery ?? this.currentQuery,
    );
  }
}

class PaginatedSearchNotifier extends StateNotifier<PaginatedSearchState> {
  PaginatedSearchNotifier() : super(const PaginatedSearchState());

  static const int _pageSize = 5;
  int _currentOffset = 0;
  String? _countryCodeOverride;

  /// Search with a new query.
  ///
  /// [countryCodeOverride] — when provided, prioritises results from this
  /// ISO 3166-1 alpha-2 country instead of the device's current country.
  /// Used so a planned trip's destination biases search before the user
  /// physically arrives there.
  Future<void> search(String query, {String? countryCodeOverride}) async {
    if (query.isEmpty) {
      state = const PaginatedSearchState();
      return;
    }

    // If query changed, reset pagination
    if (query != state.currentQuery) {
      _currentOffset = 0;
      _countryCodeOverride = countryCodeOverride;
      state = PaginatedSearchState(
        isLoading: true,
        currentQuery: query,
      );
    } else if (state.isLoading || !state.hasMore) {
      return; // Already loading or no more results
    } else {
      state = state.copyWith(isLoading: true);
    }

    try {
      final newResults = await PlacesService.searchPlacesPaginated(
        query,
        offset: _currentOffset,
        limit: _pageSize,
        countryCodeOverride: _countryCodeOverride,
      );

      // If we got fewer results than requested, we've reached the end
      final hasMore = newResults.length >= _pageSize;

      // Append new results to existing ones (for pagination)
      final allResults =
          _currentOffset == 0 ? newResults : [...state.results, ...newResults];

      _currentOffset = _currentOffset + newResults.length;

      state = state.copyWith(
        results: allResults,
        isLoading: false,
        hasMore: hasMore,
        currentQuery: query,
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: e.toString(),
      );
    }
  }

  /// Load next page of results
  Future<void> loadMore() async {
    if (state.currentQuery.isEmpty || state.isLoading || !state.hasMore) {
      return;
    }

    // Reuse the override captured on the initial search so pagination keeps
    // the same country bias across pages.
    await search(
      state.currentQuery,
      countryCodeOverride: _countryCodeOverride,
    );
  }

  /// Clear search results
  void clear() {
    _currentOffset = 0;
    _countryCodeOverride = null;
    state = const PaginatedSearchState();
  }
}

final paginatedSearchProvider =
    StateNotifierProvider<PaginatedSearchNotifier, PaginatedSearchState>(
  (ref) => PaginatedSearchNotifier(),
);

/// Separate provider for trip detail location search (independent of map search)
final tripDetailSearchProvider =
    StateNotifierProvider<PaginatedSearchNotifier, PaginatedSearchState>(
  (ref) => PaginatedSearchNotifier(),
);
