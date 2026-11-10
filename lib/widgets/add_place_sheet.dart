import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../core/theme.dart';
import '../models/saved_location.dart';
import '../models/trip.dart';
import '../providers/local_active_trip_provider.dart';
import '../providers/location_provider.dart';
import '../providers/map_ui_state_provider.dart';
import '../providers/nearby_radius_provider.dart';
import '../providers/paginated_search_provider.dart';
import '../providers/trip_collaborator_provider.dart';
import '../providers/trip_provider.dart';
import '../services/location_add_service.dart';
import '../services/places_gateway.dart';
import '../services/places_service.dart';
import '../services/subscription_limit_service.dart';
import '../utils/same_day_place_guard.dart';
import '../utils/trip_day_labels.dart';
import '../utils/trip_dates.dart';
import 'app_toast.dart';
import 'nearby_places_picker_sheet.dart';

/// The three ways to name a place.
enum AddPlaceSegment { search, nearby, paste }

/// THE way to add a place, from every door: the map's search bar, the trip
/// page's button, a day's "+", the map long-press, the accommodation
/// prompt. Bound to one [trip] (null on a trip-less map: loose places) and
/// one [day], shown in the header so the person always knows where the
/// place will land. Stays open after an add for the next one.
Future<void> showAddPlaceSheet(
  BuildContext context, {
  required Trip? trip,
  required DateTime day,
  AddPlaceSegment initial = AddPlaceSegment.search,
  LatLng? nearbyCenter,
  String? nearbyCenterLabel,
}) async {
  // Adding places is VoyZa Pro: ask before the sheet opens, so nobody
  // searches for a place they cannot save. A member who may only view the
  // trip skips the question; the sheet itself tells them why they can't add.
  final container = ProviderScope.containerOf(context, listen: false);
  final viewOnly = trip != null &&
      container.read(hasWriteAccessProvider(trip.id)).valueOrNull == false;
  if (!viewOnly) {
    final ok = await SubscriptionLimitService.ensureCanAdd(context);
    if (!ok || !context.mounted) return;
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: AppTheme.sheetBarrierColor(context),
    builder: (_) => AddPlaceSheet(
      trip: trip,
      day: day,
      initial: initial,
      nearbyCenter: nearbyCenter,
      nearbyCenterLabel: nearbyCenterLabel,
    ),
  );
}

class AddPlaceSheet extends ConsumerStatefulWidget {
  const AddPlaceSheet({
    super.key,
    required this.trip,
    required this.day,
    this.initial = AddPlaceSegment.search,
    this.nearbyCenter,
    this.nearbyCenterLabel,
  });

  final Trip? trip;
  final DateTime day;
  final AddPlaceSegment initial;

  /// Where "Nearby" looks around. Null: the day's first stop, else the
  /// middle of the map, else the device.
  final LatLng? nearbyCenter;
  final String? nearbyCenterLabel;

  @override
  ConsumerState<AddPlaceSheet> createState() => _AddPlaceSheetState();
}

class _AddPlaceSheetState extends ConsumerState<AddPlaceSheet> {
  late AddPlaceSegment _segment = widget.initial;
  bool _nearbyVisited = false;

  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();
  final _pasteController = TextEditingController();
  Timer? _debounce;

  /// Label of the request in flight; the overlay shows it and blocks taps.
  String? _busy;

  /// Captured in initState: `ref` is unusable from dispose, and the search
  /// state is app-lifetime, so clearing it after unmount is safe.
  late final PaginatedSearchNotifier _search;

  Trip? get _trip => widget.trip;
  PlacesGateway get _places => ref.read(placesGatewayProvider);
  String get _targetName => _trip?.name ?? 'your places';
  String get _dayLabel => DayLabeler.forTrip(_trip)(widget.day);

  @override
  void initState() {
    super.initState();
    _search = ref.read(paginatedSearchProvider.notifier);
    _nearbyVisited = widget.initial == AddPlaceSegment.nearby;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _searchFocus.dispose();
    _pasteController.dispose();
    // Not synchronously: clearing notifies this (still subscribed) element.
    // Guarded: in a test the container may already have disposed it.
    final search = _search;
    Future.microtask(() {
      if (search.mounted) search.clear();
    });
    super.dispose();
  }

  // ── Shared checks ────────────────────────────────────────────────────

  Future<bool> _canWrite() async {
    final trip = _trip;
    if (trip == null) return true;
    try {
      return await ref.read(hasWriteAccessProvider(trip.id).future);
    } catch (_) {
      return true; // unknown offline: the server's rules decide
    }
  }

  void _refuseWrite() => AppToast.warning(
      context, 'You don\'t have permission to add locations to this trip.');

  /// The rows of this trip (or the loose places) planned on the day.
  Iterable<SavedLocation> _rowsOnDay() {
    final day = dayKey(widget.day);
    final all =
        ref.read(savedLocationsProvider).valueOrNull ?? const <SavedLocation>[];
    return all.where((l) =>
        l.tripId == _trip?.id &&
        l.scheduledDate != null &&
        l.isActiveOnDate(day));
  }

  /// Same-day duplicate rule, run before paying for Place Details.
  bool _isAlreadyOnDay({
    String? placeId,
    String? name,
    double? lat,
    double? lng,
  }) {
    final hasId = placeId != null && placeId.isNotEmpty;
    final hasName = name != null && name.isNotEmpty;
    if (!hasId && !hasName) return false;
    final candidate = (
      id: '',
      placeId: placeId,
      name: name ?? '',
      lat: lat ?? double.nan,
      lng: lng ?? double.nan,
    );
    return filterSameDayDuplicates(
      moving: [candidate],
      occupantsOnDay: _rowsOnDay().map(placeKeyOfSaved),
      samePlace: isLikelySamePlace,
    ).allowedIds.isEmpty;
  }

  void _toastDuplicate(String name) =>
      AppToast.warning(context, '"$name" is already planned for $_dayLabel');

  Future<bool> _add(PlaceDetails details,
      {String? tag, bool tagConfirmed = false, bool skipLimitCheck = false}) {
    return LocationAddService(ref).addPlace(
      context,
      details,
      trip: _trip,
      day: widget.day,
      tag: tag,
      tagConfirmed: tagConfirmed,
      skipLimitCheck: skipLimitCheck,
    );
  }

  // ── Search ───────────────────────────────────────────────────────────

  void _onSearchChanged(String value) {
    setState(() {}); // clear-button visibility
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (value.isEmpty) {
        _search.clear();
      } else {
        _search.search(value, countryCodeOverride: _trip?.countryCode);
      }
    });
  }

  /// Back to "ready for the next one": field cleared, keyboard kept.
  void _resetSearch() {
    _debounce?.cancel();
    _searchController.clear();
    _search.clear();
    if (mounted) {
      setState(() {});
      _searchFocus.requestFocus();
    }
  }

  Future<void> _selectPrediction(PlacePrediction prediction) async {
    if (_busy != null) return;
    if (!await _canWrite()) {
      if (mounted) _refuseWrite();
      return;
    }
    if (!mounted) return;
    if (_isAlreadyOnDay(placeId: prediction.placeId)) {
      _toastDuplicate(prediction.mainText);
      _resetSearch();
      return;
    }
    setState(() => _busy = 'Adding location…');
    try {
      var details = await _places.details(prediction.placeId);
      if (!mounted) return;
      if (details == null) {
        AppToast.error(context, 'Failed to get location details');
        return;
      }
      // Place Details may answer with a canonical id that differs from the
      // prediction's; re-check against that one before writing.
      if (details.placeId == null) {
        details = _withPlaceId(details, prediction.placeId);
      }
      if (_isAlreadyOnDay(
        placeId: details.placeId,
        name: details.name,
        lat: details.coordinates.latitude,
        lng: details.coordinates.longitude,
      )) {
        _toastDuplicate(details.name);
        _resetSearch();
        return;
      }
      final added = await _add(details);
      if (!mounted || !added) return;
      AppToast.success(context, 'Added ${details.name} to $_targetName');
      _resetSearch();
    } catch (e) {
      if (mounted) AppToast.error(context, 'Error: $e');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  // ── Paste a link ─────────────────────────────────────────────────────

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData('text/plain');
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty || !mounted) return;
    setState(() {
      _pasteController.text = text;
      _pasteController.selection =
          TextSelection(baseOffset: 0, extentOffset: text.length);
    });
  }

  Future<void> _addFromLink() async {
    final text = _pasteController.text.trim();
    if (text.isEmpty || _busy != null) return;
    setState(() => _busy = 'Decoding link…');
    try {
      final PlaceDetails? details;
      try {
        details = await _places.fromMapsLink(text);
      } on InvalidMapsLink {
        if (mounted) AppToast.warning(context, 'Not a valid Google Maps link');
        return;
      }
      if (!mounted) return;
      if (details == null) {
        AppToast.error(context, 'Could not decode location from URL');
        return;
      }
      if (!await _canWrite()) {
        if (mounted) _refuseWrite();
        return;
      }
      if (!mounted) return;
      if (_isAlreadyOnDay(
        placeId: details.placeId,
        name: details.name,
        lat: details.coordinates.latitude,
        lng: details.coordinates.longitude,
      )) {
        _toastDuplicate(details.name);
        return;
      }
      final added = await _add(details);
      if (!mounted || !added) return;
      AppToast.success(context, 'Added ${details.name} to $_targetName');
      setState(() => _pasteController.clear());
    } catch (e) {
      if (mounted) AppToast.error(context, 'Failed to decode URL: $e');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  // ── Nearby ───────────────────────────────────────────────────────────

  /// Where to look around, and how to say it. The press point when the
  /// map handed one over; otherwise the day's first stop, the middle of
  /// the map, the device — whichever is known first.
  ({LatLng center, String label})? _nearbyAround() {
    final given = widget.nearbyCenter;
    if (given != null) {
      return (
        center: given,
        label: widget.nearbyCenterLabel ?? 'where you tapped'
      );
    }
    final rows = _rowsOnDay().toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    if (rows.isNotEmpty) {
      final r = rows.first;
      return (center: LatLng(r.lat, r.lng), label: 'your first stop that day');
    }
    final camera = ref.read(mapCameraTargetProvider);
    if (camera != null) return (center: camera, label: 'the middle of the map');
    final here = ref.read(tripProvider).currentLocation;
    if (here != null) return (center: here, label: 'where you are');
    return null;
  }

  Future<void> _addNearby(List<NearbyPlace> pickedAll) async {
    if (_busy != null || pickedAll.isEmpty) return;
    // ONE decision — and at most one paywall — for the batch (a backstop:
    // the sheet's door already asked).
    final allowed = await SubscriptionLimitService(ref)
        .canAddPlaces(context, pickedAll.length);
    if (!mounted || allowed == 0) return;
    final picked = pickedAll;
    setState(() => _busy = picked.length == 1
        ? 'Adding location…'
        : 'Adding ${picked.length} locations…');
    try {
      // Nearby Search alone returns one photo and no country; Place
      // Details fills both in. A failed lookup keeps the nearby row.
      final enriched = await Future.wait(picked
          .map((p) => _places.details(p.placeId).catchError((_) => null)));
      if (!mounted) return;
      final names = <String>[];
      for (var i = 0; i < picked.length; i++) {
        final details = _mergeNearby(picked[i], enriched[i]);
        final added = await _add(details,
            tag: picked[i].tag, tagConfirmed: true, skipLimitCheck: true);
        if (!mounted) return;
        if (added) names.add(details.name);
      }
      if (names.isEmpty) return;
      AppToast.success(
        context,
        names.length == 1
            ? 'Added ${names.first} to $_targetName'
            : 'Added ${names.length} locations to $_targetName',
      );
      if (_trip?.id == ref.read(localActiveTripIdProvider)) {
        ref.read(mapUIStateProvider.notifier).clearHighlights();
      }
      Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  // ── Build ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DraggableScrollableSheet(
      initialChildSize: 0.9,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (context, scrollController) {
        return ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          child: BackdropFilter(
            filter: ImageFilter.blur(
                sigmaX: AppTheme.sheetBlurSigma,
                sigmaY: AppTheme.sheetBlurSigma),
            child: Container(
              decoration: BoxDecoration(
                color: theme.scaffoldBackgroundColor
                    .withValues(alpha: AppTheme.sheetFillAlpha(context)),
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(20)),
                border: Border.all(
                  color: AppTheme.sheetBorderColor(context),
                  width: 0.8,
                ),
              ),
              child: Stack(
                children: [
                  Column(
                    children: [
                      Container(
                        margin: const EdgeInsets.only(top: 12, bottom: 8),
                        height: 4,
                        width: 40,
                        decoration: BoxDecoration(
                          color: Colors.grey[400],
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      _header(theme),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                        child: SegmentedButton<AddPlaceSegment>(
                          showSelectedIcon: false,
                          segments: const [
                            ButtonSegment(
                              value: AddPlaceSegment.search,
                              icon: Icon(Icons.search, size: 18),
                              label: Text('Search'),
                            ),
                            ButtonSegment(
                              value: AddPlaceSegment.nearby,
                              icon: Icon(Icons.near_me_outlined, size: 18),
                              label: Text('Nearby'),
                            ),
                            ButtonSegment(
                              value: AddPlaceSegment.paste,
                              icon: Icon(Icons.link, size: 18),
                              label: Text('Paste link'),
                            ),
                          ],
                          selected: {_segment},
                          onSelectionChanged: (s) => setState(() {
                            _segment = s.first;
                            if (_segment == AddPlaceSegment.nearby) {
                              _nearbyVisited = true;
                            }
                          }),
                        ),
                      ),
                      Expanded(
                        // The segments keep their state while hidden; the
                        // nearby list is only built once it was opened, so
                        // nobody pays for a request they never asked for.
                        child: IndexedStack(
                          index: _segment.index,
                          children: [
                            _searchSegment(theme, scrollController),
                            _nearbyVisited
                                ? _nearbySegment(theme, scrollController)
                                : const SizedBox.shrink(),
                            _pasteSegment(theme),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (_busy != null) _busyOverlay(theme, _busy!),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _header(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 8, 0),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Add a place',
                  style: theme.textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 2),
                Text(
                  '$_targetName · $_dayLabel',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Close',
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  // ── Search segment ───────────────────────────────────────────────────

  Widget _searchSegment(ThemeData theme, ScrollController scrollController) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: TextField(
            key: const ValueKey('add-place-search'),
            cursorOpacityAnimates: false,
            controller: _searchController,
            focusNode: _searchFocus,
            autofocus: widget.initial == AddPlaceSegment.search,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: 'Search for a place...',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _searchController.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear',
                      icon: const Icon(Icons.clear),
                      onPressed: _resetSearch,
                    ),
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              filled: true,
              fillColor: theme.cardColor,
            ),
            onChanged: _onSearchChanged,
          ),
        ),
        const Divider(height: 1),
        Expanded(child: _searchResults(theme, scrollController)),
      ],
    );
  }

  Widget _searchResults(ThemeData theme, ScrollController scrollController) {
    final muted = theme.colorScheme.onSurfaceVariant;
    if (_searchController.text.isEmpty) {
      final country = _trip?.countryCode;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.search,
                  size: 56,
                  color: theme.colorScheme.primary.withValues(alpha: 0.35)),
              const SizedBox(height: 12),
              Text('Type a place name to start searching',
                  style: theme.textTheme.bodyMedium?.copyWith(color: muted),
                  textAlign: TextAlign.center),
              if (country != null) ...[
                const SizedBox(height: 4),
                Text('Results favour the trip\'s country',
                    style: theme.textTheme.bodySmall?.copyWith(color: muted)),
              ],
            ],
          ),
        ),
      );
    }

    final state = ref.watch(paginatedSearchProvider);
    if (state.isLoading && state.results.isEmpty) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (state.error != null && state.results.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text('Error: ${state.error}',
              style: TextStyle(color: theme.colorScheme.error)),
        ),
      );
    }
    if (state.results.isEmpty) {
      return Center(
        child: Text('No places found',
            style: theme.textTheme.bodyMedium?.copyWith(color: muted)),
      );
    }
    return NotificationListener<ScrollUpdateNotification>(
      onNotification: (n) {
        if (n.metrics.pixels >= n.metrics.maxScrollExtent * 0.8) {
          _search.loadMore();
        }
        return false;
      },
      child: ListView.separated(
        controller: scrollController,
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 24),
        itemCount: state.results.length + (state.hasMore ? 1 : 0),
        separatorBuilder: (_, __) => const Divider(height: 1, indent: 56),
        itemBuilder: (context, i) {
          if (i == state.results.length) {
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: state.isLoading
                    ? const SizedBox(
                        height: 22,
                        width: 22,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const SizedBox.shrink(),
              ),
            );
          }
          final p = state.results[i];
          return ListTile(
            leading: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(Icons.location_on, color: theme.colorScheme.primary),
            ),
            title: Text(p.mainText,
                style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(p.secondaryText,
                    style: theme.textTheme.bodyMedium?.copyWith(color: muted)),
                if (p.distanceMeters != null) ...[
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(Icons.near_me,
                          size: 12, color: theme.colorScheme.primary),
                      const SizedBox(width: 4),
                      Text(
                        _formatDistance(p.distanceMeters!),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
            onTap: () => _selectPrediction(p),
          );
        },
      ),
    );
  }

  // ── Nearby segment ───────────────────────────────────────────────────

  Widget _nearbySegment(ThemeData theme, ScrollController scrollController) {
    final around = _nearbyAround();
    if (around == null) {
      final muted = theme.colorScheme.onSurfaceVariant;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.near_me_disabled_outlined, size: 48, color: muted),
              const SizedBox(height: 12),
              Text(
                'Nothing to look around yet — long-press the map where you '
                'want to look, or find a first place by name.',
                style: theme.textTheme.bodyMedium?.copyWith(color: muted),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () =>
                    setState(() => _segment = AddPlaceSegment.search),
                icon: const Icon(Icons.search),
                label: const Text('Search by name'),
              ),
            ],
          ),
        ),
      );
    }
    final center = around.center;
    return NearbyPlacesPickerSheet(
      key: ValueKey('nearby-${center.latitude}-${center.longitude}'),
      embedded: true,
      scrollController: scrollController,
      places: const [],
      loadOnOpen: true,
      radiusMeters: ref.read(nearbyRadiusProvider).round(),
      aroundLabel: around.label,
      occupantsOnDay: _rowsOnDay().map(placeKeyOfSaved).toList(),
      // Apply in the picker: the new radius becomes the default next time.
      onRequery: (r) async {
        await ref.read(nearbyRadiusProvider.notifier).set(r.toDouble());
        return _places.nearby(center, radiusMeters: r);
      },
      onSearchText: (q, r) => _places.nearbyByText(q, center, radiusMeters: r),
      onConfirm: _addNearby,
      onCancel: () => Navigator.of(context).pop(),
    );
  }

  // ── Paste segment ────────────────────────────────────────────────────

  Widget _pasteSegment(ThemeData theme) {
    final muted = theme.colorScheme.onSurfaceVariant;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Paste a Google Maps link and the place lands on $_dayLabel.',
            style: theme.textTheme.bodyMedium?.copyWith(color: muted),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('add-place-link'),
            cursorOpacityAnimates: false,
            controller: _pasteController,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.go,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _addFromLink(),
            decoration: InputDecoration(
              hintText: 'https://maps.app.goo.gl/...',
              filled: true,
              fillColor: theme.cardColor,
              suffixIcon: IconButton(
                icon: const Icon(Icons.content_paste_rounded),
                tooltip: 'Paste',
                onPressed: _pasteFromClipboard,
              ),
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _pasteController.text.trim().isEmpty || _busy != null
                ? null
                : _addFromLink,
            icon: const Icon(Icons.add_location_alt_outlined),
            label: const Text('Add this place'),
          ),
        ],
      ),
    );
  }

  Widget _busyOverlay(ThemeData theme, String label) {
    return Positioned.fill(
      child: AbsorbPointer(
        child: ColoredBox(
          color: Colors.black.withValues(alpha: 0.25),
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
              decoration: BoxDecoration(
                color: theme.colorScheme.surface,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.2),
                    blurRadius: 16,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.4),
                  ),
                  const SizedBox(width: 14),
                  Text(label,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _formatDistance(int meters) {
  if (meters < 1000) return '${meters}m away';
  return '${(meters / 1000).toStringAsFixed(1)}km away';
}

/// Place Details answered without an id (it happens for some CID rows):
/// keep the prediction's, so the duplicate rule and later lookups work.
PlaceDetails _withPlaceId(PlaceDetails d, String placeId) => PlaceDetails(
      name: d.name,
      address: d.address,
      coordinates: d.coordinates,
      photoReference: d.photoReference,
      photoReferences: d.photoReferences,
      photoWidth: d.photoWidth,
      photoHeight: d.photoHeight,
      photoAttributions: d.photoAttributions,
      countryCode: d.countryCode,
      placeId: placeId,
      openingHours: d.openingHours,
      types: d.types,
      floor: d.floor,
    );

/// A nearby row enriched by Place Details where Details answered, the
/// nearby row's own facts where it did not.
PlaceDetails _mergeNearby(NearbyPlace p, PlaceDetails? d) => PlaceDetails(
      name: d != null && d.name.isNotEmpty ? d.name : p.name,
      address: d != null && d.address.isNotEmpty ? d.address : p.vicinity,
      coordinates: d?.coordinates ?? p.coordinates,
      photoReference: d?.photoReference ?? p.photoReference,
      photoReferences: d != null && d.photoReferences.isNotEmpty
          ? d.photoReferences
          : p.photoReferences,
      photoAttributions: d?.photoAttributions ?? p.photoAttributions,
      countryCode: d?.countryCode,
      placeId: d?.placeId ?? p.placeId,
      openingHours: d?.openingHours,
      types: d != null && d.types.isNotEmpty ? d.types : p.types,
      floor: d?.floor,
    );
