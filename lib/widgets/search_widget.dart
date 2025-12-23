import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyza/providers/map_ui_state_provider.dart';
import 'package:uuid/uuid.dart';
import '../models/location_model.dart';
import '../providers/places_provider.dart';
import '../providers/trip_provider.dart';
import '../providers/trip_collaborator_provider.dart';
import '../services/places_service.dart';
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
    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: predictions.length,
      separatorBuilder: (context, index) => const Divider(),
      itemBuilder: (context, index) {
        final prediction = predictions[index];
        return ListTile(
          title: Text(
            prediction.mainText,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          subtitle: Text(
            prediction.secondaryText,
            style: Theme.of(context).textTheme.bodyMedium,
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
    );
  }

  Future<void> _selectPlace(PlacePrediction prediction) async {
    // Check if user has write access to the active trip
    final hasWriteAccessAsync = ref.read(hasActiveTripWriteAccessProvider);
    final hasWriteAccess = hasWriteAccessAsync.asData?.value ?? false;

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
        scheduledDate: selectedDate, // Ensure the new location is scheduled for the current date
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
