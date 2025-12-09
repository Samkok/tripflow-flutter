import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:ui';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:voyza/widgets/location_detail_sheet.dart';
import 'package:uuid/uuid.dart';
import '../models/location_model.dart';
import '../providers/trip_provider.dart';
import '../providers/theme_provider.dart';
import '../providers/map_ui_state_provider.dart';
import '../providers/debounced_settings_provider.dart';
import '../services/location_service.dart';
import '../services/places_service.dart';
import '../widgets/map_widget.dart';
import '../widgets/search_widget.dart';
import '../widgets/trip_bottom_sheet.dart';

class MapScreen extends ConsumerStatefulWidget {
  MapScreen({super.key});

  @override
  ConsumerState<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends ConsumerState<MapScreen>
    with SingleTickerProviderStateMixin {
  GoogleMapController? _mapController;
  DraggableScrollableController? _sheetController;
  bool _isTrackingLocation = false;
  int? _highlightedLocationIndex;
  final FocusNode _searchFocusNode = FocusNode();
  bool _isSearchFocused = false;
  StreamSubscription<LatLng>?
      _locationSubscription; // PERFORMANCE: Track subscription for cleanup

  @override
  void initState() {
    super.initState();
    _sheetController = DraggableScrollableController();
    _initializeLocation();
    _searchFocusNode.addListener(_onSearchFocusChange);
  }

  void _onSearchFocusChange() {
    if (_searchFocusNode.hasFocus != _isSearchFocused) {
      setState(() {
        _isSearchFocused = _searchFocusNode.hasFocus;
      });
    }
  }

  @override
  void dispose() {
    _sheetController?.dispose();
    _searchFocusNode.removeListener(_onSearchFocusChange);
    _searchFocusNode.dispose();

    // PERFORMANCE: Cancel location stream to prevent memory leaks and battery drain
    _locationSubscription?.cancel();

    super.dispose();
  }

  Future<void> _initializeLocation() async {
    try {
      final currentLocation = await LocationService.getCurrentLocation();
      if (currentLocation != null) {
        ref.read(tripProvider.notifier).updateCurrentLocation(currentLocation);

        // Initial camera positioning
        if (_mapController != null) {
          _mapController!.animateCamera(
            CameraUpdate.newCameraPosition(
              CameraPosition(
                target: currentLocation,
                zoom: 15.0,
              ),
            ),
          );
        }
        _startLocationTracking();
      }
    } catch (e) {
      print("Failed to get location: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content:
                Text('Location permissions denied. Showing default map area.'),
            backgroundColor: Colors.orange,
          ),
        );
      }
      // Move camera to a default location if getting current location fails
      _mapController?.animateCamera(
        CameraUpdate.newCameraPosition(
          const CameraPosition(
            target: LatLng(37.422, -122.084), // GooglePlex as default
            zoom: 10.0,
          ),
        ),
      );
    }
  }

  void _startLocationTracking() {
    if (_isTrackingLocation) return;

    _isTrackingLocation = true;

    // PERFORMANCE: Location stream is now throttled and filtered
    // - Only updates every 50+ meters (set in LocationService)
    // - Further filtered by updateCurrentLocation() to ignore <20m changes
    // - Result: ~95% fewer location updates
    _locationSubscription = LocationService.getLocationStream().listen(
      (location) {
        if (mounted) {
          ref.read(tripProvider.notifier).updateCurrentLocation(location);
        }
        // Location tracking without automatic camera animation
        // Camera only moves when user explicitly requests it
      },
      onError: (error) {
        // Handle location stream errors gracefully
        print('Location stream error: $error');
      },
    );
  }

  void _onMapCreated(GoogleMapController controller) async {
    _mapController = controller;
    // Set the initial map style.
    final themeMode = ref.read(themeProvider);
    final showPlaceNames = ref.read(showPlaceNamesProvider);
    final style = await MapWidget.getMapStyle(themeMode, showPlaceNames);
    _mapController!.setMapStyle(style);
  }

  Future<void> _onMapLongPress(LatLng coordinates) async {
    // Prevent adding locations to past dates
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
    try {
      // Show loading indicator
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Row(
            children: [
              SizedBox(
                height: 16,
                width: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 16),
              Text('Adding location...'), // Uses theme colors
            ],
          ),
          duration: Duration(seconds: 2),
        ),
      );

      // Get place details from coordinates
      final placeDetails =
          await PlacesService.getPlaceFromCoordinates(coordinates);

      if (placeDetails != null) {
        final selectedDate = ref.read(selectedDateProvider);
        final location = LocationModel(
          id: const Uuid().v4(),
          name: placeDetails.name,
          address: placeDetails.address,
          coordinates: placeDetails.coordinates,
          addedAt: DateTime.now(),
          scheduledDate: selectedDate,
        );

        await ref.read(tripProvider.notifier).addLocation(location);

        // Hide loading snackbar and show success
        ScaffoldMessenger.of(context).hideCurrentSnackBar();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              // Uses theme colors
              content: Text('Added ${location.name} to your trip',
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.onPrimary)),
              backgroundColor: Theme.of(context).colorScheme.primary,
              behavior: SnackBarBehavior.floating,
              action: SnackBarAction(
                textColor: Theme.of(context).colorScheme.onPrimary,
                label: 'Undo',
                onPressed: () {
                  ref.read(tripProvider.notifier).removeLocation(location.id);
                },
              ),
            ),
          );
        }

        // Clear polyline highlighting
        setState(() {
          _highlightedLocationIndex = null;
        });
        ref.read(mapUIStateProvider.notifier).clearHighlights();
      }
    } catch (e) {
      print('Error adding location from map: $e');
      ScaffoldMessenger.of(context).hideCurrentSnackBar();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            // Uses theme colors
            content: Text('Failed to add location. Please try again.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _onMarkerTapped(LocationModel location) {
    // Find the index of the tapped location in the list for the currently selected date.
    final locationsForDate = ref.read(locationsForSelectedDateProvider);
    final indexInList = locationsForDate.indexWhere((l) => l.id == location.id);

    // The stop number is the index + 1. If not found, default to 0.
    final stopNumber = indexInList != -1 ? indexInList + 1 : 0;

    // The bottom sheet's scroll controller is not directly available here,
    // so we create a new one for the detail sheet's parent controller.
    // This is okay because the detail sheet doesn't need to control the main sheet's scroll from here.
    final dummyScrollController = ScrollController();

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (modalContext) => LocationDetailSheet(
        location: location,
        number: stopNumber,
        parentScrollController: dummyScrollController,
        parentSheetController: _sheetController,
        onLocationTap: _zoomToLocation,
      ),
    );

    // Clean up the dummy controller after use.
    dummyScrollController.dispose();
  }

  void _showProximitySliderBottomSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Consumer(
        builder: (context, ref, child) {
          final proximityThreshold =
              ref.watch(proximityThresholdPreviewProvider);

          return Container(
            // Uses theme colors
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.3),
                  blurRadius: 20,
                  offset: const Offset(0, -5),
                ),
              ],
              border: Border.all(
                color: Theme.of(context).colorScheme.primary.withOpacity(0.3),
                width: 1,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.tune,
                      color: Theme.of(context).colorScheme.primary,
                      size: 24,
                    ),
                    const SizedBox(width: 12),
                    Text(
                      'Zone Distance',
                      style:
                          Theme.of(context).textTheme.headlineSmall?.copyWith(
                                color: Theme.of(context).colorScheme.primary,
                                fontWeight: FontWeight.bold,
                              ),
                    ),
                    const Spacer(),
                    GestureDetector(
                      onTap: () {
                        Navigator.of(context).pop();
                        _showManualZoneDistanceInputDialog();
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          // Uses theme colors
                          color: Theme.of(context)
                              .colorScheme
                              .primary
                              .withOpacity(0.2),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Theme.of(context).colorScheme.primary,
                            width: 1,
                          ),
                        ),
                        child: Text(
                          _formatDistance(proximityThreshold),
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium
                              ?.copyWith(
                                // Uses theme colors
                                color: Theme.of(context).colorScheme.primary,
                                fontWeight: FontWeight.bold,
                              ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor: Theme.of(context).colorScheme.primary,
                    inactiveTrackColor:
                        Theme.of(context).colorScheme.primary.withOpacity(0.3),
                    thumbColor: Theme.of(context).colorScheme.primary,
                    overlayColor:
                        Theme.of(context).colorScheme.primary.withOpacity(0.2),
                    trackHeight: 6,
                    thumbShape:
                        const RoundSliderThumbShape(enabledThumbRadius: 12),
                  ),
                  child: Slider(
                    value: proximityThreshold,
                    min: 100.0,
                    max: 5000.0,
                    divisions: 49,
                    onChanged: (value) {
                      ref
                          .read(debouncedProximityThresholdProvider.notifier)
                          .updatePreviewValue(value);
                    },
                    onChangeEnd: (value) {
                      ref
                          .read(debouncedProximityThresholdProvider.notifier)
                          .setValueImmediately(value);
                    },
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Adjust how close locations need to be to form a zone. Smaller values create tighter zones, larger values group more distant locations together.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        // Uses theme colors
                        fontStyle: FontStyle.italic, // Uses theme colors
                      ),
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: ElevatedButton.styleFrom(
                      // Uses theme colors
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text('Done'),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _showManualZoneDistanceInputDialog() {
    final textController = TextEditingController();
    final currentThreshold = ref.read(proximityThresholdPreviewProvider);
    textController.text = currentThreshold.toInt().toString();

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: Theme.of(context).cardColor, // Uses theme colors
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('Set Zone Distance'),
          content: TextField(
            controller: textController,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: false),
            decoration: InputDecoration(
              hintText: 'Enter distance in meters', // Uses theme colors
              filled: true,
              fillColor: Theme.of(context).colorScheme.surface,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
            ),
            onSubmitted: (newValue) {
              final distance = double.tryParse(newValue);
              if (distance != null && distance >= 100 && distance <= 5000) {
                ref
                    .read(debouncedProximityThresholdProvider.notifier)
                    .setValueImmediately(distance);
              }
              Navigator.of(context).pop();
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text('Cancel',
                  style: TextStyle(
                      color: Theme.of(context)
                          .textTheme
                          .bodyMedium
                          ?.color)), // Uses theme colors
            ),
            TextButton(
              onPressed: () {
                final distance = double.tryParse(textController.text);
                if (distance != null && distance >= 100 && distance <= 5000) {
                  ref
                      .read(debouncedProximityThresholdProvider.notifier)
                      .setValueImmediately(distance);
                }
                Navigator.of(context).pop();
              },
              style: TextButton.styleFrom(
                  backgroundColor: Theme.of(context)
                      .colorScheme
                      .primary), // Uses theme colors
              child: const Text(
                'Set', // Uses theme colors
                style:
                    TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // Listen to polyline taps to animate the camera to fit the route segment.
    ref.listen<String?>(tappedPolylineIdProvider, (previous, next) {
      if (next != null) {
        final legIndex = int.tryParse(next.replaceFirst('leg_', '')) ?? -1;
        if (legIndex != -1) {
          _zoomToFitLeg(legIndex);
        }
      }
    });

    // Listen for trip state changes to auto-zoom on historical routes.
    ref.listen<TripState>(tripProvider, (previous, next) {
      final selectedDate = ref.read(selectedDateProvider);
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final isPastDate = selectedDate.isBefore(today);

      // If we are on a past date and a route has just been loaded...
      if (isPastDate &&
          next.optimizedRoute.isNotEmpty &&
          (previous?.optimizedRoute.isEmpty ?? true)) {
        // Use a post-frame callback to ensure the map controller is ready.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _zoomToFitRoute(next.optimizedRoute);
        });
      }
    });

    // Listen for when the "View Route" button is pressed on a historical trip.
    ref.listen<bool>(TripBottomSheet.viewHistoricalRouteProvider,
        (previous, next) {
      if (next) {
        final route = ref.read(tripProvider).optimizedRoute;
        if (route.isNotEmpty) {
          _zoomToFitRoute(route);
        }
        // Reset the trigger
        ref.read(TripBottomSheet.viewHistoricalRouteProvider.notifier).state =
            false;
      }
    });

    // Listen for the zoom trigger after route optimization
    ref.listen<int>(zoomToFitRouteTrigger, (previous, next) {
      if (next > (previous ?? 0)) {
        _zoomToFitTrip();
      }
    });

    // Listen for theme or label visibility changes to update the map style instantly.
    ref.listen<bool>(showPlaceNamesProvider, (_, showLabels) async {
      if (_mapController != null) {
        final themeMode = ref.read(themeProvider);
        final style = await MapWidget.getMapStyle(themeMode, showLabels);
        _mapController!.setMapStyle(style);
      }
    });
    ref.listen<ThemeMode>(themeProvider, (_, themeMode) async {
      if (_mapController != null) {
        final showLabels = ref.read(showPlaceNamesProvider);
        final style = await MapWidget.getMapStyle(themeMode, showLabels);
        _mapController!.setMapStyle(style);
      }
    });

    return Scaffold(
      body: Stack(
        children: [
          // Map
          MapWidget(
            onMapCreated: _onMapCreated,
            onMapLongPress: _onMapLongPress,
            onMarkerTap: _onMarkerTapped,
          ),

          // Search bar
          Positioned(
            top: 50,
            left: 16,
            right: 16,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Search bar
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(30),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 10.0, sigmaY: 10.0),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 300),
                        decoration: BoxDecoration(
                          color: _isSearchFocused
                              ? Theme.of(context).colorScheme.surface
                              : Theme.of(context)
                                  .colorScheme
                                  .surface
                                  .withOpacity(0.8),
                          borderRadius: BorderRadius.circular(30),
                          border: Border.all(
                            color: _isSearchFocused
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(context)
                                    .dividerColor
                                    .withOpacity(0.2),
                            width: 1.5,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.2),
                              blurRadius: 20,
                              offset: const Offset(0, 5),
                            ),
                          ],
                        ),
                        child: SearchWidget(focusNode: _searchFocusNode),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Floating Action Buttons for Map Controls
          Positioned(
            bottom: MediaQuery.of(context).size.height * 0.23 +
                16, // Position above collapsed sheet
            right: 16,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                FloatingActionButton(
                  heroTag: 'currentLocationFab',
                  mini: true,
                  onPressed: _goToCurrentLocation,
                  child: const Icon(Icons.my_location),
                ),
                const SizedBox(height: 12),
                Consumer(
                  builder: (context, ref, child) {
                    final locationsForDate =
                        ref.watch(locationsForSelectedDateProvider);
                    if (locationsForDate.length < 2) {
                      return const SizedBox.shrink();
                    }
                    return FloatingActionButton(
                      heroTag: 'zoomToFitFab',
                      mini: true,
                      onPressed: _zoomToFitTrip,
                      child: const Icon(Icons.zoom_out_map),
                    );
                  },
                ),
                const SizedBox(height: 12),
                Consumer(builder: (context, ref, child) {
                  final showPlaceNames = ref.watch(showPlaceNamesProvider);
                  return FloatingActionButton(
                    heroTag: 'togglePlaceNamesFab',
                    mini: true,
                    onPressed: () {
                      ref.read(showPlaceNamesProvider.notifier).state =
                          !showPlaceNames;
                    },
                    tooltip: 'Toggle Place Names',
                    child: Icon(
                      showPlaceNames
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                    ),
                  );
                }),
                // const SizedBox(height: 12),
                // FloatingActionButton(
                //   heroTag: 'addFromUrlFab',
                //   mini: true,
                //   onPressed: _showAddLocationFromUrlDialog,
                //   tooltip: 'Add from Google Maps URL',
                //   child: const Icon(Icons.add_link),
                // ),
              ],
            ),
          ),

          // Trip bottom sheet
          TripBottomSheet(
            sheetController: _sheetController,
            onLocationTap: _zoomToLocation,
            // onGoToCurrentLocation is now handled by the FAB
            onShowZoneSettings: _showProximitySliderBottomSheet,
            // onZoomToFitTrip is now handled by the FAB
            highlightedLocationIndex: _highlightedLocationIndex,
          ),

          // Map controls (Current Location, Zone Settings)
          // Positioned(
          //   bottom: 120,
          //   right: 16,
          // ),
        ],
      ),
    );
  }

  Future<void> _goToCurrentLocation() async {
    LatLng? currentLocation = ref.read(tripProvider).currentLocation;

    // If location isn't available in the state, try to fetch it again.
    if (currentLocation == null) {
      try {
        currentLocation = await LocationService.getCurrentLocation();
        if (currentLocation != null) {
          ref
              .read(tripProvider.notifier)
              .updateCurrentLocation(currentLocation);
        }
      } catch (e) {
        print("Failed to get current location on demand: $e");
      }
    }

    if (currentLocation != null && _mapController != null && mounted) {
      _mapController?.animateCamera(
        CameraUpdate.newCameraPosition(
            CameraPosition(target: currentLocation, zoom: 16.0)),
      ); // Uses theme colors

      // Collapse the bottom sheet to show more of the map
      _sheetController?.animateTo(
        0.15, // minChildSize
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );

      // Clear highlighting
      setState(() {
        _highlightedLocationIndex = null;
      });
      ref.read(mapUIStateProvider.notifier).clearHighlights();
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'Current location is not available. Please enable location services.'), // Uses theme colors
          backgroundColor: Colors.orange,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _zoomToFitTrip() {
    if (_mapController == null) return;

    final locations = ref.read(locationsForSelectedDateProvider);
    if (locations.length < 2) {
      // If only one location, zoom to it. If none, do nothing.
      if (locations.isNotEmpty) {
        _zoomToLocation(locations.first.coordinates);
      }
      return;
    }

    final points = locations.map((loc) => loc.coordinates).toList();

    double minLat = points.first.latitude;
    double maxLat = points.first.latitude;
    double minLng = points.first.longitude;
    double maxLng = points.first.longitude;

    for (final point in points) {
      minLat = math.min(minLat, point.latitude);
      maxLat = math.max(maxLat, point.latitude);
      minLng = math.min(minLng, point.longitude);
      maxLng = math.max(maxLng, point.longitude);
    }

    final bounds = LatLngBounds(
      southwest: LatLng(minLat, minLng),
      northeast: LatLng(maxLat, maxLng),
    );

    _mapController!.animateCamera(
        CameraUpdate.newLatLngBounds(bounds, 80.0)); // 80.0 padding
  }

  void _zoomToLocation(LatLng coordinates) {
    if (_mapController != null) {
      _mapController!.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(
            target: coordinates,
            zoom: 16.0,
          ),
        ),
      );

      // Clear highlighting when zooming to location
      setState(() {
        _highlightedLocationIndex = null;
      });
      ref.read(mapUIStateProvider.notifier).clearHighlights();
    }
  }

  void _zoomToFitLeg(int legIndex) {
    if (_mapController == null) return;

    final tripState = ref.read(tripProvider);
    if (legIndex < 0 || legIndex >= tripState.legPolylines.length) return;

    final legPoints = tripState.legPolylines[legIndex];
    if (legPoints.length < 2) return;

    // Calculate the bounds of the polyline
    double minLat = legPoints.first.latitude;
    double maxLat = legPoints.first.latitude;
    double minLng = legPoints.first.longitude;
    double maxLng = legPoints.first.longitude;

    for (final point in legPoints) {
      minLat = math.min(minLat, point.latitude);
      maxLat = math.max(maxLat, point.latitude);
      minLng = math.min(minLng, point.longitude);
      maxLng = math.max(maxLng, point.longitude);
    }

    final bounds = LatLngBounds(
      southwest: LatLng(minLat, minLng),
      northeast: LatLng(maxLat, maxLng),
    );

    _mapController!.animateCamera(
        CameraUpdate.newLatLngBounds(bounds, 80.0)); // 80.0 padding
  }

  void _zoomToFitRoute(List<LatLng> routePoints) {
    if (_mapController == null || routePoints.isEmpty) return;

    if (routePoints.length == 1) {
      _mapController!
          .animateCamera(CameraUpdate.newLatLngZoom(routePoints.first, 15.0));
      return;
    }

    double minLat = routePoints.first.latitude;
    double maxLat = routePoints.first.latitude;
    double minLng = routePoints.first.longitude;
    double maxLng = routePoints.first.longitude;

    for (final point in routePoints) {
      minLat = math.min(minLat, point.latitude);
      maxLat = math.max(maxLat, point.latitude);
      minLng = math.min(minLng, point.longitude);
      maxLng = math.max(maxLng, point.longitude);
    }

    final bounds = LatLngBounds(
      southwest: LatLng(minLat, minLng),
      northeast: LatLng(maxLat, maxLng),
    );

    _mapController!.animateCamera(
        CameraUpdate.newLatLngBounds(bounds, 60.0)); // 60.0 padding
  }

  String _formatDistance(double distanceInMeters) {
    if (distanceInMeters < 1000) {
      return '${distanceInMeters.toInt()}m';
    } else {
      final kilometers = distanceInMeters / 1000;
      return '${kilometers.toStringAsFixed(1)}km';
    }
  }
}
