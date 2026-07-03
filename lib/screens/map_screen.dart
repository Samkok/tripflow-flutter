import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:ui';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:intl/intl.dart';
import 'package:tutorial_coach_mark/tutorial_coach_mark.dart';
import 'package:voyza/core/theme.dart';
import 'package:voyza/screens/location_search_screen.dart';
import 'package:voyza/screens/login_screen.dart';
import 'package:voyza/widgets/add_to_trip_sheet.dart';
import 'package:voyza/widgets/review_sentiment_dialog.dart';
import 'package:voyza/widgets/location_detail_sheet.dart';
import 'package:uuid/uuid.dart';
import '../models/location_model.dart';
import '../models/user_profile.dart';
import '../providers/location_provider.dart';
import '../providers/optimized_map_overlay_provider.dart';
import '../providers/trip_provider.dart';
import '../providers/trip_simulation_provider.dart';
import '../providers/theme_provider.dart';
import '../providers/map_ui_state_provider.dart';
import '../providers/debounced_settings_provider.dart';
import '../providers/trip_collaborator_provider.dart';
import '../providers/trip_listener_provider.dart';
import '../providers/local_active_trip_provider.dart';
import '../providers/onboarding_provider.dart';
import '../providers/auth_provider.dart';
import '../services/location_service.dart';
import '../services/places_service.dart';
import '../services/anonymous_user_service.dart';
import '../services/location_add_service.dart';
import '../services/onboarding_service.dart';
import '../providers/nearby_radius_provider.dart';
import '../providers/zoom_fit_settings_provider.dart';
import '../utils/countries.dart';
import '../widgets/app_toast.dart';
import '../providers/subscription_provider.dart';
import '../services/analytics_service.dart';
import '../widgets/celebration_dialogs.dart';
import '../widgets/free_places_meter.dart';
import '../widgets/map_tutorial.dart';
import '../widgets/referral_prompt.dart';
import '../widgets/map_widget.dart';
import '../widgets/nearby_places_picker_sheet.dart';
import '../widgets/trip_bottom_sheet.dart';

class MapScreen extends ConsumerStatefulWidget {
  const MapScreen({super.key});

  @override
  ConsumerState<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends ConsumerState<MapScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  GoogleMapController? _mapController;
  DraggableScrollableController? _sheetController;
  bool _isTrackingLocation = false;
  int? _highlightedLocationIndex;
  /// Set when [localActiveTripIdProvider] changes (activate / switch /
  /// deactivate). The actual camera move waits until [pinnedLocations]
  /// next emits, so we operate on the locations of the new trip rather
  /// than the old one (the sync listener that swaps locations is async).
  bool _pendingTripCameraMove = false;

  StreamSubscription<LatLng>?
      _locationSubscription; // PERFORMANCE: Track subscription for cleanup

  // OPTIMIZATION: Cache for lifecycle management
  AppLifecycleState? _lastLifecycleState;

  // ── One-time map spotlight tour ────────────────────────────────────────
  // Keys are State fields (created once) so the spotlight elements survive
  // rebuilds; the search bar lives in a Consumer's cached child and the
  // optimize button is passed down into TripBottomSheet.
  final _searchBarKey = GlobalKey();
  final _optimizeButtonKey = GlobalKey();
  bool _tutorialCheckInFlight = false;
  TutorialCoachMark? _activeTutorial;

  // Country of the device's current location, reverse-geocoded from the known
  // position (see [_resolveCurrentLocationCountry]). Used by "zoom to fit" to
  // exclude the current location when it's in a different country than the
  // active trip. Null until resolved (fit falls back to including it).
  String? _currentLocationCountry;
  LatLng? _currentLocationCountryFor;
  // Dedupes the cross-country "location not included" toast so repeated /
  // background fits don't spam it. Holds the last "trip>current" pair notified;
  // reset whenever the countries match again so a later mismatch re-notifies.
  String? _crossCountryFitNoticeKey;

  @override
  void initState() {
    super.initState();
    // OPTIMIZATION: Register as lifecycle observer to handle app state changes
    WidgetsBinding.instance.addObserver(this);
    _sheetController = DraggableScrollableController();
    _initializeLocation();
    // Session 2+: an anonymous user lands directly on the map tab with no
    // provider event, so check once after the first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeStartMapTutorial();
    });
  }

  // OPTIMIZATION: Handle app lifecycle to pause heavy operations when app is backgrounded
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lastLifecycleState = state;
    if (state == AppLifecycleState.paused) {
      // App is backgrounded - stop location tracking to save battery
      _locationSubscription?.pause();
    } else if (state == AppLifecycleState.resumed) {
      // App is resumed - resume location tracking
      _locationSubscription?.resume();
    }
  }

  @override
  void dispose() {
    // OPTIMIZATION: Remove lifecycle observer
    WidgetsBinding.instance.removeObserver(this);

    // Defensive: never strand the tutorial's OverlayEntry on teardown.
    _activeTutorial?.finish();
    _activeTutorial = null;

    _sheetController?.dispose();

    // PERFORMANCE: Cancel location stream to prevent memory leaks and battery drain
    _locationSubscription?.cancel();
    
    // OPTIMIZATION: Dispose map controller if still active
    _mapController = null;

    super.dispose();
  }

  /// One-time map spotlight tour (search → long-press → optimize).
  /// Gate chain, in order — every await is followed by a liveness re-check:
  ///  visible tab → settle delay → route current → loading overlay gone →
  ///  onboarding resolved → tour flag unset → show. Flag is marked on BOTH
  ///  finish and skip; app-kill mid-tour leaves it unset (tour repeats —
  ///  the correct failure direction).
  Future<void> _maybeStartMapTutorial() async {
    if (_tutorialCheckInFlight || _activeTutorial != null) return;
    _tutorialCheckInFlight = true;
    try {
      if (ref.read(selectedTabIndexProvider) != 1) return;

      // Let the landing settle (map paint, sheet snap, toasts).
      await Future.delayed(const Duration(milliseconds: 600));
      if (!mounted) return;
      if (ref.read(selectedTabIndexProvider) != 1) return;
      if (ModalRoute.of(context)?.isCurrent != true) return;

      // Don't spotlight through the map loading overlay — same pair of
      // conditions that dismisses it (see the Stack's loading branch).
      if (!ref.read(initialSyncCompleteProvider)) return;
      if (!ref.read(cachedMarkerBitmapsProvider).hasValue) return;

      final effectiveId = ref.read(currentUserIdProvider) ??
          await AnonymousUserService.id;
      if (!mounted) return;

      final service = OnboardingService.instance;
      // Only after onboarding is resolved (completed/skipped/seeded) — the
      // tour must never race the onboarding route.
      if (await service.shouldShowOnboarding(effectiveId)) return;
      if (await service.hasCelebrated(
          effectiveId, OnboardingMilestone.mapTutorial)) {
        return;
      }

      if (!mounted) return;
      if (ModalRoute.of(context)?.isCurrent != true) return;
      if (ref.read(selectedTabIndexProvider) != 1) return;

      Future<void> markDone() async {
        _activeTutorial = null;
        await service.markCelebrated(
            effectiveId, OnboardingMilestone.mapTutorial);
      }

      _activeTutorial = buildMapTutorial(
        context,
        searchBarKey: _searchBarKey,
        optimizeKey: _optimizeButtonKey,
        isPro: ref.read(isProProvider),
        onFinish: () {
          unawaited(markDone());
          AnalyticsService.instance.mapTutorialCompleted();
        },
        onSkip: (lastStep) {
          unawaited(markDone());
          AnalyticsService.instance.mapTutorialSkipped(lastStep);
          return true; // allow the dismissal
        },
      );
      // rootOverlay: the scrim must cover the bottom nav so the user can't
      // switch tabs out from under the tour.
      _activeTutorial!.show(context: context, rootOverlay: true);
    } finally {
      _tutorialCheckInFlight = false;
    }
  }

  Future<void> _initializeLocation() async {
    try {
      final currentLocation = await LocationService.getCurrentLocation();
      if (currentLocation != null) {
        ref.read(tripProvider.notifier).updateCurrentLocation(currentLocation);
        // Resolve its country up front so the first "zoom to fit" already
        // knows whether we're in the trip's country.
        _resolveCurrentLocationCountry(currentLocation);

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
      debugPrint("Failed to get location: $e");
      if (mounted) {
        AppToast.warning(
          context,
          'Location permissions denied. Showing default map area.',
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
        // OPTIMIZATION: Only update if app is in foreground to prevent background processing
        if (mounted && _lastLifecycleState == AppLifecycleState.resumed) {
          ref.read(tripProvider.notifier).updateCurrentLocation(location);
        }
        // Location tracking without automatic camera animation
        // Camera only moves when user explicitly requests it
      },
      onError: (error) {
        // Handle location stream errors gracefully
        debugPrint('Location stream error: $error');
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
    // Now that the controller is ready, animate to current location.
    // _initializeLocation() was already called from initState() but _mapController
    // was null then so animateCamera was skipped. _startLocationTracking() has its
    // own guard so calling this again is safe.
    _initializeLocation();
  }

  Future<void> _onMapLongPress(LatLng coordinates) async {
    // Check if user has write access to the active trip
    final hasWriteAccess = await ref.read(hasActiveTripWriteAccessProvider.future);
    if (!mounted) return;

    if (!hasWriteAccess) {
      AppToast.warning(
        context,
        'You don\'t have permission to add locations to this trip.',
      );
      return;
    }

    // Prevent adding locations to past dates
    final selectedDate = ref.read(selectedDateProvider);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    if (selectedDate.isBefore(today)) {
      AppToast.warning(context, 'Cannot add locations to a past date.');
      return;
    }
    try {
      final radius = ref.read(nearbyRadiusProvider).round();

      AppToast.info(
        context,
        'Looking up places within ${_formatRadius(radius)}...',
        duration: const Duration(seconds: 3),
      );

      final nearby = await PlacesService.searchNearbyPlaces(
        coordinates,
        radiusMeters: radius,
      );
      if (!mounted) return;
      AppToast.dismiss();

      final picked = await showNearbyPlacesPicker(
        context,
        places: nearby,
        radiusMeters: radius,
      );
      if (picked.isEmpty || !mounted) return;

      await _addNearbyPlaces(picked);
    } catch (e) {
      debugPrint('Error adding location from map: $e');
      if (mounted) {
        AppToast.error(context, 'Failed to add location. Please try again.');
      }
    }
  }

  /// Adds each picked nearby place to the trip. Each pick is first enriched
  /// via [PlacesService.getPlaceDetails] so it carries the full photo list
  /// and the parsed country code — Nearby Search alone returns only the
  /// cover photo and no `address_components`, which is why a manual-search
  /// add ends up with more photos than a long-press add did before.
  ///
  /// The strict country guard inside [LocationAddService.addLocation]
  /// runs once per pick. Picks within the same radius are essentially
  /// always in the same country as each other, so in practice the first
  /// mismatch dialog (if any) covers the whole batch.
  Future<void> _addNearbyPlaces(List<NearbyPlace> picked) async {
    final enriched = await Future.wait(
      picked.map((p) => PlacesService.getPlaceDetails(p.placeId)),
    );
    if (!mounted) return;

    final scheduledDate = ref.read(selectedDateProvider);
    final addedLocations = <LocationModel>[];
    for (var i = 0; i < picked.length; i++) {
      final fallback = picked[i];
      final details = enriched[i];
      final resolvedName =
          details?.name.isNotEmpty == true ? details!.name : fallback.name;
      final location = LocationModel(
        id: const Uuid().v4(),
        name: resolvedName,
        address: details?.address.isNotEmpty == true
            ? details!.address
            : fallback.vicinity,
        coordinates: details?.coordinates ?? fallback.coordinates,
        addedAt: DateTime.now(),
        scheduledDate: scheduledDate,
        photoReference:
            details?.photoReference ?? fallback.photoReference,
        photoReferences: details?.photoReferences.isNotEmpty == true
            ? details!.photoReferences
            : fallback.photoReferences,
        photoAttributions:
            details?.photoAttributions ?? fallback.photoAttributions,
        placeId: details?.placeId ?? fallback.placeId,
        originalName: resolvedName,
        googleOpeningHours: details?.openingHours,
        hoursLastRefreshedAt:
            details?.openingHours != null ? DateTime.now() : null,
      );
      final added = await LocationAddService(ref).beforeAddingLocation(
        context,
        location,
        locationCountryCode: details?.countryCode,
      );
      if (!mounted) return;
      if (added) addedLocations.add(location);
    }

    if (!mounted || addedLocations.isEmpty) return;

    final count = addedLocations.length;
    AppToast.success(
      context,
      count == 1
          ? 'Added ${addedLocations.first.name} to your trip'
          : 'Added $count locations to your trip',
    );

    setState(() {
      _highlightedLocationIndex = null;
    });
    ref.read(mapUIStateProvider.notifier).clearHighlights();
  }

  String _formatRadius(int meters) {
    if (meters < 1000) return '${meters}m';
    return '${(meters / 1000).toStringAsFixed(meters % 1000 == 0 ? 0 : 1)}km';
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
    // Note: Collaborator realtime listener is now initialized at app root (main.dart)
    // No need to initialize it here anymore

    // OPTIMIZATION: Move listeners to separate effect to prevent rebuilding entire widget tree
    // Use a dedicated build widget for listener side effects
    return _buildMapScreenContent(context);
  }

  Widget _buildMapScreenContent(BuildContext context) {
    // Listen to polyline taps to animate the camera to fit the route segment.
    ref.listen<String?>(tappedPolylineIdProvider, (previous, next) {
      if (next != null) {
        final legIndex = int.tryParse(next.replaceFirst('leg_', '')) ?? -1;
        if (legIndex != -1) {
          _zoomToFitLeg(legIndex);
        }
      }
    });

    // PERFORMANCE: Only listen to optimizedRoute changes, not entire TripState
    ref.listen<List<LatLng>>(
      tripProvider.select((s) => s.optimizedRoute),
      (previous, next) {
        final selectedDate = ref.read(selectedDateProvider);
        final now = DateTime.now();
        final today = DateTime(now.year, now.month, now.day);
        final isPastDate = selectedDate.isBefore(today);

        // If we are on a past date and a route has just been loaded...
        if (isPastDate &&
            next.isNotEmpty &&
            (previous?.isEmpty ?? true)) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _zoomToFitRoute(next);
          });
        }
      },
    );

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

    // The "aha" moment: a delight event (optimization / day completion) passed
    // every eligibility gate. Let the user see the optimized route settle for a
    // beat, then run the sentiment-gated review flow. All caps/cooldown live in
    // ReviewPromptService; this only ever fires when it's appropriate to ask.
    ref.listen<int>(reviewPromptTriggerProvider, (previous, next) {
      if (next <= (previous ?? 0)) return;
      Future.delayed(const Duration(milliseconds: 1400), () {
        if (mounted) showReviewSentimentFlow(context);
      });
    });

    // One-time FIRST-optimize celebration. Delayed so the zoom-to-fit
    // settles first (mirrors the review flow's beat). Defers to the
    // timing-warnings sheet when one is due — the flag stays unset in that
    // case, so the next successful optimize celebrates instead. This
    // listener owns the per-user celebrated flag: re-check → mark → show.
    // One-time map spotlight tour re-evaluation points: the tab becoming
    // visible, and MainScreen's "onboarding resolved" bump (the anonymous
    // flow is already ON the map tab when onboarding pops, so no tab event
    // fires for them).
    ref.listen<int>(selectedTabIndexProvider, (prev, next) {
      if (next == 1 && prev != 1) _maybeStartMapTutorial();
    });
    ref.listen<int>(mapTutorialRecheckProvider, (prev, next) {
      if (next != (prev ?? 0)) _maybeStartMapTutorial();
    });

    ref.listen<int>(firstOptimizeCelebrationTrigger, (previous, next) {
      if (next <= (previous ?? 0)) return;
      Future.delayed(const Duration(milliseconds: 1200), () async {
        if (!mounted) return;
        // Anonymous users celebrate too — flags keyed to the persistent
        // device UUID. Their dialog carries a signup nudge: local places
        // merge into the account on login (syncOnLogin), so "keep your
        // places" is a true promise and this is the conversion moment.
        final authUserId = ref.read(currentUserIdProvider);
        final isAnonymous = authUserId == null;
        final userId = authUserId ?? await AnonymousUserService.id;
        if (!mounted) return;
        final service = OnboardingService.instance;
        if (await service.hasCelebrated(
            userId, OnboardingMilestone.firstOptimize)) {
          return;
        }
        // Same condition as the TimingWarningsSheet listener in
        // trip_bottom_sheet — if the warnings sheet is up/imminent, don't
        // stack the celebration on top of it.
        final sim = ref.read(tripSimulationProvider);
        if (sim != null && !sim.fullyFeasible) {
          final acked = ref.read(acknowledgedTimingWarningsProvider);
          final hasUnacked = sim.stops.any(
              (s) => s.warnings.isNotEmpty && !acked.contains(s.locationId));
          if (hasUnacked) return;
        }
        if (!mounted) return;
        final tripState = ref.read(tripProvider);
        await service.markCelebrated(
            userId, OnboardingMilestone.firstOptimize);
        if (!mounted || !context.mounted) return;
        await showFirstOptimizeCelebration(
          context,
          stops: tripState.optimizedLocationsForSelectedDate.length,
          totalTime: tripState.totalTravelTime,
          onSignUp: isAnonymous
              ? () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const LoginScreen()),
                  )
              : null,
          // Authenticated users get the referral CTA instead — the aha
          // moment is the single highest-converting referral surface.
          onInvite: isAnonymous
              ? null
              : () => inviteFriends(context, ref, source: 'celebration'),
        );
      });
    });

    // Auto-frame the map when the user changes the selected date: zoom to
    // fit the day's stops, or fall back to the device location when the
    // day is empty. Date changes are synchronous, so a post-frame callback
    // is enough — pinnedLocations is already correct.
    ref.listen<DateTime>(selectedDateProvider, (previous, next) {
      if (previous == null || previous == next) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _updateCameraForCurrentDate();
      });
    });

    // Trip activation / switch / deactivation. The locations list refreshes
    // asynchronously via _initSyncListener, so we mark a pending camera
    // move here and execute it once pinnedLocations next emits below —
    // that way we always frame the *new* trip's locations, never the old
    // ones.
    ref.listen<String?>(localActiveTripIdProvider, (previous, next) {
      if (previous == next) return;
      _pendingTripCameraMove = true;
    });

    ref.listen<List<LocationModel>>(
      tripProvider.select((s) => s.pinnedLocations),
      (previous, next) {
        // Trip activation / switch / deactivation: gated by the flag
        // set in the localActiveTripIdProvider listener above.
        if (_pendingTripCameraMove) {
          _pendingTripCameraMove = false;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _updateCameraForCurrentDate();
          });
          return;
        }

        // Reframe whenever the set of locations active on the selected
        // date changes — covers:
        //   • Adding a location via the search-bar / long-press flow.
        //   • Deleting a location.
        //   • Collaborator-driven adds/deletes arriving through the
        //     sync listener (locations show up after a remote fetch).
        // Comparing ID sets (not lengths) catches the same-count
        // "deleted A, added B in the same tick" case too. Edits that
        // don't change membership (rename, stayDuration, etc.) leave
        // the set unchanged and don't trigger reframes.
        final selectedDate = ref.read(selectedDateProvider);
        final prevIds = (previous ?? const <LocationModel>[])
            .where((l) => l.isActiveOnDate(selectedDate))
            .map((l) => l.id)
            .toSet();
        final nextIds = next
            .where((l) => l.isActiveOnDate(selectedDate))
            .map((l) => l.id)
            .toSet();
        final membershipChanged = prevIds.length != nextIds.length ||
            !prevIds.containsAll(nextIds);
        if (membershipChanged) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _updateCameraForCurrentDate();
          });
        }
      },
    );

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
      // Don't reflow the body when the soft keyboard appears — the search
      // results render inside the search-bar overlay and the bottom sheet
      // already handles scroll. Resizing on every keyboard frame caused
      // the visible "page pulls down" jank when the input was focused.
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          // Map — wrapped in a MediaQuery that zeroes viewInsets and
          // viewPadding for THIS subtree only. The google_maps_flutter
          // platform view (GMSMapView/MKMapView on iOS) reads inherited
          // MediaQuery values and shifts its native frame downward when
          // the keyboard opens, which exposes the scaffold background
          // strip at the top of the screen on focus. Other widgets in
          // the Stack (search bar, banners, FAB, bottom sheet) keep the
          // original MediaQuery — the wrap is scoped to just the map so
          // it can't break their own keyboard handling.
          MediaQuery(
            data: MediaQuery.of(context).copyWith(
              viewInsets: EdgeInsets.zero,
              viewPadding: MediaQuery.of(context).padding,
            ),
            child: MapWidget(
              onMapCreated: _onMapCreated,
              onMapLongPress: _onMapLongPress,
              onMarkerTap: _onMarkerTapped,
            ),
          ),

          // Trip Name Overlay - Beautiful header showing active trip
          Positioned(
            top: 50,
            left: 16,
            right: 16,
            child: Consumer(
              builder: (context, ref, child) {
                final activeTripAsync = ref.watch(realtimeActiveTripProvider);
                final currentUserId = ref.watch(currentUserIdProvider);

                return activeTripAsync.when(
                  data: (activeTrip) {
                    if (activeTrip == null) return child!;

                    // True when the signed-in user is NOT the trip owner —
                    // i.e. this is a collaborator viewing someone else's
                    // trip. Drives both the "owner" pill on the right of
                    // the badge and which profile we look up.
                    final isSharedTrip = currentUserId != null &&
                        activeTrip.userId != currentUserId;

                    return Column(
                      children: [
                        // Active Trip Name Banner
                        ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: BackdropFilter(
                            filter: ImageFilter.blur(sigmaX: 15.0, sigmaY: 15.0),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [
                                    Theme.of(context).colorScheme.primary.withValues(alpha: 0.95),
                                    Theme.of(context).colorScheme.primary.withValues(alpha: 0.85),
                                  ],
                                ),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.3),
                                  width: 1.5,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
                                    blurRadius: 20,
                                    offset: const Offset(0, 8),
                                  ),
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.15),
                                    blurRadius: 10,
                                    offset: const Offset(0, 4),
                                  ),
                                ],
                              ),
                              child: Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(8),
                                    decoration: BoxDecoration(
                                      color: Colors.white.withValues(alpha: 0.2),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: const Icon(
                                      Icons.navigation_rounded,
                                      color: Colors.white,
                                      size: 22,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Active Trip',
                                          style: TextStyle(
                                            color: Colors.white.withValues(alpha: 0.9),
                                            fontSize: 11,
                                            fontWeight: FontWeight.w500,
                                            letterSpacing: 0.5,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          activeTrip.name,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 17,
                                            fontWeight: FontWeight.bold,
                                            letterSpacing: 0.3,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        // Date-range + inclusive day count.
                                        // Rendered as a small subtitle so
                                        // the badge stays compact; only
                                        // shows when the trip actually has
                                        // both endpoints set.
                                        if (activeTrip.startDate != null &&
                                            activeTrip.endDate != null)
                                          Builder(builder: (context) {
                                            final s = DateTime(
                                                activeTrip.startDate!.year,
                                                activeTrip.startDate!.month,
                                                activeTrip.startDate!.day);
                                            final e = DateTime(
                                                activeTrip.endDate!.year,
                                                activeTrip.endDate!.month,
                                                activeTrip.endDate!.day);
                                            final dayCount =
                                                e.difference(s).inDays + 1;
                                            final dateText = activeTrip
                                                        .startDate ==
                                                    activeTrip.endDate
                                                ? DateFormat('MMM d, y')
                                                    .format(activeTrip
                                                        .startDate!)
                                                : '${DateFormat('MMM d').format(activeTrip.startDate!)} - ${DateFormat('MMM d').format(activeTrip.endDate!)}';
                                            return Padding(
                                              padding: const EdgeInsets.only(
                                                  top: 2),
                                              child: Text(
                                                '$dateText  ·  $dayCount day${dayCount == 1 ? '' : 's'}',
                                                style: TextStyle(
                                                  color: Colors.white
                                                      .withValues(alpha: 0.85),
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.w500,
                                                  letterSpacing: 0.2,
                                                ),
                                                maxLines: 1,
                                                overflow:
                                                    TextOverflow.ellipsis,
                                              ),
                                            );
                                          }),
                                      ],
                                    ),
                                  ),
                                  if (isSharedTrip) ...[
                                    const SizedBox(width: 10),
                                    _OwnerPill(ownerUserId: activeTrip.userId),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        child!,
                      ],
                    );
                  },
                  loading: () => child!,
                  error: (_, __) => child!,
                );
              },
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  // Fake search bar — pushes [LocationSearchScreen]
                  // instead of focusing an inline TextField. This
                  // sidesteps every keyboard-driven layout shift that
                  // an inline TextField caused on this screen (the map
                  // getting "pulled down" on focus). The chrome
                  // (rounded, translucent, blurred, with a search icon
                  // and hint text) is preserved so it still reads as a
                  // search bar at a glance.
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(30),
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 10.0, sigmaY: 10.0),
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(30),
                            onTap: () {
                              // Zero-duration page transition: the new
                              // screen appears instantly instead of
                              // sliding in. The standard slide-in left
                              // a window (~300ms on iOS) during which
                              // the map screen was still visible — any
                              // MediaQuery / keyboard event from the
                              // mounting screen propagated back to the
                              // map and visibly shifted it before the
                              // transition finished. With Duration.zero,
                              // the new screen fully covers the map
                              // before the next frame paints.
                              Navigator.of(context).push(
                                PageRouteBuilder(
                                  pageBuilder: (context, _, __) =>
                                      const LocationSearchScreen(),
                                  transitionDuration: Duration.zero,
                                  reverseTransitionDuration:
                                      Duration.zero,
                                  opaque: true,
                                ),
                              );
                            },
                            child: Container(
                              key: _searchBarKey, // spotlight-tour anchor
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 14),
                              decoration: BoxDecoration(
                                color: Theme.of(context)
                                    .colorScheme
                                    .surface
                                    .withValues(alpha: 0.92),
                                borderRadius: BorderRadius.circular(30),
                                border: Border.all(
                                  color: Theme.of(context)
                                      .dividerColor
                                      .withValues(alpha: 0.2),
                                  width: 1.5,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: 0.15),
                                    blurRadius: 20,
                                    offset: const Offset(0, 5),
                                  ),
                                ],
                              ),
                              child: Row(
                                children: [
                                  const Icon(
                                    Icons.search,
                                    color: AppTheme.primaryColor,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      'Search for places...',
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleMedium
                                          ?.copyWith(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .onSurfaceVariant,
                                          ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                    ],
                  ),
                  // Goal-gradient progress: free users see how much of the
                  // 5-place allowance is used, live. Hidden for Pro.
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: FreePlacesProgressChip(),
                  ),
                ],
              ),
            ),
          ),

          // Floating Action Buttons for Map Controls — flips to a
          // horizontal row when the search bar is focused so it doesn't
          // crowd the search results column. Direction is driven by the
          // focus ValueNotifier (so only this subtree rebuilds), and the
          // bounding-box change is smoothed with AnimatedSize.
          //
          // Positioned is INSIDE the ValueListenableBuilder so both the
          // bottom offset and the FAB axis can react to focus together:
          //   • Vertical (default): 16px gap above the collapsed sheet.
          //   • Horizontal (focused): the row drops well below the sheet
          //     top so it visibly hugs the sheet rather than floating
          //     high above it.
          //
          // Position is anchored against `View.physicalSize` — the OS-
          // reported screen size in logical pixels — instead of
          // `MediaQuery.size.height` so the FAB doesn't shift with
          // keyboard events. The search bar pushes a separate screen
          // now, so there is no inline keyboard event on this screen
          // to begin with — but anchoring against physicalSize keeps
          // the position correct even if something else (Android
          // adjustResize, system UI change) ever does shrink the
          // logical screen height.
          Builder(builder: (context) {
            final view = View.of(context);
            final screenH =
                view.physicalSize.height / view.devicePixelRatio;
            return Positioned(
              bottom: screenH * 0.23 + 16,
              right: 16,
              child: AnimatedSize(
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeInOut,
                  alignment: Alignment.bottomRight,
                  child: Consumer(
                    builder: (context, ref, _) {
                      final locationsForDate =
                          ref.watch(locationsForSelectedDateProvider);
                      final hasRoute = ref.watch(tripProvider
                          .select((s) => s.optimizedRoute.isNotEmpty));
                      final isGenerating =
                          ref.watch(isGeneratingRouteProvider);
                      final currentUserId =
                          ref.watch(currentUserIdProvider);
                      final allSaved =
                          ref.watch(savedLocationsProvider).asData?.value ??
                              const [];
                      final unassigned = allSaved
                          .where((l) =>
                              l.tripId == null && l.userId == currentUserId)
                          .toList();
                      final showPlaceNames = ref.watch(showPlaceNamesProvider);

                      final fabs = <Widget>[
                        FloatingActionButton(
                          heroTag: 'currentLocationFab',
                          mini: true,
                          onPressed: _goToCurrentLocation,
                          child: const Icon(Icons.my_location),
                        ),
                        if (locationsForDate.isNotEmpty)
                          FloatingActionButton(
                            heroTag: 'zoomToFitFab',
                            mini: true,
                            onPressed: _zoomToFitTrip,
                            child: const Icon(Icons.zoom_out_map),
                          ),
                        if (hasRoute && !isGenerating)
                          FloatingActionButton(
                            heroTag: 'clearRouteFab',
                            mini: true,
                            backgroundColor:
                                Theme.of(context).colorScheme.errorContainer,
                            foregroundColor: Theme.of(context)
                                .colorScheme
                                .onErrorContainer,
                            onPressed: () => ref
                                .read(tripProvider.notifier)
                                .clearOptimizedRoute(),
                            tooltip: 'Clear Route',
                            child: const Icon(Icons.clear_outlined),
                          ),
                        if (unassigned.isNotEmpty)
                          FloatingActionButton(
                            heroTag: 'addToTripFab',
                            mini: true,
                            onPressed: () {
                              showModalBottomSheet(
                                context: context,
                                isScrollControlled: true,
                                backgroundColor: Colors.transparent,
                                builder: (context) => AddToTripSheet(
                                  availableLocations: unassigned,
                                  onSuccess: () {},
                                ),
                              );
                            },
                            tooltip: 'Add Locations to Trip',
                            child: const Icon(Icons.playlist_add),
                          ),
                        FloatingActionButton(
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
                        ),
                      ];

                      // Always vertical now — the inline search bar
                      // (which previously flipped this to horizontal on
                      // focus) is gone, replaced by a button that pushes
                      // a separate screen.
                      const gap = SizedBox(height: 12);
                      final children = <Widget>[];
                      for (var i = 0; i < fabs.length; i++) {
                        if (i > 0) children.add(gap);
                        children.add(fabs[i]);
                      }

                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: children,
                      );
                    },
                  ),
                ),
              );
            },
          ),

          // Trip bottom sheet. (The Listener that previously wrapped
          // this sheet to dismiss the inline search keyboard is gone —
          // search now lives on its own pushed screen, so there's no
          // FocusNode on this screen to unfocus.)
          TripBottomSheet(
            sheetController: _sheetController,
            onLocationTap: _zoomToLocation,
            optimizeKey: _optimizeButtonKey, // spotlight-tour anchor
            // onGoToCurrentLocation is now handled by the FAB
            onShowZoneSettings: _showProximitySliderBottomSheet,
            // onZoomToFitTrip is now handled by the FAB
            highlightedLocationIndex: _highlightedLocationIndex,
          ),

          // Loading overlay — covers the map during the initial data sync so
          // the user never sees the blink that occurs while marker bitmaps are
          // being generated for the first time.  The overlay fades out once:
          //   1. performInitialLocationSync() has completed (remote data written
          //      to Hive), AND
          //   2. cachedMarkerBitmapsProvider has finished its async bitmap
          //      generation (the expensive part that would cause the blink).
          Consumer(
            builder: (context, ref, _) {
              final syncDone = ref.watch(initialSyncCompleteProvider);
              final markersAsync = ref.watch(cachedMarkerBitmapsProvider);
              // Ready when sync is done AND the first set of bitmaps is computed.
              // Keeping both conditions prevents the overlay from dismissing
              // prematurely while bitmap generation is still in flight.
              final isReady = syncDone && markersAsync.hasValue;
              return AnimatedOpacity(
                opacity: isReady ? 0.0 : 1.0,
                duration: const Duration(milliseconds: 500),
                child: IgnorePointer(
                  ignoring: isReady,
                  child: _buildLoadingOverlay(context),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildLoadingOverlay(BuildContext context) {
    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Icon(
                  Icons.map_outlined,
                  size: 40,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                'Loading your locations...',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _goToCurrentLocation() async {
    // Try to get current location from state first
    LatLng? currentLocation = ref.read(tripProvider).currentLocation;

    // If location isn't available in the state, try to fetch it again.
    if (currentLocation == null) {
      try {
        // Check if location services are enabled first
        final serviceEnabled = await LocationService.isLocationServiceEnabled();
        if (!serviceEnabled) {
          if (!mounted) return;
          final shouldOpenSettings = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Location Services Disabled'),
              content: const Text(
                'Location services are turned off on your device. Please enable them in Settings to use this feature.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('Open Settings'),
                ),
              ],
            ),
          );

          if (shouldOpenSettings == true) {
            // On iOS, this opens Location Services settings
            await LocationService.openLocationSettings();
          }
          return;
        }

        currentLocation = await LocationService.getCurrentLocation();
        if (currentLocation != null) {
          ref
              .read(tripProvider.notifier)
              .updateCurrentLocation(currentLocation);
        } else {
          // Location service returned null (likely permission denied)
          if (!mounted) return;
          AppToast.warning(
            context,
            'Location permission denied. Please enable it to use this feature.',
          );
          return;
        }
      } catch (e) {
        debugPrint("Failed to get current location on demand: $e");
        if (!mounted) return;
        AppToast.error(context, 'Failed to get your location. Please try again.');
        return;
      }
    }

    if (_mapController != null && mounted) {
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
      AppToast.warning(
        context,
        'Current location is not available. Please enable location services.',
      );
    }
  }

  /// Automatic camera reframe called when the selected date changes or the
  /// active trip is swapped/deactivated. Picks the natural framing for the
  /// new context:
  ///   • Day has stops → [_zoomToFitTrip] (also honors the
  ///     "include current location in fit" setting).
  ///   • Day is empty → recenter on the device's known [currentLocation].
  ///
  /// Stays silent if the map isn't ready or the device location is unknown:
  /// this is a background camera move, so it must never pop a permission
  /// dialog or snackbar the way the manual "My location" FAB does.
  void _updateCameraForCurrentDate() {
    if (_mapController == null) return;
    final locations = ref.read(locationsForSelectedDateProvider);
    if (locations.isNotEmpty) {
      _zoomToFitTrip();
      return;
    }
    final current = ref.read(tripProvider).currentLocation;
    if (current == null) return;
    _mapController!.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(target: current, zoom: 16.0),
      ),
    );
  }

  /// Resolves and caches the country of the device's [location] so
  /// [_zoomToFitTrip] can compare it against the active trip's country without
  /// an async hop. Re-geocodes only after ~5km of movement (country
  /// granularity), so it costs at most one network call per meaningful move.
  Future<void> _resolveCurrentLocationCountry(LatLng location) async {
    final last = _currentLocationCountryFor;
    if (last != null &&
        _currentLocationCountry != null &&
        _metersBetween(last, location) < 5000) {
      return; // still near the last resolve — reuse the cached country
    }
    final country = await LocationService.getCountryCodeForLocation(location);
    if (!mounted || country == null) return;
    _currentLocationCountry = country;
    _currentLocationCountryFor = location;
  }

  double _metersBetween(LatLng a, LatLng b) {
    const earthRadius = 6371000.0; // meters
    final dLat = (b.latitude - a.latitude) * math.pi / 180.0;
    final dLng = (b.longitude - a.longitude) * math.pi / 180.0;
    final lat1 = a.latitude * math.pi / 180.0;
    final lat2 = b.latitude * math.pi / 180.0;
    final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1) *
            math.cos(lat2) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    return 2 * earthRadius * math.asin(math.min(1.0, math.sqrt(h)));
  }

  void _zoomToFitTrip() {
    if (_mapController == null) return;

    final locations = ref.read(locationsForSelectedDateProvider);
    final includeCurrent = ref.read(includeCurrentInFitProvider);
    final currentLocation = ref.read(tripProvider).currentLocation;

    // Keep the current-location country fresh (cheap after the first resolve)
    // so the cross-country check has an answer on the next fit even if the
    // device has since moved.
    if (currentLocation != null) {
      _resolveCurrentLocationCountry(currentLocation);
    }

    // If the device is in a different country than the active trip, never fold
    // the current location into the bounds — a trip in Japan shouldn't zoom out
    // to a phone in Cambodia. This OVERRIDES the "include current location"
    // preference, which only makes sense within a single country.
    final tripCountry =
        ref.read(realtimeActiveTripProvider).asData?.value?.countryCode;
    final currentCountry = _currentLocationCountry;
    final crossCountry = tripCountry != null &&
        currentCountry != null &&
        tripCountry.toUpperCase() != currentCountry.toUpperCase();

    if (crossCountry) {
      // Announce it once — but only when the preference would otherwise have
      // included the location and there are stops to frame. Deduped by the
      // country pair so background / repeated fits don't spam the toast.
      if (includeCurrent && currentLocation != null && locations.isNotEmpty) {
        final key = '$tripCountry>$currentCountry';
        if (_crossCountryFitNoticeKey != key) {
          _crossCountryFitNoticeKey = key;
          final countryName = findCountryByCode(tripCountry)?.name;
          final where = countryName ?? "the trip's country";
          AppToast.info(
            context,
            "You're not in $where right now, so your current location "
            "isn't included in the map view.",
          );
        }
      }
    } else {
      // Countries match (or one is unknown) — let a later mismatch re-notify.
      _crossCountryFitNoticeKey = null;
    }

    final currentForFit =
        (includeCurrent && !crossCountry) ? currentLocation : null;

    // Build the points list before the small-list short-circuit so the
    // current-location preference also takes effect when there's only 0–1
    // stops on the date.
    final points = <LatLng>[
      ...locations.map((loc) => loc.coordinates),
      if (currentForFit != null) currentForFit,
    ];

    if (points.length < 2) {
      if (points.isNotEmpty) {
        _zoomToLocation(points.first);
      }
      return;
    }

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

    // OPTIMIZATION: Calculate padding for each edge to fit all UI elements
    final screenHeight = MediaQuery.of(context).size.height;

    // Check if active trip banner is shown
    final activeTripAsync = ref.read(realtimeActiveTripProvider);
    final hasActiveTrip = activeTripAsync.asData?.value != null;

    // Calculate top safe area padding
    final topSafePadding = MediaQuery.of(context).padding.top;

    // UI elements heights and widths:
    // Top UI elements:
    // - Status bar: included in topSafePadding
    // - Top margin: 50px (from map_screen.dart line 621)
    // - Active Trip Banner (if shown): ~72px
    // - Spacing after banner: ~12px
    // - Search bar container: ~60px
    const topMargin = 50.0;
    final activeTripBannerHeight = hasActiveTrip ? 72.0 : 0.0;
    final spacingAfterBanner = hasActiveTrip ? 12.0 : 0.0;
    const searchBarHeight = 60.0;

    final topUIHeight = topSafePadding +
                       topMargin +
                       activeTripBannerHeight +
                       spacingAfterBanner +
                       searchBarHeight;

    // Bottom UI: Bottom sheet in collapsed state takes 23% of screen height
    final bottomSheetCollapsedHeight = screenHeight * 0.23;

    // Right UI: FAB buttons column
    // - 4 mini FABs (40px each) = 160px
    // - 3 spacings between them (12px each) = 36px
    // - Right margin: 16px
    // Total width from right edge: 40px (FAB) + 16px (margin) = 56px
    // Add extra buffer for marker visibility
    const fabWidth = 40.0;
    const fabRightMargin = 16.0;
    const rightUIWidth = fabWidth + fabRightMargin;

    // Left UI: minimal margin
    const leftMargin = 16.0;

    // Add buffer padding for visual comfort
    const bufferPadding = 20.0;
    const rightBufferPadding = 40.0; // Extra buffer for right side due to FABs

    // Calculate edge-specific padding
    final topPadding = topUIHeight + bufferPadding;
    final bottomPadding = bottomSheetCollapsedHeight + bufferPadding;
    const rightPadding = rightUIWidth + rightBufferPadding; // Use larger buffer for right
    const leftPadding = leftMargin + bufferPadding;

    // Create expanded bounds that account for asymmetric padding
    // We need to expand the bounds to ensure all markers fit within the visible area
    // after accounting for UI elements

    final latSpan = maxLat - minLat;
    final lngSpan = maxLng - minLng;

    // Calculate the visible area dimensions
    final visibleHeight = screenHeight - topPadding - bottomPadding;

    // Calculate how much to expand the bounds on each side
    // This ensures the actual locations fit within the visible area
    final verticalExpansionTop = (topPadding / visibleHeight) * latSpan;
    final verticalExpansionBottom = (bottomPadding / visibleHeight) * latSpan;
    final horizontalExpansionLeft = (leftPadding / screenHeight) * lngSpan; // Use screenHeight as approximation for aspect ratio
    final horizontalExpansionRight = (rightPadding / screenHeight) * lngSpan;

    // Create expanded bounds
    final expandedBounds = LatLngBounds(
      southwest: LatLng(
        minLat - verticalExpansionBottom,
        minLng - horizontalExpansionLeft,
      ),
      northeast: LatLng(
        maxLat + verticalExpansionTop,
        maxLng + horizontalExpansionRight,
      ),
    );

    // Animate to the expanded bounds with minimal padding
    // This ensures all original markers are visible within the UI-free area
    _mapController!.animateCamera(
      CameraUpdate.newLatLngBounds(expandedBounds, 20.0), // Small uniform padding for safety
    );
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

/// Compact pill rendered on the right edge of the active-trip badge when
/// the signed-in user is viewing a trip OWNED by someone else. Shows the
/// owner's avatar (initials fallback) and short name so a collaborator can
/// tell at a glance whose trip they're planning in.
///
/// Profile is loaded via [userProfileByIdProvider], which caches per-userId
/// — switching back to the same shared trip won't re-fetch.
class _OwnerPill extends ConsumerWidget {
  final String ownerUserId;

  const _OwnerPill({required this.ownerUserId});

  String _shortLabel(UserProfile? profile) {
    if (profile == null) return 'Owner';
    final first = (profile.firstName ?? '').trim();
    if (first.isNotEmpty) return first;
    final last = (profile.lastName ?? '').trim();
    if (last.isNotEmpty) return last;
    // Fall back to the part of the email before the @ so we always show
    // *something* useful while the user's profile is still bare.
    final email = profile.email;
    final at = email.indexOf('@');
    return at > 0 ? email.substring(0, at) : email;
  }

  String _initials(UserProfile? profile) {
    if (profile == null) return '?';
    final f = (profile.firstName ?? '').trim();
    final l = (profile.lastName ?? '').trim();
    if (f.isNotEmpty && l.isNotEmpty) {
      return '${f[0]}${l[0]}'.toUpperCase();
    }
    if (f.isNotEmpty) return f[0].toUpperCase();
    if (l.isNotEmpty) return l[0].toUpperCase();
    final email = profile.email;
    return email.isNotEmpty ? email[0].toUpperCase() : '?';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ownerAsync = ref.watch(userProfileByIdProvider(ownerUserId));
    final profile = ownerAsync.asData?.value;

    final initials = _initials(profile);
    final name = profile == null ? '…' : _shortLabel(profile);
    // While the lookup is in flight OR if it returned null (RPC missing,
    // RLS denied), show a person glyph instead of bogus initials so the
    // pill never looks like a broken state.
    final hasProfile = profile != null;

    return ConstrainedBox(
      // Cap the pill width so a long owner name can't push the trip title
      // into ellipsis territory on narrow phones.
      constraints: const BoxConstraints(maxWidth: 96),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.22),
              shape: BoxShape.circle,
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.6),
                width: 1.2,
              ),
            ),
            alignment: Alignment.center,
            child: hasProfile
                ? Text(
                    initials,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.2,
                    ),
                  )
                : const Icon(
                    Icons.person_rounded,
                    size: 16,
                    color: Colors.white,
                  ),
          ),
          const SizedBox(height: 3),
          Text(
            name,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.95),
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
