import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:voyza/providers/map_ui_state_provider.dart';
import '../providers/trip_listener_provider.dart';
import '../providers/trip_provider.dart';
import '../providers/trip_simulation_provider.dart';
import '../utils/geo_utils.dart';
import '../services/leg_mode_prefs.dart';
import '../services/places_service.dart';

/// The day planner: where today's route starts (and ends), then
/// Optimize. Hosted by the Plan sheet's "This day" segment. Lays out:
///   - A prominent "Start at" card sourced from [effectiveTripStartTimeProvider].
///   - "My Location" (when device location is known).
///   - "Active stops" — the day's stops eligible for optimization.
///   - "Skipped & done" — usable as a route anchor but excluded from the
///     optimizer. Lets users start the next leg from a place they already
///     visited (or one they decided to skip) without re-adding it to the
///     plan.
class DayPlanPanel extends ConsumerStatefulWidget {
  const DayPlanPanel({
    super.key,
    required this.scrollController,
    required this.isReoptimizing,
  });

  /// The host sheet's controller, so the list drags the sheet.
  final ScrollController scrollController;
  final bool isReoptimizing;

  @override
  ConsumerState<DayPlanPanel> createState() => _DayPlanPanelState();
}

class _DayPlanPanelState extends ConsumerState<DayPlanPanel> {
  String? _selectedStartId;
  bool _initialized = false;

  /// Set once the user taps a start tile themselves. The async in-country
  /// promotion of the device GPS (see build) must never override an
  /// explicit pick.
  bool _userPickedStart = false;
  void _pickStart(String? v) => setState(() {
        _selectedStartId = v;
        _userPickedStart = true;
      });

  /// Optional "end the day at" stop (null = let the optimizer decide).
  String? _selectedFinalId;

  /// "Return to accommodation" — per-trip pref, default ON. Decides whether
  /// the day's route ends at the hotel (and whether a start-at-hotel day
  /// gets a ride home).
  bool _returnToAcc = true;

  // ── Travel style (multi-modal anchor) ─────────────────────────────────
  // 'auto' sniffs the trip's scale (compact ⇒ walking city); 'walk'/'drive'
  // force the anchor mode. Persisted per trip; the optimizer reads it on
  // every run. Loaded lazily the first time the sheet has the trip id.
  String _travelProfile = 'auto';
  bool _profileLoaded = false;

  /// "Max walk between stops" (routed meters) — a GLOBAL preference (the
  /// traveller's tolerance, not the trip's), fed into the routing ladder.
  double _maxWalkMeters = LegModePrefs.defaultMaxWalkMeters.toDouble();

  /// The start/end tiles fold away on a first optimize (the auto-picked
  /// start is right most of the time, and Optimize is one tap away) and
  /// open on a re-optimize, when changing them is the point.
  late bool _startEndOpen = widget.isReoptimizing;

  Future<void> _loadTravelProfile(String tripId) async {
    if (_profileLoaded) return;
    _profileLoaded = true;
    final profile = await LegModePrefs.travelProfile(tripId);
    final maxWalk = await LegModePrefs.maxWalkMeters();
    final returnToAcc = await LegModePrefs.returnToAccommodation(tripId);
    if (mounted) {
      setState(() {
        _travelProfile = profile;
        _maxWalkMeters = maxWalk.toDouble();
        _returnToAcc = returnToAcc;
      });
    }
  }

  String get _maxWalkLabel => _maxWalkMeters < 1000
      ? '${_maxWalkMeters.round()} m'
      : '${(_maxWalkMeters / 1000).toStringAsFixed(1)} km';

  Future<void> _setTravelProfile(String tripId, String profile) async {
    final changed = profile != _travelProfile;
    setState(() => _travelProfile = profile);
    await LegModePrefs.setTravelProfile(tripId, profile);
    // A style switch is "re-plan the trip THIS way" — manual per-leg
    // overrides from the previous style would silently win over the new
    // ladder on every leg they touched, which read as the picker doing
    // nothing. Fresh style, fresh slate.
    if (changed) await LegModePrefs.clearAllLegModes(tripId);
  }

  Widget _buildTravelStyleRow(BuildContext context, String tripId) {
    final theme = Theme.of(context);
    const options = [
      ('auto', Icons.auto_awesome_rounded, 'Auto'),
      ('walk', Icons.directions_walk_rounded, 'Walking city'),
      ('transit', Icons.directions_transit_rounded, 'Public transport'),
      ('drive', Icons.directions_car_rounded, 'Road trip'),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel(context, 'Travel style'),
        Wrap(
          spacing: 8,
          children: [
            for (final (value, icon, label) in options)
              ChoiceChip(
                selected: _travelProfile == value,
                showCheckmark: false,
                avatar: Icon(icon,
                    size: 16,
                    color: _travelProfile == value
                        ? theme.colorScheme.onPrimary
                        : theme.colorScheme.primary),
                label: Text(label),
                labelStyle: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: _travelProfile == value
                      ? theme.colorScheme.onPrimary
                      : theme.textTheme.bodyMedium?.color,
                ),
                selectedColor: theme.colorScheme.primary,
                backgroundColor: theme.cardColor.withValues(alpha: 0.6),
                side: BorderSide(
                  color: _travelProfile == value
                      ? theme.colorScheme.primary
                      : theme.dividerColor.withValues(alpha: 0.5),
                ),
                onSelected: (_) => _setTravelProfile(tripId, value),
              ),
          ],
        ),
        const SizedBox(height: 14),
        // ── Travel preferences ────────────────────────────────────────
        _sectionLabel(context, 'Max walk between stops'),
        Row(
          children: [
            Expanded(
              child: Slider(
                value: _maxWalkMeters.clamp(
                    LegModePrefs.minMaxWalkMeters.toDouble(),
                    LegModePrefs.maxMaxWalkMeters.toDouble()),
                min: LegModePrefs.minMaxWalkMeters.toDouble(),
                max: LegModePrefs.maxMaxWalkMeters.toDouble(),
                divisions: (LegModePrefs.maxMaxWalkMeters -
                        LegModePrefs.minMaxWalkMeters) ~/
                    100,
                label: _maxWalkLabel,
                onChanged: (v) => setState(() => _maxWalkMeters = v),
                onChangeEnd: (v) => LegModePrefs.setMaxWalkMeters(v.round()),
              ),
            ),
            SizedBox(
              width: 56,
              child: Text(
                _maxWalkLabel,
                textAlign: TextAlign.end,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(left: 4),
          child: Text(
            'Longer hops get a ride instead. Ignored when your travel '
            'style is Walking city.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }

  // Country-mismatch gate for the "My current location" anchor.
  //
  // Trip has a tagged country and the device is sitting in a different one
  // (e.g. user planning a Tokyo trip from home in NYC). Anchoring the
  // optimizer to the device GPS would silently route a leg across the
  // ocean. We disable the option in that case and tell the user to pick a
  // stop inside the trip's country.
  //
  // Resolution is a single reverse-geocode kicked off the first time the
  // sheet builds with the data it needs; cached in [_currentCountryCode]
  // afterward.
  bool _countryCheckStarted = false;
  bool _countryCheckInFlight = false;
  String? _currentCountryCode; // ISO-2 of the device GPS, once resolved.

  Future<void> _resolveCurrentCountry(LatLng coords) async {
    if (_countryCheckStarted) return;
    _countryCheckStarted = true;
    setState(() => _countryCheckInFlight = true);
    try {
      final details = await PlacesService.getPlaceFromCoordinates(coords);
      if (!mounted) return;
      setState(() {
        _currentCountryCode = details?.countryCode?.toUpperCase();
        _countryCheckInFlight = false;
      });
    } catch (_) {
      if (!mounted) return;
      // On failure, leave _currentCountryCode null so we don't block the
      // option — the strict country guard at add time still has the user's
      // back if the chosen anchor is actually wrong.
      setState(() => _countryCheckInFlight = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tripState = ref.watch(tripProvider);
    final selectedDate = ref.watch(selectedDateProvider);
    final activeTrip = ref.watch(realtimeActiveTripProvider).valueOrNull;
    final tripCountry = activeTrip?.countryCode?.toUpperCase();

    // Day's stops — including skipped/done, since those can serve as
    // anchors even though they won't be visited by the optimizer.
    final dayStops = tripState.pinnedLocations
        .where((loc) => loc.isActiveOnDate(selectedDate))
        .toList();
    // The day's accommodation gets its own section (and is the default
    // anchor — days naturally start from where you slept).
    final dayAccommodations = dayStops.where((l) => l.isAccommodation).toList();
    final activeStops = dayStops
        .where((l) => !l.isSkipped && !l.isDone && !l.isAccommodation)
        .toList();
    final inactiveStops = dayStops
        .where((l) => (l.isSkipped || l.isDone) && !l.isAccommodation)
        .toList();
    final hasCurrentLocation = tripState.currentLocation != null;

    // Kick off a one-shot reverse geocode the moment we know the trip has
    // a tagged country and the device has a fix. Cheap to call repeatedly
    // — _resolveCurrentCountry guards itself via [_countryCheckStarted].
    if (tripCountry != null && tripState.currentLocation != null) {
      _resolveCurrentCountry(tripState.currentLocation!);
    }

    // True only once we've confirmed the device is in a DIFFERENT country
    // than the trip. Null country code (lookup pending or failed) is not
    // a mismatch — we don't want a flaky geocode to lock out the option.
    final bool currentLocationMismatch;
    if (tripCountry != null) {
      currentLocationMismatch =
          _currentCountryCode != null && _currentCountryCode != tripCountry;
    } else {
      // No trip country (anonymous session / country-less trip): fall back to
      // proximity — if the device is far from every stop, anchoring the route
      // to its GPS would route a leg across the world (e.g. optimizing the
      // Lisbon sample from a phone in Cambodia).
      currentLocationMismatch = hasCurrentLocation &&
          dayStops.isNotEmpty &&
          minMetersToAny(tripState.currentLocation!,
                  dayStops.map((s) => s.coordinates)) >
              kForeignFallbackMeters;
    }
    final currentLocationDisabled =
        hasCurrentLocation && currentLocationMismatch;

    // Is the device CONFIRMED to be in the trip's country (or, for a
    // country-less trip, near the day's stops)? Only a positive answer
    // promotes the GPS to the default start — "unknown" (lookup pending or
    // failed) keeps the accommodation-first order below.
    final bool inTripRegion;
    if (tripCountry != null) {
      inTripRegion =
          _currentCountryCode != null && _currentCountryCode == tripCountry;
    } else {
      inTripRegion =
          hasCurrentLocation && dayStops.isNotEmpty && !currentLocationMismatch;
    }
    final preferCurrent =
        hasCurrentLocation && !currentLocationDisabled && inTripRegion;

    // Default selection. Priority: the device GPS when we KNOW the user is
    // in the trip's country (they're on the ground — the day starts from
    // where they stand); else the day's accommodation (routes naturally
    // start from where you slept); else the GPS unless it's known to be in
    // the wrong country; then stops. The country lookup is async, so the
    // GPS promotion is re-applied on later builds until the user picks a
    // tile themselves ([_userPickedStart]).
    String? fallbackStart() => dayAccommodations.isNotEmpty
        ? dayAccommodations.first.id
        : (hasCurrentLocation && !currentLocationDisabled)
            ? 'current_location'
            : (activeStops.isNotEmpty
                ? activeStops.first.id
                : (inactiveStops.isNotEmpty ? inactiveStops.first.id : null));
    if (!_initialized) {
      _initialized = true;
      _selectedStartId = preferCurrent ? 'current_location' : fallbackStart();
    } else if (!_userPickedStart &&
        preferCurrent &&
        _selectedStartId != 'current_location') {
      // The country lookup landed AFTER the first build and confirmed the
      // user is in the trip's country — promote the GPS now.
      _selectedStartId = 'current_location';
    } else if (currentLocationDisabled &&
        _selectedStartId == 'current_location') {
      // The country lookup landed AFTER the first build and invalidated
      // the device-GPS preselection — swap to the accommodation / first
      // usable stop so the Optimize button doesn't fire with a
      // now-disabled anchor.
      _selectedStartId = dayAccommodations.isNotEmpty
          ? dayAccommodations.first.id
          : activeStops.isNotEmpty
              ? activeStops.first.id
              : (inactiveStops.isNotEmpty ? inactiveStops.first.id : null);
    }

    final scrollController = widget.scrollController;
    // One line for the folded start/end tiles.
    var startName = 'Pick a stop';
    if (_selectedStartId == 'current_location') {
      startName = 'My current location';
    } else {
      for (final l in dayStops) {
        if (l.id == _selectedStartId) {
          startName = l.name;
          break;
        }
      }
    }
    final roundTrip = dayAccommodations.isNotEmpty && _returnToAcc;
    var endPhrase = roundTrip
        ? 'back at ${dayAccommodations.first.name}'
        : 'where the route does';
    if (_selectedFinalId != null) {
      for (final l in activeStops) {
        if (l.id == _selectedFinalId) {
          endPhrase = 'at ${l.name}';
          break;
        }
      }
    }
    // Nothing auto-picked: the tiles have to show so the user can pick.
    final showStartEnd = _startEndOpen || _selectedStartId == null;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              widget.isReoptimizing
                  ? 'Pick where the new route should begin.'
                  : 'Set the start time and travel style, then optimize.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        Expanded(
          child: ListView(
            controller: scrollController,
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            children: [
              _buildStartAtCard(context),
              const SizedBox(height: 16),
              // Travel style: which mode anchors the whole route.
              // Loose locations (no active trip) optimize with the SAME
              // machinery under the 'no_trip' sentinel — the exact key
              // the optimizer reads (`tripId ?? 'no_trip'` in
              // trip_provider) — so the picker shows either way instead
              // of silently locking tripless users to the defaults.
              Builder(builder: (context) {
                final tripId =
                    ref.watch(realtimeActiveTripProvider).valueOrNull?.id ??
                        'no_trip';
                _loadTravelProfile(tripId);
                return Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: _buildTravelStyleRow(context, tripId),
                );
              }),
              if (!showStartEnd)
                _startEndSummary(context, start: startName, end: endPhrase)
              else ...[
                if (dayAccommodations.isNotEmpty) ...[
                  _sectionLabel(context, 'Accommodation'),
                  ...dayAccommodations.map((loc) => _StartPointTile(
                        leading: Icon(Icons.hotel_outlined,
                            color: theme.colorScheme.primary),
                        title: loc.name,
                        subtitle: 'Your stay — start the day from here',
                        value: loc.id,
                        groupValue: _selectedStartId,
                        onChanged: _pickStart,
                      )),
                  // Round trip: does the day END back at the hotel?
                  // Fed into the optimizer as its fixed destination /
                  // loop-home leg. Persisted per trip.
                  Builder(builder: (context) {
                    final tripId =
                        ref.read(realtimeActiveTripProvider).valueOrNull?.id ??
                            'no_trip';
                    return Container(
                      margin: const EdgeInsets.only(top: 6),
                      decoration: BoxDecoration(
                        color: theme.cardColor.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                            color: theme.dividerColor.withValues(alpha: 0.4)),
                      ),
                      child: Column(
                        children: [
                          SwitchListTile.adaptive(
                            value: _returnToAcc,
                            onChanged: (v) {
                              setState(() {
                                _returnToAcc = v;
                                // With the round trip on, the hotel is
                                // the end by definition — a final pick
                                // of the hotel itself is redundant.
                                if (v &&
                                    dayAccommodations
                                        .any((a) => a.id == _selectedFinalId)) {
                                  _selectedFinalId = null;
                                }
                              });
                              LegModePrefs.setReturnToAccommodation(tripId, v);
                            },
                            dense: true,
                            contentPadding:
                                const EdgeInsets.symmetric(horizontal: 12),
                            title: Text('Return to accommodation',
                                style: theme.textTheme.bodyMedium
                                    ?.copyWith(fontWeight: FontWeight.w600)),
                            activeTrackColor: theme.colorScheme.primary,
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                            child: Text(
                              _returnToAcc
                                  ? 'The route ends back at your stay — '
                                      'the optimizer plans the day as a '
                                      'loop. Pick an end point below and '
                                      'it becomes the last stop before '
                                      'heading home.'
                                  : 'Open-ended day: the route finishes '
                                      'at its last stop, with no ride '
                                      'back to your stay.',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                  const SizedBox(height: 16),
                ],
                if (hasCurrentLocation) ...[
                  _sectionLabel(context, 'My location'),
                  _StartPointTile(
                    leading: Icon(Icons.my_location,
                        color: currentLocationDisabled
                            ? theme.colorScheme.onSurfaceVariant
                                .withValues(alpha: 0.5)
                            : theme.colorScheme.primary),
                    title: 'My current location',
                    subtitle: currentLocationDisabled
                        ? (tripCountry != null
                            ? 'You\'re outside this trip\'s country — pick a stop within ${activeTrip?.countryCode ?? 'the trip\'s region'} to start from instead.'
                            : 'You\'re far from these stops — pick a stop to start from instead.')
                        : (_countryCheckInFlight && tripCountry != null
                            ? 'Checking whether you\'re in the trip\'s country…'
                            : (inTripRegion && tripCountry != null
                                ? 'You\'re in this trip\'s country — start from where you stand'
                                : 'Use device GPS as the start anchor')),
                    value: 'current_location',
                    groupValue: _selectedStartId,
                    onChanged: _pickStart,
                    disabled: currentLocationDisabled,
                  ),
                  const SizedBox(height: 16),
                ],
                _sectionLabel(
                  context,
                  'Active stops',
                  trailing:
                      activeStops.isEmpty ? null : '${activeStops.length}',
                ),
                if (activeStops.isEmpty)
                  _emptyHint(
                      context, 'No active stops on this day to start from.')
                else
                  ...activeStops.map((loc) => _StartPointTile(
                        leading: Icon(Icons.place_outlined,
                            color: theme.colorScheme.primary),
                        title: loc.name,
                        subtitle: loc.address.isNotEmpty ? loc.address : null,
                        value: loc.id,
                        groupValue: _selectedStartId,
                        onChanged: _pickStart,
                      )),
                if (inactiveStops.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _sectionLabel(
                    context,
                    'Skipped & done',
                    trailing: '${inactiveStops.length}',
                  ),
                  Padding(
                    padding:
                        const EdgeInsets.only(bottom: 8, left: 4, right: 4),
                    child: Text(
                      'Selectable as anchor only — these aren\'t '
                      'included in the optimized route.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  ...inactiveStops.map((loc) => _StartPointTile(
                        leading: Icon(
                          loc.isDone
                              ? Icons.check_circle_outline
                              : Icons.remove_circle_outline,
                          color: loc.isDone
                              ? Colors.green.shade600
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                        title: loc.name,
                        subtitle: loc.address.isNotEmpty ? loc.address : null,
                        value: loc.id,
                        groupValue: _selectedStartId,
                        onChanged: _pickStart,
                        statusChip: _StatusChip(
                          label: loc.isDone ? 'Done' : 'Skipped',
                          color: loc.isDone
                              ? Colors.green.shade600
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                        mutedTitle: true,
                      )),
                ],
                // ── End point (optional) ───────────────────────────
                // Candidates: today's active stops minus the chosen
                // start, minus the accommodation while the round trip
                // is on (it's already the end then).
                Builder(builder: (context) {
                  final hasAcc = dayAccommodations.isNotEmpty;
                  final roundTrip = hasAcc && _returnToAcc;
                  final candidates = activeStops
                      .where((l) =>
                          l.id != _selectedStartId &&
                          !(roundTrip && l.isAccommodation))
                      .toList();
                  if (_selectedFinalId != null &&
                      !candidates.any((l) => l.id == _selectedFinalId)) {
                    _selectedFinalId = null; // start took it / hidden
                  }
                  if (candidates.isEmpty) return const SizedBox.shrink();
                  final chosen = _selectedFinalId == null
                      ? null
                      : candidates.firstWhere((l) => l.id == _selectedFinalId);
                  final accName = hasAcc ? dayAccommodations.first.name : '';
                  final String note;
                  if (chosen == null) {
                    note = roundTrip
                        ? 'Optional. By default the day ends back at '
                            '$accName.'
                        : 'Optional. By default the day ends at the '
                            'stop farthest from your start.';
                  } else if (roundTrip) {
                    note = '${chosen.name} will be the last stop, then '
                        'the route returns to $accName.';
                  } else {
                    note = '${chosen.name} will be the last stop of the '
                        'day.';
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 16),
                      _sectionLabel(context, 'End the day at'),
                      Padding(
                        padding:
                            const EdgeInsets.only(bottom: 8, left: 4, right: 4),
                        child: Text(
                          note,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      _StartPointTile(
                        leading: Icon(Icons.auto_awesome_rounded,
                            color: theme.colorScheme.primary),
                        title: 'Let VoyZa decide',
                        value: '',
                        groupValue: _selectedFinalId ?? '',
                        onChanged: (_) =>
                            setState(() => _selectedFinalId = null),
                      ),
                      ...candidates.map((loc) => _StartPointTile(
                            leading: Icon(Icons.flag_outlined,
                                color: theme.colorScheme.primary),
                            title: loc.name,
                            subtitle:
                                loc.address.isNotEmpty ? loc.address : null,
                            value: loc.id,
                            groupValue: _selectedFinalId ?? '',
                            onChanged: (v) =>
                                setState(() => _selectedFinalId = v),
                          )),
                    ],
                  );
                }),
              ],
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: FilledButton(
                    onPressed: _selectedStartId == null
                        ? null
                        : () {
                            final id = _selectedStartId!;
                            Navigator.of(context).pop();
                            // Fresh user-initiated optimize:
                            // clear any "Go anyway" acknowledgements
                            // from a previous planning attempt so
                            // warnings re-surface from scratch.
                            ref
                                .read(
                                    acknowledgedTimingWarningsProvider.notifier)
                                .state = const {};
                            ref
                                .read(tripProvider.notifier)
                                .generateOptimizedRoute(
                                    startLocationId: id,
                                    finalLocationId: _selectedFinalId,
                                    selectedDate: selectedDate);
                          },
                    style: FilledButton.styleFrom(
                      backgroundColor: theme.colorScheme.primary,
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    child: Text(
                      widget.isReoptimizing ? 'Re-optimize' : 'Optimize',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// The folded start/end tiles: where the day starts and ends in one
  /// line, a tap opens the tiles.
  Widget _startEndSummary(BuildContext context,
      {required String start, required String end}) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.cardColor.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.4)),
      ),
      child: ListTile(
        key: const Key('day-plan-start-end'),
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
        leading: Icon(Icons.flag_outlined, color: theme.colorScheme.primary),
        title: Text('Start and end',
            style: theme.textTheme.bodyMedium
                ?.copyWith(fontWeight: FontWeight.w600)),
        subtitle: Text('Starts at $start · Ends $end',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        trailing: const Icon(Icons.expand_more_rounded),
        onTap: () => setState(() => _startEndOpen = true),
      ),
    );
  }

  Widget _buildStartAtCard(BuildContext context) {
    final theme = Theme.of(context);
    final start = ref.watch(effectiveTripStartTimeProvider);
    // Only an explicit user pick needs a way back: with no override the
    // card already follows the live clock, so Reset would be a no-op.
    final hasOverride = ref.watch(tripStartTimeOverrideProvider) != null;
    final timeLabel =
        '${start.hour.toString().padLeft(2, '0')}:${start.minute.toString().padLeft(2, '0')}';

    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () async {
        final picked = await showTimePicker(
          context: context,
          initialTime: TimeOfDay(hour: start.hour, minute: start.minute),
          helpText: 'Start at',
        );
        if (picked == null) return;
        ref.read(tripStartTimeOverrideProvider.notifier).state = picked;
        if (mounted) setState(() {});
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: theme.colorScheme.primary.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: theme.colorScheme.primary.withValues(alpha: 0.35),
          ),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(Icons.schedule_rounded,
                  color: theme.colorScheme.primary, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Start at',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      letterSpacing: 0.4,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    timeLabel,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
            if (hasOverride) ...[
              TextButton.icon(
                onPressed: () {
                  ref.read(tripStartTimeOverrideProvider.notifier).state = null;
                  if (mounted) setState(() {});
                },
                icon: const Icon(Icons.restore_rounded, size: 16),
                label: const Text('Reset to now'),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  foregroundColor: theme.colorScheme.primary,
                  textStyle: theme.textTheme.labelMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(width: 4),
            ],
            Icon(Icons.edit_outlined,
                size: 18,
                color: theme.colorScheme.primary.withValues(alpha: 0.8)),
          ],
        ),
      ),
    );
  }

  Widget _sectionLabel(BuildContext context, String text, {String? trailing}) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
      child: Row(
        children: [
          Text(
            text.toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                trailing,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _emptyHint(BuildContext context, String text) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: theme.dividerColor.withValues(alpha: 0.4),
        ),
      ),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// Card-style "radio" row used inside [_StartPointSheet]. Larger tap target
/// than RadioListTile and shows an optional status chip for skipped/done
/// stops.
class _StartPointTile extends StatelessWidget {
  final Widget leading;
  final String title;
  final String? subtitle;
  final String value;
  final String? groupValue;
  final ValueChanged<String?> onChanged;
  final Widget? statusChip;
  final bool mutedTitle;
  final bool disabled;

  const _StartPointTile({
    required this.leading,
    required this.title,
    this.subtitle,
    required this.value,
    required this.groupValue,
    required this.onChanged,
    this.statusChip,
    this.mutedTitle = false,
    this.disabled = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isSelected = !disabled && value == groupValue;
    final fadedTitleColor =
        theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.45);
    final fadedSubtitleColor =
        theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7);
    final borderColor = disabled
        ? theme.dividerColor.withValues(alpha: 0.25)
        : (isSelected
            ? theme.colorScheme.primary.withValues(alpha: 0.6)
            : theme.dividerColor.withValues(alpha: 0.3));
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Opacity(
        opacity: disabled ? 0.6 : 1.0,
        child: Material(
          color: disabled
              ? theme.cardColor.withValues(alpha: 0.6)
              : (isSelected
                  ? theme.colorScheme.primary.withValues(alpha: 0.08)
                  : theme.cardColor),
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: disabled ? null : () => onChanged(value),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: borderColor,
                  width: isSelected ? 1.5 : 1,
                ),
              ),
              child: Row(
                children: [
                  leading,
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Expanded(
                              child: Text(
                                title,
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: disabled
                                      ? fadedTitleColor
                                      : (mutedTitle
                                          ? theme.textTheme.bodyMedium?.color
                                              ?.withValues(alpha: 0.75)
                                          : null),
                                  decoration: mutedTitle
                                      ? TextDecoration.lineThrough
                                      : null,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (statusChip != null) ...[
                              const SizedBox(width: 8),
                              statusChip!,
                            ],
                          ],
                        ),
                        if (subtitle != null && subtitle!.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            subtitle!,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: disabled
                                  ? fadedSubtitleColor
                                  : theme.colorScheme.onSurfaceVariant,
                            ),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    disabled
                        ? Icons.block
                        : (isSelected
                            ? Icons.radio_button_checked
                            : Icons.radio_button_off),
                    size: 22,
                    color: disabled
                        ? theme.colorScheme.onSurfaceVariant
                            .withValues(alpha: 0.5)
                        : (isSelected
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurfaceVariant
                                .withValues(alpha: 0.6)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Small pill rendered next to a start-point title to indicate skipped/done.
class _StatusChip extends StatelessWidget {
  final String label;
  final Color color;

  const _StatusChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w600,
          fontSize: 11,
        ),
      ),
    );
  }
}

/// Dashed rounded-rect outline for the add-day square — Flutter has no
/// built-in dashed BorderSide.
