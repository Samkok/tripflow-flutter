import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:google_maps_url_extractor/google_maps_url_extractor.dart';
import 'package:uuid/uuid.dart';
import 'package:voyza/core/theme.dart';
import 'package:voyza/models/location_model.dart';
import 'package:voyza/providers/local_active_trip_provider.dart';
import 'package:voyza/providers/map_ui_state_provider.dart';
import 'package:voyza/providers/paginated_search_provider.dart';
import 'package:voyza/providers/trip_collaborator_provider.dart';
import 'package:voyza/services/location_add_service.dart';
import 'package:voyza/services/places_service.dart';
import 'package:voyza/widgets/app_toast.dart';
import 'package:voyza/widgets/google_maps_url_dialog.dart';
import 'package:voyza/widgets/search_widget.dart' show searchQueryProvider;

/// Full-screen replacement for the inline search-bar focus flow. Pushed
/// from the map screen via [Navigator.push] when the user taps the fake
/// search bar. Owns its own Scaffold and TextField so standard keyboard
/// handling works cleanly — no more focus-driven layout shifts on the
/// map screen.
///
/// Selection / paste-URL behavior is intentionally identical to the old
/// inline [SearchWidget]: same providers ([paginatedSearchProvider],
/// [searchQueryProvider]), same [LocationAddService.beforeAddingLocation]
/// gating, same SnackBar copy. Only the chrome changes.
class LocationSearchScreen extends ConsumerStatefulWidget {
  const LocationSearchScreen({super.key});

  @override
  ConsumerState<LocationSearchScreen> createState() =>
      _LocationSearchScreenState();
}

class _LocationSearchScreenState extends ConsumerState<LocationSearchScreen> {
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _focusNode = FocusNode();
  Timer? _debounceTimer;
  bool _isPastingUrl = false;
  bool _focusRequested = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    // Pre-fill any in-progress query so the screen reopens "where you
    // left off" if the user pops and re-pushes mid-search.
    final existing = ref.read(searchQueryProvider);
    if (existing.isNotEmpty) {
      _searchController.text = existing;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Defer the focus request until the page-transition animation
    // finishes. Using `autofocus: true` on the TextField opens the
    // keyboard immediately as the screen is being pushed — that
    // keyboard event propagates through MediaQuery to the still-
    // mounted map screen underneath, and you see the map "pull down"
    // for the brief moment before this screen finishes covering it.
    // Waiting for the route animation to complete keeps the keyboard
    // event contained to a moment when only this screen is visible.
    if (_focusRequested) return;
    _focusRequested = true;
    final animation = ModalRoute.of(context)?.animation;
    if (animation == null ||
        animation.status == AnimationStatus.completed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusNode.requestFocus();
      });
      return;
    }
    void onStatus(AnimationStatus status) {
      if (status == AnimationStatus.completed) {
        animation.removeStatusListener(onStatus);
        if (mounted) _focusNode.requestFocus();
      }
    }
    animation.addStatusListener(onStatus);
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    _debounceTimer?.cancel();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent * 0.8) {
      ref.read(paginatedSearchProvider.notifier).loadMore();
    }
  }

  void _onSearchChanged(String value) {
    ref.read(searchQueryProvider.notifier).state = value;

    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 300), () {
      if (value.isEmpty) {
        ref.read(paginatedSearchProvider.notifier).clear();
      } else {
        final activeTrip = ref.read(localActiveTripProvider).asData?.value;
        ref.read(paginatedSearchProvider.notifier).search(
              value,
              countryCodeOverride: activeTrip?.countryCode,
            );
      }
    });
  }

  String _formatDistance(int distanceMeters) {
    if (distanceMeters < 1000) return '${distanceMeters}m away';
    return '${(distanceMeters / 1000).toStringAsFixed(1)}km away';
  }

  Future<void> _selectPlace(PlacePrediction prediction) async {
    final hasWriteAccess =
        await ref.read(hasActiveTripWriteAccessProvider.future);
    if (!hasWriteAccess) {
      if (!mounted) return;
      AppToast.warning(
        context,
        'You don\'t have permission to add locations to this trip.',
      );
      return;
    }

    final selectedDate = ref.read(selectedDateProvider);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    if (selectedDate.isBefore(today)) {
      if (!mounted) return;
      AppToast.warning(context, 'Cannot add locations to a past date.');
      return;
    }

    final placeDetails =
        await PlacesService.getPlaceDetails(prediction.placeId);
    if (placeDetails == null || !mounted) return;

    final location = LocationModel(
      id: const Uuid().v4(),
      name: placeDetails.name,
      address: placeDetails.address,
      coordinates: placeDetails.coordinates,
      addedAt: DateTime.now(),
      scheduledDate: selectedDate,
      photoReference: placeDetails.photoReference,
      photoReferences: placeDetails.photoReferences,
      photoAttributions: placeDetails.photoAttributions,
      placeId: placeDetails.placeId ?? prediction.placeId,
      originalName: placeDetails.name,
    );

    final added = await LocationAddService(ref).beforeAddingLocation(
      context,
      location,
      locationCountryCode: placeDetails.countryCode,
    );
    if (!added || !mounted) return;

    _searchController.clear();
    ref.read(searchQueryProvider.notifier).state = '';
    ref.read(paginatedSearchProvider.notifier).clear();

    // Pop back to the map. SnackBar fires after pop so the user lands
    // on the map screen with the confirmation visible there (where the
    // new pin has just appeared).
    Navigator.of(context).pop();
    AppToast.success(context, 'Added ${location.name} to your trip');
  }

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
        AppToast.warning(context, 'Not a valid Google Maps link');
      }
      return;
    }

    setState(() => _isPastingUrl = true);

    try {
      PlaceDetails? placeDetails;

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
          AppToast.error(context, 'Could not decode location from URL');
        }
        return;
      }

      final hasWriteAccess =
          await ref.read(hasActiveTripWriteAccessProvider.future);
      if (!hasWriteAccess) {
        if (mounted) {
          AppToast.warning(
            context,
            'You don\'t have permission to add locations to this trip.',
          );
        }
        return;
      }

      final selectedDate = ref.read(selectedDateProvider);
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      if (selectedDate.isBefore(today)) {
        if (mounted) {
          AppToast.warning(context, 'Cannot add locations to a past date.');
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
        photoReferences: placeDetails.photoReferences,
        photoAttributions: placeDetails.photoAttributions,
        placeId: placeDetails.placeId,
        originalName: placeDetails.name,
        googleOpeningHours: placeDetails.openingHours,
        hoursLastRefreshedAt:
            placeDetails.openingHours != null ? DateTime.now() : null,
      );

      if (!mounted) return;
      final added = await LocationAddService(ref).beforeAddingLocation(
        context,
        location,
        locationCountryCode: placeDetails.countryCode,
      );
      if (!added || !mounted) return;

      Navigator.of(context).pop();
      AppToast.success(context, 'Added ${location.name} to your trip');
    } catch (e) {
      if (mounted) {
        AppToast.error(context, 'Failed to decode URL: $e');
      }
    } finally {
      if (mounted) setState(() => _isPastingUrl = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final searchQuery = ref.watch(searchQueryProvider);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        titleSpacing: 0,
        title: TextField(
          controller: _searchController,
          focusNode: _focusNode,
          // No `autofocus: true` — focus is requested manually in
          // didChangeDependencies after the route animation completes,
          // so the keyboard never opens during the slide-in. (Opening
          // during the transition propagates a MediaQuery viewInsets
          // change to the still-mounted map screen behind us and
          // visually "pulls it down" for a moment.)
          onChanged: _onSearchChanged,
          decoration: const InputDecoration(
            hintText: 'Search for places...',
            border: InputBorder.none,
          ),
          style: theme.textTheme.titleMedium,
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.link),
            tooltip: 'Paste Google Maps link',
            onPressed: _isPastingUrl ? null : _showUrlInputDialog,
          ),
          if (searchQuery.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.clear),
              tooltip: 'Clear',
              onPressed: () {
                _searchController.clear();
                ref.read(searchQueryProvider.notifier).state = '';
                ref.read(paginatedSearchProvider.notifier).clear();
              },
            ),
        ],
      ),
      body: _buildResults(),
    );
  }

  Widget _buildResults() {
    final searchQuery = ref.watch(searchQueryProvider);

    if (searchQuery.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.search,
                size: 64,
                color: Theme.of(context)
                    .colorScheme
                    .primary
                    .withValues(alpha: 0.4),
              ),
              const SizedBox(height: 12),
              Text(
                'Type a place name to start searching',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    final searchState = ref.watch(paginatedSearchProvider);

    if (searchState.isLoading && searchState.results.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (searchState.error != null && searchState.results.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'Error: ${searchState.error}',
            style: const TextStyle(color: Colors.red),
          ),
        ),
      );
    }

    if (searchState.results.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('No places found'),
        ),
      );
    }

    return ListView.separated(
      controller: _scrollController,
      itemCount:
          searchState.results.length + (searchState.hasMore ? 1 : 0),
      separatorBuilder: (context, index) => const Divider(height: 1),
      itemBuilder: (context, index) {
        if (index == searchState.results.length) {
          return Padding(
            padding: const EdgeInsets.all(16),
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
        return ListTile(
          leading: const CircleAvatar(
            backgroundColor: AppTheme.primaryColor,
            child: Icon(Icons.location_on, color: Colors.black),
          ),
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
                      style:
                          Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: AppTheme.primaryColor,
                                fontWeight: FontWeight.w600,
                              ),
                    ),
                  ],
                ),
              ],
            ],
          ),
          onTap: () => _selectPlace(prediction),
        );
      },
    );
  }
}
