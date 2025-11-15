import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyza/providers/map_ui_state_provider.dart';
import 'package:uuid/uuid.dart';
import '../models/location_model.dart';
import '../providers/places_provider.dart';
import '../providers/trip_provider.dart';
import '../services/places_service.dart';
import '../core/theme.dart';

class SearchWidget extends ConsumerStatefulWidget {
  final FocusNode? focusNode;

  const SearchWidget({super.key, this.focusNode});

  @override
  ConsumerState<SearchWidget> createState() => _SearchWidgetState();
}

class _SearchWidgetState extends ConsumerState<SearchWidget> {
  final TextEditingController _searchController = TextEditingController();
  bool _isSearching = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0),
          child: TextField(
            focusNode: widget.focusNode,
            controller: _searchController,
            onChanged: (value) {
              setState(() {
                _isSearching = value.isNotEmpty;
              });
            },
            decoration: InputDecoration(
              filled: false, // Prevents the TextField from having its own background color
              hintText: 'Search for places...',
              prefixIcon: Icon(
                Icons.search,
                color: AppTheme.primaryColor,
              ),
              suffixIcon: _searchController.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _searchController.clear();
                        setState(() {
                          _isSearching = false;
                        });
                      },
                    )
                  : null,
              border: InputBorder.none,
            ),
          ),
        ),
        if (_isSearching) ...[
          const Divider(height: 1, thickness: 1),
          Consumer(
            builder: (context, ref, child) {
              final searchResults = ref.watch(
                placesSearchProvider(_searchController.text),
              );

              return searchResults.when(
                data: (predictions) => _buildPredictionsList(predictions),
                loading: () => const Padding(
                  padding: EdgeInsets.all(16.0),
                  child: CircularProgressIndicator(),
                ),
                error: (error, stack) => const SizedBox(),
              );
            },
          ),
        ],
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
    final placeDetails = await PlacesService.getPlaceDetails(prediction.placeId);
    
    if (placeDetails != null) {
      final selectedDate = ref.read(selectedDateProvider);
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
      setState(() {
        _isSearching = false;
      });

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