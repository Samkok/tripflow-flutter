import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:google_maps_url_extractor/google_maps_url_extractor.dart';
import 'package:voyza/providers/map_ui_state_provider.dart';
import 'package:uuid/uuid.dart';
import '../models/location_model.dart';
import '../providers/paginated_search_provider.dart';
import '../providers/trip_collaborator_provider.dart';
import '../services/places_service.dart';
import '../services/location_add_service.dart';
import '../core/theme.dart';
import 'google_maps_url_dialog.dart';

final searchQueryProvider = StateProvider.autoDispose<String>((ref) => '');

class SearchWidget extends ConsumerStatefulWidget {
  final FocusNode? focusNode;

  const SearchWidget({super.key, this.focusNode});

  @override
  ConsumerState<SearchWidget> createState() => _SearchWidgetState();
}

class _SearchWidgetState extends ConsumerState<SearchWidget> {
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    // Add scroll listener for infinite scroll
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    _debounceTimer?.cancel();
    super.dispose();
  }

  void _onScroll() {
    // Load more when user scrolls to 80% of the list
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent * 0.8) {
      ref.read(paginatedSearchProvider.notifier).loadMore();
    }
  }

  void _onSearchChanged(String value) {
    ref.read(searchQueryProvider.notifier).state = value;

    // Cancel previous timer
    _debounceTimer?.cancel();

    // Debounce search to avoid too many API calls
    _debounceTimer = Timer(const Duration(milliseconds: 300), () {
      if (value.isEmpty) {
        ref.read(paginatedSearchProvider.notifier).clear();
      } else {
        ref.read(paginatedSearchProvider.notifier).search(value);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0),
          child: Consumer(
            builder: (context, ref, child) {
              final searchQuery = ref.watch(searchQueryProvider);
              return TextField(
                focusNode: widget.focusNode,
                controller: _searchController,
                onChanged: _onSearchChanged,
                decoration: InputDecoration(
                  filled: false,
                  hintText: 'Search for places...',
                  prefixIcon: const Icon(
                    Icons.search,
                    color: AppTheme.primaryColor,
                  ),
                  suffixIcon: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.link),
                        tooltip: 'Paste Google Maps link',
                        onPressed: _showUrlInputDialog,
                      ),
                      if (searchQuery.isNotEmpty)
                        IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: () {
                            _searchController.clear();
                            ref.read(searchQueryProvider.notifier).state = '';
                            ref.read(paginatedSearchProvider.notifier).clear();
                          },
                        ),
                    ],
                  ),
                  border: InputBorder.none,
                ),
              );
            },
          ),
        ),
        Consumer(
          builder: (context, ref, child) {
            final searchQuery = ref.watch(searchQueryProvider);
            if (searchQuery.isEmpty) return const SizedBox.shrink();

            final searchState = ref.watch(paginatedSearchProvider);

            return Column(
              children: [
                const Divider(height: 1, thickness: 1),
                _buildSearchResults(searchState),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _buildSearchResults(PaginatedSearchState searchState) {
    // Calculate max height for the search results
    final screenHeight = MediaQuery.of(context).size.height;
    final topPadding = MediaQuery.of(context).padding.top;

    const searchBarHeight = 60.0;
    const topSpacing = 50.0;
    const spacing = 12.0;
    const bottomSheetCollapsedHeight = 100.0;
    const bottomPadding = 20.0;

    final maxHeight = screenHeight -
        topPadding -
        topSpacing -
        searchBarHeight -
        spacing -
        bottomSheetCollapsedHeight -
        bottomPadding;

    // Show initial loading
    if (searchState.isLoading && searchState.results.isEmpty) {
      return Container(
        constraints: BoxConstraints(maxHeight: maxHeight > 100 ? maxHeight : 100),
        child: const Center(
          child: Padding(
            padding: EdgeInsets.all(16.0),
            child: CircularProgressIndicator(),
          ),
        ),
      );
    }

    // Show error
    if (searchState.error != null && searchState.results.isEmpty) {
      return Container(
        constraints: BoxConstraints(maxHeight: maxHeight > 100 ? maxHeight : 100),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Text(
              'Error: ${searchState.error}',
              style: const TextStyle(color: Colors.red),
            ),
          ),
        ),
      );
    }

    // Show no results
    if (searchState.results.isEmpty) {
      return Container(
        constraints: BoxConstraints(maxHeight: maxHeight > 100 ? maxHeight : 100),
        child: const Center(
          child: Padding(
            padding: EdgeInsets.all(16.0),
            child: Text('No places found'),
          ),
        ),
      );
    }

    // Show results with infinite scroll
    return Container(
      constraints: BoxConstraints(
        maxHeight: maxHeight > 100 ? maxHeight : 100,
      ),
      child: ListView.separated(
        controller: _scrollController,
        shrinkWrap: true,
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: searchState.results.length + (searchState.hasMore ? 1 : 0),
        separatorBuilder: (context, index) => const Divider(),
        itemBuilder: (context, index) {
          // Show loading indicator at the end
          if (index == searchState.results.length) {
            return Padding(
              padding: const EdgeInsets.all(16.0),
              child: Center(
                child: searchState.isLoading
                    ? const SizedBox(
                        height: 24,
                        width: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const SizedBox.shrink(),
              ),
            );
          }

          final prediction = searchState.results[index];
          return _buildPredictionTile(prediction);
        },
      ),
    );
  }

  Widget _buildPredictionTile(PlacePrediction prediction) {
    return ListTile(
      title: Text(
        prediction.mainText,
        style: Theme.of(context).textTheme.titleMedium,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            prediction.secondaryText,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          if (prediction.distanceMeters != null) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                const Icon(
                  Icons.near_me,
                  size: 12,
                  color: AppTheme.primaryColor,
                ),
                const SizedBox(width: 4),
                Text(
                  _formatDistance(prediction.distanceMeters!),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppTheme.primaryColor,
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ],
            ),
          ],
        ],
      ),
      leading: const CircleAvatar(
        backgroundColor: AppTheme.primaryColor,
        child: Icon(
          Icons.location_on,
          color: Colors.black,
        ),
      ),
      onTap: () => _selectPlace(prediction),
    );
  }

  String _formatDistance(int distanceMeters) {
    if (distanceMeters < 1000) {
      return '${distanceMeters}m away';
    } else {
      final kilometers = distanceMeters / 1000;
      return '${kilometers.toStringAsFixed(1)}km away';
    }
  }

  bool _isPastingUrl = false;

  Future<void> _showUrlInputDialog() async {
    final url = await showDialog<String>(
      context: context,
      builder: (context) => const GoogleMapsUrlDialog(),
    );
    if (url != null && url.isNotEmpty) {
      _processGoogleMapsUrl(url);
    }
  }

  Future<void> _processGoogleMapsUrl(String text) async {
    if (_isPastingUrl) return;

    if (!GoogleMapsUrlExtractor.isValidGoogleMapsUrl(text)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Not a valid Google Maps link'),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }

    setState(() => _isPastingUrl = true);

    try {
      PlaceDetails? placeDetails;

      // Try extracting coordinates from the URL
      try {
        final coordinates =
            await GoogleMapsUrlExtractor.processGoogleMapsUrl(text);
        if (coordinates != null &&
            coordinates['latitude'] != null &&
            coordinates['longitude'] != null) {
          final lat = coordinates['latitude'] as double;
          final lng = coordinates['longitude'] as double;
          placeDetails =
              await PlacesService.getPlaceFromCoordinates(LatLng(lat, lng));
        }
      } catch (_) {}

      // Fallback: expand short URL and geocode the q parameter
      if (placeDetails == null) {
        String? expandedUrl;
        try {
          expandedUrl = await GoogleMapsUrlExtractor.expandShortUrl(text);
        } catch (_) {}
        final urlToParse = expandedUrl ?? text;
        final uri = Uri.tryParse(urlToParse);
        final query = uri?.queryParameters['q'];
        if (query != null && query.isNotEmpty) {
          placeDetails = await PlacesService.getPlaceFromAddress(query);
        }
      }

      if (placeDetails == null || !mounted) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Could not decode location from URL'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }

      // Reuse the same validation checks as _selectPlace
      final hasWriteAccess =
          await ref.read(hasActiveTripWriteAccessProvider.future);
      if (!hasWriteAccess) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                  'You don\'t have permission to add locations to this trip.'),
              backgroundColor: Colors.orange,
            ),
          );
        }
        return;
      }

      final selectedDate = ref.read(selectedDateProvider);
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      if (selectedDate.isBefore(today)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Cannot add locations to a past date.'),
              backgroundColor: Colors.orange,
            ),
          );
        }
        return;
      }

      final location = LocationModel(
        id: const Uuid().v4(),
        name: placeDetails.name,
        address: placeDetails.address,
        coordinates: placeDetails.coordinates,
        addedAt: DateTime.now(),
        scheduledDate: selectedDate,
        photoReference: placeDetails.photoReference,
        photoAttributions: placeDetails.photoAttributions,
      );

      if (!mounted) return;
      final added = await LocationAddService(ref).addLocation(context, location);
      if (!added) return;

      widget.focusNode?.unfocus();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Added ${location.name} to your trip'),
            backgroundColor: AppTheme.primaryColor,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to decode URL: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isPastingUrl = false);
    }
  }

  Future<void> _selectPlace(PlacePrediction prediction) async {
    // Check if user has write access to the active trip
    final hasWriteAccess = await ref.read(hasActiveTripWriteAccessProvider.future);

    if (!hasWriteAccess) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('You don\'t have permission to add locations to this trip.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    // Check if trying to add to a past date
    final selectedDate = ref.read(selectedDateProvider);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    if (selectedDate.isBefore(today)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Cannot add locations to a past date.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final placeDetails =
        await PlacesService.getPlaceDetails(prediction.placeId);

    if (placeDetails != null) {
      if (!mounted) return;

      final location = LocationModel(
        id: const Uuid().v4(),
        name: placeDetails.name,
        address: placeDetails.address,
        coordinates: placeDetails.coordinates,
        addedAt: DateTime.now(),
        scheduledDate: selectedDate,
        photoReference: placeDetails.photoReference,
        photoAttributions: placeDetails.photoAttributions,
      );

      final added = await LocationAddService(ref).addLocation(context, location);
      if (!added) return;

      _searchController.clear();
      ref.read(searchQueryProvider.notifier).state = '';
      ref.read(paginatedSearchProvider.notifier).clear();

      // Dismiss the keyboard
      widget.focusNode?.unfocus();

      // Show snackbar
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Added ${location.name} to your trip'),
            backgroundColor: AppTheme.primaryColor,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }
}

