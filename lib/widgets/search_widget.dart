import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyza/providers/map_ui_state_provider.dart';
import 'package:uuid/uuid.dart';
import '../models/location_model.dart';
import '../providers/places_provider.dart';
import '../providers/trip_provider.dart';
import '../providers/trip_collaborator_provider.dart';
import '../services/places_service.dart';
import '../services/subscription_limit_service.dart';
import '../core/theme.dart';

final searchQueryProvider = StateProvider.autoDispose<String>((ref) => '');

class SearchWidget extends ConsumerStatefulWidget {
  final FocusNode? focusNode;

  const SearchWidget({super.key, this.focusNode});

  @override
  ConsumerState<SearchWidget> createState() => _SearchWidgetState();
}

class _SearchWidgetState extends ConsumerState<SearchWidget> {
  final TextEditingController _searchController = TextEditingController();

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
                onChanged: (value) {
                  ref.read(searchQueryProvider.notifier).state = value;
                },
                decoration: InputDecoration(
                  filled: false,
                  hintText: 'Search for places...',
                  prefixIcon: Icon(
                    Icons.search,
                    color: AppTheme.primaryColor,
                  ),
                  suffixIcon: searchQuery.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: () {
                            _searchController.clear();
                            ref.read(searchQueryProvider.notifier).state = '';
                          },
                        )
                      : null,
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

            final searchResults = ref.watch(
              placesSearchProvider(searchQuery),
            );

            return Column(
              children: [
                const Divider(height: 1, thickness: 1),
                searchResults.when(
                  data: (predictions) => _buildPredictionsList(predictions),
                  loading: () => const Padding(
                    padding: EdgeInsets.all(16.0),
                    child: CircularProgressIndicator(),
                  ),
                  error: (error, stack) => const SizedBox(),
                ),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _buildPredictionsList(List<PlacePrediction> predictions) {
    // Calculate max height for the search results to fit between search bar and bottom sheet
    final screenHeight = MediaQuery.of(context).size.height;
    final topPadding = MediaQuery.of(context).padding.top;

    // UI elements heights
    final searchBarHeight = 60.0; // Search bar height
    final topSpacing = 50.0; // Top safe area + margins (50px from map_screen.dart line 621)
    final spacing = 12.0; // Spacing between elements

    // Bottom sheet collapsed height is 23% of screen height (from map_screen.dart line 770-771)
    final bottomSheetCollapsedHeight = screenHeight * 0.23;
    final bottomPadding = 20.0; // Buffer space above bottom sheet

    // Calculate available space for search results
    // Total space = screen height - (top padding + top spacing + search bar + spacing + bottom sheet + bottom padding)
    final maxHeight = screenHeight -
                     topPadding -
                     topSpacing -
                     searchBarHeight -
                     spacing -
                     bottomSheetCollapsedHeight -
                     bottomPadding;

    return Container(
      constraints: BoxConstraints(
        maxHeight: maxHeight > 100 ? maxHeight : 100, // Ensure minimum height of 100
      ),
      child: ListView.separated(
        shrinkWrap: true,
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: predictions.length,
        separatorBuilder: (context, index) => const Divider(),
        itemBuilder: (context, index) {
          final prediction = predictions[index];
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
                      Icon(
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
            leading: CircleAvatar(
              backgroundColor: AppTheme.primaryColor,
              child: const Icon(
                Icons.location_on,
                color: Colors.black,
              ),
            ),
            onTap: () => _selectPlace(prediction),
          );
        },
      ),
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

    // Check subscription limit - show paywall if limit reached
    final subscriptionLimitService = SubscriptionLimitService(ref);
    final canAdd = await subscriptionLimitService.canAddLocation(context);
    if (!canAdd) {
      return; // User hit limit and didn't upgrade
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
        scheduledDate: selectedDate, // Ensure the new location is scheduled for the current date
        photoReference: placeDetails.photoReference,
        photoAttributions: placeDetails.photoAttributions,
      );

      await ref.read(tripProvider.notifier).addLocation(location);

      _searchController.clear();
      ref.read(searchQueryProvider.notifier).state = '';

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

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }
}
