import 'dart:async';
import 'dart:math' as math;

import 'package:voyza/core/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';
import 'package:voyza/models/trip.dart';
import 'package:voyza/providers/location_provider.dart';
import 'package:voyza/providers/trip_collaborator_provider.dart';
import 'package:voyza/models/saved_location.dart';
import 'package:voyza/providers/auth_provider.dart';
import 'package:voyza/widgets/app_toast.dart';
import 'package:voyza/widgets/collaborators_sheet.dart';
import 'package:voyza/widgets/sign_up_required_sheet.dart';
import 'package:voyza/providers/onboarding_checklist_provider.dart';
import 'package:voyza/widgets/onboarding_checklist.dart';
import 'package:voyza/services/onboarding_service.dart';
import 'package:voyza/models/location_model.dart';
import 'package:voyza/widgets/celebration_dialogs.dart';
import 'package:voyza/widgets/location_detail_sheet.dart';
import 'package:voyza/providers/day_distribution_provider.dart';
import 'package:voyza/widgets/buddy_nudge_row.dart';
import 'package:voyza/widgets/plan_sheet.dart';
import 'package:voyza/providers/user_trip_provider.dart';
import 'package:voyza/utils/date_picker_utils.dart';
import 'package:voyza/widgets/location_photo_gallery.dart';
import 'package:voyza/providers/local_active_trip_provider.dart';
import 'package:voyza/providers/trip_provider.dart';
import 'package:voyza/widgets/accommodation_prompts.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:voyza/providers/map_ui_state_provider.dart';
import 'package:voyza/widgets/add_place_sheet.dart';
import 'package:voyza/widgets/optimized_location_card.dart';
import 'package:voyza/widgets/place_selection_actions.dart';
import 'package:voyza/services/csv_service.dart';
import 'package:voyza/utils/location_order.dart';
import 'package:voyza/utils/open_trip_on_map.dart';
import 'package:voyza/utils/same_day_place_guard.dart';
import 'package:voyza/utils/search_text.dart';
import 'package:voyza/utils/trip_dates.dart';
import 'package:voyza/utils/unvisited_places.dart';
import 'package:voyza/utils/trip_day_labels.dart';
import 'package:voyza/utils/trip_qr_text.dart';
import 'package:voyza/utils/trip_share_link.dart';
import 'package:voyza/utils/countries.dart';
import 'package:voyza/widgets/trip_qr_card.dart';
import 'package:voyza/utils/trip_times.dart';
import 'package:voyza/widgets/trip_times_lines.dart';
import 'package:voyza/widgets/trip_times_sheet.dart';
import 'package:voyza/widgets/trip_day_picker.dart';
import 'package:voyza/widgets/unvisited_places_sheet.dart';
import 'package:voyza/services/trip_dates_service.dart';
import 'package:voyza/services/itinerary_pdf_service.dart';
import 'package:voyza/services/trip_day_service.dart';
import 'package:voyza/services/trip_rollover_service.dart';
import 'package:voyza/widgets/static_glow.dart';
import 'package:voyza/widgets/rotating_globe_background.dart';

class TripDetailsScreen extends ConsumerStatefulWidget {
  final Trip trip;

  /// True only when pushed right after the user created their very first
  /// trip (see trip_screen._createTrip). Shows the one-time congrats modal
  /// on arrival — celebrating here, where the next action (adding places)
  /// lives, instead of on the screen being left behind.
  final bool celebrateFirstTrip;

  /// When set (notification tap: "X added a place"), the screen opens that
  /// location's detail sheet as soon as its data has loaded.
  final String? initialLocationId;

  const TripDetailsScreen({
    super.key,
    required this.trip,
    this.celebrateFirstTrip = false,
    this.initialLocationId,
  });

  @override
  ConsumerState<TripDetailsScreen> createState() => _TripDetailsScreenState();
}

class _TripDetailsScreenState extends ConsumerState<TripDetailsScreen> {
  /// widget.trip frozen at push time, overridden after in-screen changes to
  /// the trip's date range (the add-day tile) so the day slots refresh
  /// without reopening the screen.
  Trip? _tripOverride;
  Trip get _trip => _tripOverride ?? widget.trip;

  /// Itinerary PDF export: busy flag for the app-bar button, and its key so
  /// the share sheet can anchor to it on iPad.
  bool _exportingItinerary = false;
  final GlobalKey _exportButtonKey = GlobalKey();

  /// Share button: busy while the trip is published and the share sheet
  /// opens, and its key so the sheet can anchor to it on iPad.
  bool _sharingLink = false;
  final GlobalKey _shareButtonKey = GlobalKey();

  /// QR button: busy while the trip is published before its card opens.
  bool _openingQr = false;

  /// Map button: busy while the trip is made the active one.
  bool _openingMap = false;

  /// Builds the whole trip's itinerary (every day, where you stay, each
  /// place with its tag, planned time and hours) as a PDF and opens the
  /// share sheet. Always the full plan — a search filter on this page
  /// doesn't narrow it.
  /// Every place of the trip as a spreadsheet, day by day (unscheduled
  /// rows last).
  Future<void> _exportCsv() async {
    final all = ref.read(savedLocationsProvider).valueOrNull;
    if (all == null) {
      AppToast.info(context, 'Still loading your places — try again.');
      return;
    }
    final rows = all.where((l) => l.tripId == widget.trip.id).toList()
      ..sort((a, b) {
        final x = a.scheduledDate, y = b.scheduledDate;
        if (x == null || y == null) return x == null ? (y == null ? 0 : 1) : -1;
        return x.compareTo(y);
      });
    if (rows.isEmpty) {
      AppToast.info(context, 'Nothing to export yet.');
      return;
    }
    String coordAddress(SavedLocation l) =>
        '${l.lat.toStringAsFixed(5)}, ${l.lng.toStringAsFixed(5)}';
    try {
      await CsvService().generateAndShareTripCsv(
        [for (final l in rows) l.toLocationModel(address: coordAddress(l))],
        tripName: _trip.name,
        dayLabeler: _labeler,
      );
    } on MissingPluginException {
      if (mounted) AppToast.error(context, 'Sharing is not available here.');
    } catch (e) {
      if (mounted) AppToast.error(context, 'Could not export: $e');
    }
  }

  Future<void> _exportItinerary() async {
    final all = ref.read(savedLocationsProvider).valueOrNull;
    if (all == null) {
      AppToast.info(context, 'Still loading your places — try again.');
      return;
    }
    final places = all.where((l) => l.tripId == widget.trip.id).toList();
    if (places.isEmpty) {
      AppToast.info(context, 'Add a few places first — then export the plan.');
      return;
    }
    final box =
        _exportButtonKey.currentContext?.findRenderObject() as RenderBox?;
    final origin = box == null || !box.hasSize
        ? null
        : box.localToGlobal(Offset.zero) & box.size;

    setState(() => _exportingItinerary = true);
    try {
      await ItineraryPdfService.exportAndShare(
        trip: _trip,
        locations: places,
        shareOrigin: origin,
      );
    } catch (e) {
      debugPrint('_exportItinerary: $e');
      if (mounted) {
        AppToast.error(context, 'Couldn\'t create the itinerary — try again.');
      }
    } finally {
      if (mounted) setState(() => _exportingItinerary = false);
    }
  }

  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  // Stream created once so rebuilds (e.g. typing in search) don't recreate it,
  // which would cause StreamBuilder to briefly flash ConnectionState.waiting.
  late final Stream<List<SavedLocation>> _locationsStream;

  final _addLocationFabKey = GlobalKey();

  // ─── Multi-select state ────────────────────────────────────────────────
  /// Multi-select lives in the shared providers the card reads; captured
  /// notifiers reset them on dispose, so leaving the page never leaves
  /// cards half-selected elsewhere.
  bool get _selectionMode => ref.watch(isSelectionModeProvider);
  Set<String> get _selectedIds => ref.watch(selectedLocationsProvider);
  late final StateController<bool> _selectionModeNotifier;
  late final StateController<Set<String>> _selectedNotifier;
  List<SavedLocation> _currentTripLocations = [];

  /// Last count handed to the checklist from the stream builder — so a
  /// rebuild that changes nothing doesn't schedule another provider write.
  int? _lastReportedChecklistCount;

  /// Content equality for the cached trip list: same ids in the same order.
  /// The stream builder produces a NEW list object on every build, so an
  /// identity check (`!=`) was always true.
  static bool _sameLocationIds(List<SavedLocation> a, List<SavedLocation> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id) return false;
    }
    return true;
  }

  // Per-location COLLAPSE state for the photo dropdown. Tracks the
  // ids of cards the user has explicitly collapsed; everything else is
  // expanded by default. (Previously this tracked expanded ids, so the
  // default was collapsed — flipping the polarity here is the whole
  // change needed to show photos out of the box.)

  /// Days the user flipped to OLDEST added first with the header's sort
  /// toggle, keyed by the day's normalized midnight. Every other day shows
  /// the newest added place first, so what was just added is the first card
  /// under the header. Session-only view state, deliberately not persisted
  /// — like the photo collapse set — and it never writes to the locations
  /// themselves.
  final Set<DateTime> _oldestFirstDays = {};

  /// Per-day fold state the user set by tapping a header (true = folded).
  /// Days without an entry use the default: folded when the day is already
  /// behind the traveller on an ONGOING trip, open otherwise (see
  /// [_buildDateSection]). Lives for this screen's lifetime only.
  final Map<DateTime, bool> _dayFoldOverrides = {};

  /// Ongoing-trip landing: the day list opens scrolled to today, once per
  /// screen life. The sliver builds lazily, so the scroll pages down until
  /// today's section exists, then aligns it just under the header.
  final GlobalKey _todayDayKey = GlobalKey();
  bool _didAutoScrollToToday = false;

  /// Today's header colour on the day list — a different hue from every
  /// other day, so the eye lands on "now" first.
  static const Color _todayGreen = Color(0xFF34C759);

  /// Collapse state of the Unscheduled-bucket section (session-scoped).
  bool _unscheduledCollapsed = false;

  void _exitSelectionMode() {
    _selectionModeNotifier.state = false;
    _selectedNotifier.state = {};
  }

  /// The selection bar's Delete: the rows go entirely (no day scope on
  /// the trip page). Through the map trip, like every other action.
  Future<void> _deleteSelected() async {
    await _ensureMapTrip();
    if (!mounted) return;
    await deleteSelectedPlaces(context, ref);
  }

  Future<void> _showLocationDetail(
    SavedLocation location,
    int indexInList,
    List<SavedLocation> dateGroup,
  ) async {
    await _ensureMapTrip();
    if (!mounted) return;
    String coordAddress(SavedLocation l) =>
        '${l.lat.toStringAsFixed(5)}, ${l.lng.toStringAsFixed(5)}';

    final locationModel =
        location.toLocationModel(address: coordAddress(location));
    final dateGroupModels = dateGroup
        .map((l) => l.toLocationModel(address: coordAddress(l)))
        .toList();

    final scrollController = ScrollController();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      // Keep a full-height sheet (photos + hours + multi-day on small
      // screens) from rendering its header under the status bar/notch.
      useSafeArea: true,
      builder: (ctx) => LocationDetailSheet(
        location: locationModel,
        number: indexInList + 1,
        parentScrollController: scrollController,
        locationsForDate: dateGroupModels,
        // Pass the viewed trip ID so the Multi-day stay section's
        // permission gate and write path target this trip rather than
        // whichever trip is currently active on the map.
        tripId: widget.trip.id,
      ),
    ).whenComplete(scrollController.dispose);
  }

  @override
  void initState() {
    super.initState();
    _selectionModeNotifier = ref.read(isSelectionModeProvider.notifier);
    _selectedNotifier = ref.read(selectedLocationsProvider.notifier);
    // Ongoing trip with "carry unvisited places forward" on: catch up now
    // (once per trip per day) so the page shows today's real plan.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(TripRolloverService.runIfDue(ref));
    });
    _locationsStream = ref.read(locationRepositoryProvider).watchLocations();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Checklist: the add-locations guide is pre-armed by the wizard (or a
      // checklist tap on home). Consume it once the FAB is laid out.
      if (ref.read(checklistGuideRequestProvider) ==
          ChecklistGuide.addLocations) {
        ref.read(checklistGuideRequestProvider.notifier).state = null;
        Future.delayed(const Duration(milliseconds: 450), () {
          if (!mounted) return;
          showChecklistCoach(
            context,
            targetKey: _addLocationFabKey,
            title: 'Add 2 places',
            body: 'Search for spots you want to visit — cafés, sights, your '
                'hotel. Add 2 and step 2 is done; the badge up top keeps '
                'count.',
            align: ContentAlign.top,
          );
        });
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Invalidate permissions when screen is first created to ensure fresh data
      ref.invalidate(hasWriteAccessProvider(widget.trip.id));
      ref.invalidate(isTripOwnerProvider(widget.trip.id));
      ref.invalidate(userTripPermissionProvider(widget.trip.id));

      // Refresh location cache from Supabase so collaborators see each other's locations.
      // The local Hive box is only populated at login, so it may be stale if the user
      // was invited after they last logged in.
      //
      // DEFERRED past the push transition (~300 ms): the refresh can write
      // Hive rows, and each write re-emits the locations stream to every
      // watcher — doing that mid-animation was a visible stutter on the
      // home → details transition. Half a second of extra staleness is
      // imperceptible; a janked push animation is not.
      Future.delayed(const Duration(milliseconds: 600), () {
        if (!mounted) return;
        ref.read(locationRepositoryProvider).fetchRemoteLocations();
        unawaited(_loadSharedTripTimes());
      });

      // One-time "first trip" congrats. Double-gated: the caller only sets
      // the flag on a genuine first creation, and the per-user prefs flag
      // makes it impossible to repeat (e.g. delete-and-recreate).
      if (widget.celebrateFirstTrip) {
        _maybeCelebrateFirstTrip();
      }

      // Notification tap landing: open the added location's detail sheet
      // once its row is in (the remote refresh above may still be running).
      if (widget.initialLocationId != null) {
        _maybeOpenInitialLocation();
      }
    });
  }

  /// Waits (bounded) for [TripDetailsScreen.initialLocationId] to appear in
  /// this trip's locations, then opens its detail sheet — mirroring a tap on
  /// its card, including the same day-group so the multi-day section works.
  Future<void> _maybeOpenInitialLocation() async {
    final targetId = widget.initialLocationId;
    if (targetId == null) return;
    try {
      final all = await ref
          .read(locationRepositoryProvider)
          .watchLocations()
          .firstWhere((locs) =>
              locs.any((l) => l.id == targetId && l.tripId == widget.trip.id))
          .timeout(const Duration(seconds: 10));
      if (!mounted) return;

      final tripLocations =
          all.where((l) => l.tripId == widget.trip.id).toList();
      final target = tripLocations.firstWhere((l) => l.id == targetId);
      final targetStart = target.scheduledDate;
      // Same day-cover rule as _buildLocationsList: the group holds every
      // location whose scheduled range covers the target's first day. An
      // unscheduled target groups with the other Unscheduled-bucket rows.
      final dateGroup = targetStart == null
          ? tripLocations.where((l) => l.scheduledDate == null).toList()
          : tripLocations.where((l) {
              final startRaw = l.scheduledDate;
              if (startRaw == null) return false;
              final day = _dayKey(targetStart);
              final s = _dayKey(startRaw);
              final e = _dayKey(l.scheduledEndDate ?? startRaw);
              return !day.isBefore(s) && !day.isAfter(e);
            }).toList();
      var index = dateGroup.indexWhere((l) => l.id == targetId);
      if (index < 0) index = 0;
      _showLocationDetail(target, index, dateGroup);
    } catch (_) {
      // Timed out or gone (deleted / access revoked) — the details page is
      // still the right landing; just don't pop a sheet.
    }
  }

  Future<void> _maybeCelebrateFirstTrip() async {
    final userId = ref.read(currentUserIdProvider);
    if (userId == null) return;
    final service = OnboardingService.instance;
    if (await service.hasCelebrated(userId, OnboardingMilestone.firstTrip)) {
      return;
    }
    await service.markCelebrated(userId, OnboardingMilestone.firstTrip);
    if (mounted) {
      await showFirstTripCelebration(context);
    }
  }

  @override
  void dispose() {
    _stopDragAutoScroll();
    _listScrollController.dispose();
    _searchController.dispose();
    // Not synchronously: a state change here notifies elements that are
    // mid-dispose. The notifiers outlive the page (app-lifetime providers).
    final mode = _selectionModeNotifier;
    final selected = _selectedNotifier;
    Future.microtask(() {
      mode.state = false;
      selected.state = {};
    });
    super.dispose();
  }

  /// The whole-trip planner, through the one Plan sheet (the planner works
  /// on the map trip's state, so this trip becomes it first).
  Future<void> _openAutoPlan() async {
    await _ensureMapTrip();
    if (!mounted) return;
    showPlanSheet(context, initial: PlanScope.trip);
  }

  /// Every place action on this page goes through `TripNotifier`, which
  /// holds the trip on the map. Viewing the page never moves the map; the
  /// first action does, and waits for this trip's pins (see ensureMapTrip).
  Future<void> _ensureMapTrip() => ensureMapTrip(ref, _trip);

  /// The map button: this trip on the Map tab, on the day that matters —
  /// today while the trip is underway, day one otherwise. The map draws one
  /// trip at a time, so this becomes it.
  Future<void> _openOnMap() async {
    if (_openingMap) return;
    final trip = _trip;
    setState(() => _openingMap = true);
    try {
      await openTripOnMap(ref, trip);
      if (!mounted) return;
      // Back to the home screen, which is switching to its Map tab.
      Navigator.of(context).popUntil((route) => route.isFirst);
    } catch (e) {
      debugPrint('_openOnMap: $e');
      if (mounted) {
        AppToast.error(context, 'Could not open the map. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _openingMap = false);
    }
  }

  /// What both ways of handing the trip over need first: an account, and
  /// the trip public — a link or a QR code only works while it is. An owner
  /// whose trip is still private gets the same question as the Publish
  /// button. Returns the trip's share code, or null when there is nothing
  /// to hand over (not signed in, not the owner, declined, or it failed).
  Future<String?> _ensureShareCode({
    required IconData icon,
    required String signUpTitle,
    required String signUpMessage,
  }) async {
    if (ref.read(currentUserIdProvider) == null) {
      showSignUpRequiredSheet(
        context,
        icon: icon,
        title: signUpTitle,
        message: signUpMessage,
      );
      return null;
    }
    if (!(_trip.isPublic && _trip.shareCode != null)) {
      final isOwner =
          ref.read(isTripOwnerProvider(widget.trip.id)).valueOrNull ?? false;
      if (!isOwner) {
        AppToast.info(context, 'Only the trip owner can turn on sharing.');
        return null;
      }
      final published = await _setTripPublished(true, announce: false);
      if (!published || !mounted) return null;
    }
    final code = normalizeTripShareCode(_trip.shareCode);
    if (code == null && mounted) {
      AppToast.error(context, 'Could not create the link. Please try again.');
    }
    return code;
  }

  /// The share button: sends a link that opens this trip's copy flow — the
  /// share code without the typing.
  Future<void> _shareTripLink() async {
    if (_sharingLink) return;
    // Where the share sheet points on iPad — read before any await.
    final box =
        _shareButtonKey.currentContext?.findRenderObject() as RenderBox?;
    final origin = box == null || !box.hasSize
        ? null
        : box.localToGlobal(Offset.zero) & box.size;

    setState(() => _sharingLink = true);
    try {
      final code = await _ensureShareCode(
        icon: Icons.ios_share_rounded,
        signUpTitle: 'Sign up to share this trip',
        signUpMessage: 'A shared trip travels as a link: whoever opens it '
            'gets their own copy of your plan. Links belong to an account '
            '— this trip stays on your device and comes with you when you '
            'sign up.',
      );
      if (code == null || !mounted) return;
      await SharePlus.instance.share(ShareParams(
        text: tripShareMessage(tripName: _trip.name, shareCode: code),
        subject: 'A trip for you on VoyZa: ${_trip.name}',
        sharePositionOrigin: origin,
      ));
    } catch (e) {
      debugPrint('_shareTripLink: $e');
      if (mounted) {
        AppToast.error(context, 'Could not share the trip. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _sharingLink = false);
    }
  }

  /// The QR button: the trip as a card to show or send. The code on it
  /// holds the same link the share button sends, and nothing else; the
  /// card names the country — "Places to visit in Japan" — unless the
  /// traveller has written a headline of their own for this trip.
  Future<void> _showTripQr() async {
    if (_openingQr) return;
    setState(() => _openingQr = true);
    try {
      final code = await _ensureShareCode(
        icon: Icons.qr_code_2_rounded,
        signUpTitle: 'Sign up to share this trip',
        signUpMessage: 'A trip QR code lets anyone who scans it copy your '
            'plan. Codes belong to an account — this trip stays on your '
            'device and comes with you when you sign up.',
      );
      final link = tripShareLink(code);
      if (code == null || link == null || !mounted) return;

      final trip = _trip;
      final places = ref
          .read(savedLocationsProvider)
          .valueOrNull
          ?.where((l) => l.tripId == trip.id)
          .length;
      final start = trip.startDate;
      final end = trip.endDate;
      final days = start == null || end == null
          ? null
          : daySpanDays(dayKey(start), dayKey(end)) + 1;

      await showTripQrSheet(
        context,
        link: link,
        shareCode: code,
        tripId: trip.id,
        countryCode: findCountryByCode(trip.countryCode)?.code,
        text: TripQrText.forTrip(
          tripName: trip.name,
          countryName: findCountryByCode(trip.countryCode)?.name,
          placeCount: places,
          dayCount: days,
        ),
      );
    } catch (e) {
      debugPrint('_showTripQr: $e');
      if (mounted) {
        AppToast.error(
            context, 'Could not open the QR code. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _openingQr = false);
    }
  }

  Future<void> _refreshPermissions() async {
    // Invalidate permission providers to force re-fetch from database
    ref.invalidate(hasWriteAccessProvider(widget.trip.id));
    ref.invalidate(isTripOwnerProvider(widget.trip.id));
    ref.invalidate(userTripPermissionProvider(widget.trip.id));

    // Also invalidate location data to refresh the list
    ref.invalidate(locationRepositoryProvider);

    // Wait a bit for providers to refresh
    await Future.delayed(const Duration(milliseconds: 500));
  }

  @override
  Widget build(BuildContext context) {
    // Initialize collaborator realtime listener (handles permission updates and removal)
    ref.watch(collaboratorRealtimeInitProvider);

    // Check if current user is the owner
    final isOwnerAsync = ref.watch(isTripOwnerProvider(widget.trip.id));
    final hasWriteAccessAsync =
        ref.watch(hasWriteAccessProvider(widget.trip.id));

    return Stack(
      children: [
        // Ambient rotating globe behind the page (see-through cards + a
        // transparent app bar let it show, matching the home screen).
        Positioned.fill(
          child: ColoredBox(
            color: Theme.of(context).scaffoldBackgroundColor,
            child: const RotatingGlobeBackground(),
          ),
        ),
        Scaffold(
          backgroundColor: Colors.transparent,
          appBar: _selectionMode
              ? AppBar(
                  elevation: 0,
                  backgroundColor: Theme.of(context)
                      .colorScheme
                      .primary
                      .withValues(alpha: 0.08),
                  leading: IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: _exitSelectionMode,
                  ),
                  title: Text(
                    '${_selectedIds.length} selected',
                    style: Theme.of(context)
                        .textTheme
                        .headlineSmall
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  actions: [
                    // Tristate checkbox: null=some, true=all, false=none
                    Checkbox(
                      tristate: true,
                      value: _selectedIds.isEmpty
                          ? false
                          : _selectedIds.length == _currentTripLocations.length
                              ? true
                              : null,
                      onChanged: (_) {
                        if (_selectedNotifier.state.length ==
                            _currentTripLocations.length) {
                          _selectedNotifier.state = {};
                        } else {
                          _selectedNotifier.state = {
                            for (final l in _currentTripLocations) l.id,
                          };
                        }
                      },
                    ),
                    if (_selectedIds.isNotEmpty)
                      Consumer(builder: (context, ref, _) {
                        final hasWriteAccess = ref.watch(
                            hasWriteAccessProvider(widget.trip.id)
                                .select((a) => a.valueOrNull ?? false));
                        return buildPlaceSelectionMenu(
                          context,
                          ref,
                          hasWriteAccess: hasWriteAccess,
                          // Per-row past-day rules live on the cards; a
                          // bulk edit of an ended trip's leftovers must
                          // stay possible.
                          canEdit: hasWriteAccess,
                          promptContext: this.context,
                          beforeAction: _ensureMapTrip,
                        );
                      }),
                  ],
                )
              : AppBar(
                  elevation: 0,
                  backgroundColor: Colors.transparent,
                  leading: IconButton(
                    icon: const Icon(Icons.arrow_back_rounded),
                    onPressed: () => Navigator.pop(context),
                  ),
                  title: Text(
                    widget.trip.name,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  actions: [
                    // Export the whole itinerary — a PDF to read, a CSV to
                    // work with (every member can; both only read the plan).
                    PopupMenuButton<String>(
                      key: _exportButtonKey,
                      tooltip: 'Export',
                      enabled: !_exportingItinerary,
                      icon: _exportingItinerary
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2.2),
                            )
                          : const Icon(Icons.ios_share_outlined),
                      onSelected: (value) =>
                          value == 'pdf' ? _exportItinerary() : _exportCsv(),
                      itemBuilder: (_) => const [
                        PopupMenuItem(
                          value: 'pdf',
                          child: ListTile(
                            leading: Icon(Icons.picture_as_pdf_outlined),
                            title: Text('Itinerary PDF'),
                          ),
                        ),
                        PopupMenuItem(
                          value: 'csv',
                          child: ListTile(
                            leading: Icon(Icons.table_chart_outlined),
                            title: Text('Trip CSV'),
                          ),
                        ),
                      ],
                    ),
                    // Auto-plan: cluster → order cities → spread across
                    // days, for any trip with 2+ places (the planner works
                    // on the map trip's state, so opening it makes this the
                    // map trip first). Badge dot when the trip clearly
                    // needs it (bucket rows, or an overloaded day) — known
                    // only for the trip on the map.
                    Consumer(builder: (context, ref, _) {
                      final placeCount = ref.watch(tripCardStatsProvider
                          .select((m) => m[widget.trip.id]?.count ?? 0));
                      if (placeCount < 2) return const SizedBox.shrink();
                      final isMapTrip = ref.watch(localActiveTripIdProvider) ==
                          widget.trip.id;
                      final needsAttention = isMapTrip &&
                          ref.watch(tripNeedsPlanAttentionProvider);
                      return IconButton(
                        tooltip: 'Plan',
                        onPressed: _openAutoPlan,
                        icon: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            const Icon(Icons.auto_awesome_rounded),
                            if (needsAttention)
                              Positioned(
                                right: -2,
                                top: -2,
                                child: Container(
                                  width: 8,
                                  height: 8,
                                  decoration: const BoxDecoration(
                                    color: Color(0xFFFFB300),
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      );
                    }),
                    // Team members button - only visible to trip owner.
                    // Guests see it too (they own their local trips), but
                    // tapping it prompts sign-up: collaboration needs an
                    // account, and hiding the button would keep guests from
                    // ever learning the feature exists.
                    isOwnerAsync.when(
                      data: (isOwner) => isOwner
                          ? IconButton(
                              icon: const Icon(Icons.group_outlined),
                              tooltip: 'Travel buddies',
                              onPressed: () {
                                if (ref.read(currentUserIdProvider) == null) {
                                  showSignUpRequiredSheet(
                                    context,
                                    icon: Icons.group_add_rounded,
                                    title: 'Sign up to invite travel buddies',
                                    message: 'Trip collaboration needs a free '
                                        'account — your buddies get live '
                                        'access, and every change syncs to '
                                        'everyone instantly. This trip stays '
                                        'on your device and comes with you '
                                        'when you sign up.',
                                  );
                                  return;
                                }
                                _showCollaboratorsSheet();
                              },
                            )
                          : const SizedBox.shrink(),
                      loading: () => const SizedBox.shrink(),
                      error: (_, __) => const SizedBox.shrink(),
                    ),
                  ],
                ),
          bottomNavigationBar: _selectionMode
              ? SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                    child: FilledButton.icon(
                      style:
                          FilledButton.styleFrom(backgroundColor: Colors.red),
                      onPressed: _selectedIds.isEmpty ? null : _deleteSelected,
                      icon: const Icon(Icons.delete_outline),
                      label: Text(
                          'Delete ${_selectedIds.length} location${_selectedIds.length == 1 ? '' : 's'}'),
                    ),
                  ),
                )
              : null,
          body: RefreshIndicator(
            onRefresh: _refreshPermissions,
            child: Column(
              children: [
                // Search bar
                _buildSearchBar(),
                // Locations list. Pass write-access down so drag-to-move handles
                // and drop targets are only enabled for users who can edit.
                Expanded(
                  child: _buildLocationStreamBody(
                    hasWriteAccess:
                        hasWriteAccessAsync.whenOrNull(data: (v) => v) ?? false,
                  ),
                ),
              ],
            ),
          ),
          floatingActionButton: _selectionMode
              ? null
              : hasWriteAccessAsync.when(
                  data: (hasWriteAccess) => hasWriteAccess
                      // Single glowing Add Location FAB — the old secondary
                      // "Add Existing" entry confused more than it helped.
                      ? StaticGlow(
                          shape: BoxShape.rectangle,
                          borderRadius: BorderRadius.circular(16),
                          glowColor: Theme.of(context).colorScheme.primary,
                          child: FloatingActionButton.extended(
                            key: _addLocationFabKey,
                            heroTag: 'fab_add_location',
                            onPressed: () => _showAddLocationDialog(),
                            icon: const Icon(Icons.add_location_alt_outlined),
                            label: const Text('Add Location'),
                            backgroundColor:
                                Theme.of(context).colorScheme.primary,
                            foregroundColor: Colors.black,
                          ),
                        )
                      : null,
                  loading: () => null,
                  error: (_, __) => null,
                ),
        ),
        // Floating step-2 progress badge (checklist): visible only while
        // "add places" is the active goal — the checklist lives on home,
        // so this is the on-screen definition of done.
        Positioned(
          top: MediaQuery.of(context).padding.top + kToolbarHeight + 6,
          left: 0,
          right: 0,
          child: Center(
            child: AddLocationsProgressBadge(
                count: ref.watch(checklistProvider).locCount),
          ),
        ),
      ],
    );
  }

  void _showCollaboratorsSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      // Light barrier so the page stays visible behind the glass sheet.
      barrierColor: AppTheme.sheetBarrierColor(context),
      builder: (context) => CollaboratorsSheet(
        tripId: widget.trip.id,
        tripName: widget.trip.name,
      ),
    );
  }

  /// The fixed row above the list: search, then the page's ways out — to
  /// the map, and to someone else (as a QR card or as a link). Fixed, not
  /// in the scrolling card, so they stay in reach however far down the plan
  /// the page is (an ongoing trip opens scrolled to today).
  Widget _buildSearchBar() {
    final isOwner =
        ref.watch(isTripOwnerProvider(widget.trip.id)).valueOrNull ?? false;
    // Owners can always share (publishing first if needed); anyone else
    // only once the trip is public.
    final canShare = isOwner || (_trip.isPublic && _trip.shareCode != null);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Expanded(child: _buildSearchField()),
          const SizedBox(width: 8),
          _buildPageAction(
            icon: Icons.map_rounded,
            tooltip: 'Open on map',
            emphasized: true,
            busy: _openingMap,
            onPressed: _openOnMap,
          ),
          if (canShare) ...[
            const SizedBox(width: 8),
            _buildPageAction(
              icon: Icons.qr_code_2_rounded,
              tooltip: 'Trip QR code',
              busy: _openingQr,
              onPressed: _showTripQr,
            ),
            const SizedBox(width: 8),
            _buildPageAction(
              key: _shareButtonKey,
              icon: Icons.ios_share_rounded,
              tooltip: 'Share this trip',
              busy: _sharingLink,
              onPressed: _shareTripLink,
            ),
          ],
        ],
      ),
    );
  }

  /// One square button of the search row, as tall as the search field.
  /// [emphasized] tints it with the primary colour (the map is the page's
  /// main way onward).
  Widget _buildPageAction({
    Key? key,
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
    bool emphasized = false,
    bool busy = false,
  }) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final radius = BorderRadius.circular(12);
    return Tooltip(
      message: tooltip,
      child: Material(
        key: key,
        color: emphasized ? primary.withValues(alpha: 0.16) : theme.cardColor,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(
            color: emphasized
                ? primary.withValues(alpha: 0.5)
                : theme.dividerColor.withValues(alpha: 0.3),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: busy ? null : onPressed,
          child: Semantics(
            button: true,
            label: tooltip,
            child: SizedBox(
              width: 48,
              height: 48,
              child: Center(
                child: busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2.2),
                      )
                    : Icon(
                        icon,
                        size: 22,
                        color:
                            emphasized ? primary : theme.colorScheme.onSurface,
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSearchField() {
    return LayoutBuilder(
      builder: (context, constraints) => _buildSearchInput(
        // Beside three buttons a narrow phone leaves room for one word.
        hint: constraints.maxWidth < 230 ? 'Search' : 'Search locations...',
      ),
    );
  }

  Widget _buildSearchInput({required String hint}) {
    return TextField(
      cursorOpacityAnimates: false,
      controller: _searchController,
      decoration: InputDecoration(
        hintText: hint,
        prefixIcon: const Icon(Icons.search),
        suffixIcon: _searchQuery.isNotEmpty
            ? IconButton(
                icon: const Icon(Icons.clear),
                onPressed: () {
                  _searchController.clear();
                  setState(() => _searchQuery = '');
                },
              )
            : null,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: Theme.of(context).dividerColor,
          ),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: Theme.of(context).dividerColor.withValues(alpha: 0.3),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: Theme.of(context).colorScheme.primary,
            width: 2,
          ),
        ),
        filled: true,
        fillColor: Theme.of(context).cardColor,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 12,
        ),
      ),
      onChanged: (value) {
        setState(() => _searchQuery = value.toLowerCase());
      },
    );
  }

  Widget _buildLocationStreamBody({required bool hasWriteAccess}) {
    return StreamBuilder<List<SavedLocation>>(
      stream: _locationsStream,
      initialData: const [],
      builder: (context, snapshot) {
        debugPrint(
            'Trip details - Stream state: ${snapshot.connectionState}, hasData: ${snapshot.hasData}, data length: ${snapshot.data?.length ?? 0}');

        // Handle connection states
        if (snapshot.connectionState == ConnectionState.waiting &&
            snapshot.data == null) {
          return const Center(child: CircularProgressIndicator());
        }

        // Handle errors
        if (snapshot.hasError) {
          debugPrint('Stream error: ${snapshot.error}');
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Error loading locations: ${snapshot.error}'),
            ),
          );
        }

        // Get data safely
        final allLocations = snapshot.data ?? const [];

        // Filter by trip ID
        var tripLocations =
            allLocations.where((loc) => loc.tripId == widget.trip.id).toList();

        // Checklist step 2 progress: report this trip's live count (marks
        // the step at 3). Post-frame — never mutate providers during build —
        // and only when the count actually changed.
        final checklistCount = tripLocations.length;
        if (checklistCount != _lastReportedChecklistCount) {
          _lastReportedChecklistCount = checklistCount;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              ref
                  .read(checklistProvider.notifier)
                  .reportTripLocationCount(checklistCount);
            }
          });
        }

        // Apply search filter if query is not empty
        if (_searchQuery.isNotEmpty) {
          tripLocations = tripLocations
              .where((loc) => matchesSearchQuery(loc.name, _searchQuery))
              .toList();
          // A search with no hits keeps the plain empty state — day slots
          // full of empty groups would read as "no results" badly.
          if (tripLocations.isEmpty) return _buildEmptyState(false);
        }

        debugPrint('Trip details - Trip ID: ${widget.trip.id}');
        debugPrint(
            'Trip details - Filtered locations: ${tripLocations.length}');

        // NO empty-list early return here: a trip with a date range but no
        // locations yet must still render its per-day slots (with the
        // per-date add affordances). _buildLocationsList falls back to the
        // empty state itself when the trip has no dates either.

        // Keep a reference so the selection-mode AppBar can select all.
        // Compare by CONTENT: `tripLocations` is a fresh list every build,
        // so the old identity check was always true and its post-frame
        // setState re-ran this build on every frame — the whole screen
        // rendered at ~48 fps / 62 % CPU while idle (measured). The field
        // is updated in place for the body; the post-frame setState exists
        // only to refresh the AppBar's select-all state on a real change.
        if (!_sameLocationIds(_currentTripLocations, tripLocations)) {
          _currentTripLocations = tripLocations;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() {});
          });
        }

        return _buildLocationsList(tripLocations,
            hasWriteAccess: hasWriteAccess);
      },
    );
  }

  /// Normalizes a [DateTime] to midnight local time so two timestamps from
  /// the same calendar day compare equal.
  DateTime _dayKey(DateTime d) => DateTime(d.year, d.month, d.day);

  /// True when [day] is a calendar day strictly before today. Drives the
  /// past tense of folded day summaries only — places CAN be added to past
  /// days (logging where you actually went), so this no longer gates the
  /// add affordances.
  bool _isPastDay(DateTime day) =>
      _dayKey(day).isBefore(_dayKey(DateTime.now()));

  /// Day labels for this trip: "Day N" while it has no dates yet.
  DayLabeler get _labeler => DayLabeler.forTrip(_trip);

  /// True once the trip's last day has passed. An ended trip keeps its
  /// dates: no rescheduling, no adding or removing days — but places can
  /// still be added to the days it had.
  bool get _tripEnded {
    final last = _trip.endDate ?? _trip.startDate;
    return last != null && _dayKey(last).isBefore(_dayKey(DateTime.now()));
  }

  /// "No Date" on a dated trip (owner): the dates come off, the days stay
  /// as Day 1 … N with every place in place.
  Future<void> _clearTripDates() async {
    final trip = _trip;
    final start = trip.startDate;
    final end = trip.endDate ?? start;
    final days = start == null || end == null
        ? null
        : daySpanDays(dayKey(start), dayKey(end)) + 1;
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Switch to No Date?'),
        content: Text(
          'The dates come off "${trip.name}". '
          '${days == null ? 'Its days' : 'Its $days ${days == 1 ? 'day stays' : 'days stay'}'} '
          'as Day 1${days == null || days == 1 ? '' : ' – Day $days'} with '
          'every place where it is, and you can set new dates any time.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Switch'),
          ),
        ],
      ),
    );
    if (proceed != true || !mounted) return;
    try {
      final updated = await TripDatesService.clearDates(ref, trip);
      if (!mounted) return;
      setState(() => _tripOverride = updated);
      AppToast.success(context, '"${trip.name}" has no dates now');
    } catch (e) {
      debugPrint('_clearTripDates: $e');
      if (mounted) {
        AppToast.error(context, 'Couldn\'t remove the dates — try again.');
      }
    }
  }

  /// "Set dates" on a trip planned without them (owner): Day 1 lands on
  /// the picked day and every place keeps its day number.
  Future<void> _setTripDates() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final picked = await showDatePicker(
      context: context,
      initialDate: today,
      firstDate: today,
      lastDate: DateTime(today.year + 5),
      helpText: 'First day of the trip',
    );
    if (picked == null || !mounted) return;
    try {
      final updated = await TripDatesService.setStartDate(ref, _trip, picked);
      if (!mounted) return;
      setState(() => _tripOverride = updated);
      final fmt = DateFormat('MMM d');
      AppToast.success(
          context,
          'Dates set — ${fmt.format(updated.startDate!)} to '
          '${fmt.format(updated.endDate!)}');
    } catch (e) {
      debugPrint('_setTripDates: $e');
      if (mounted) {
        AppToast.error(context, 'Couldn\'t set the dates — try again.');
      }
    }
  }

  /// A trip shared with this user reaches the page from a list that carries
  /// only some of its columns, and the owner's arrival and departure times
  /// are not among them. Read them from the trip itself (members may) so
  /// the page shows what the owner set. Own and guest trips arrive whole.
  Future<void> _loadSharedTripTimes() async {
    final me = ref.read(currentUserIdProvider);
    if (me == null || me == widget.trip.userId) return;
    try {
      final whole =
          await ref.read(tripRepositoryProvider).getTripById(widget.trip.id);
      if (!mounted || whole == null) return;
      if (whole.arrivalMinute == _trip.arrivalMinute &&
          whole.departureMinute == _trip.departureMinute) {
        return;
      }
      setState(() => _tripOverride = _trip.copyWith(
            arrivalMinute: whole.arrivalMinute,
            departureMinute: whole.departureMinute,
          ));
    } catch (e) {
      debugPrint('_loadSharedTripTimes: $e');
    }
  }

  /// Opens the arrival / departure sheet (owner). The two times are part of
  /// the trip, so the page's copy of it follows every save. [add] opens the
  /// clock for that time at once (the "Add arrival time" line on a day).
  void _openTripTimes({TripTimeField? add}) {
    showTripTimesSheet(
      context,
      trip: _trip,
      openClockFor: add,
      onChanged: (changed) {
        if (!mounted) return;
        setState(() => _tripOverride = _trip.copyWith(
              arrivalMinute: changed.arrivalMinute,
              departureMinute: changed.departureMinute,
            ));
      },
    );
  }

  /// The trip's arrival and departure times in the header card. The owner
  /// sets them from here (or from the first / last day below); everyone
  /// else on the trip sees them once they are set. A trip that is over
  /// keeps what it has.
  Widget _buildTripTimesRow() {
    return Consumer(builder: (context, ref, _) {
      final isOwner =
          ref.watch(isTripOwnerProvider(widget.trip.id)).valueOrNull ?? false;
      return TripTimesHeaderRow(
        trip: _trip,
        canEdit: isOwner && !_tripEnded,
        onEdit: _openTripTimes,
      );
    });
  }

  /// Under the trip's first day: when the traveller arrives. Under its
  /// last: when they leave. See [TripDayTimeLines].
  List<Widget> _buildDayTimeLines(DateTime day) {
    if (!TripDayTimeLines.appliesTo(_trip, day)) return const [];
    return [
      Consumer(builder: (context, ref, _) {
        final isOwner =
            ref.watch(isTripOwnerProvider(widget.trip.id)).valueOrNull ?? false;
        return TripDayTimeLines(
          trip: _trip,
          day: day,
          canEdit: isOwner && !_tripEnded,
          // A time not set yet: straight to the clock. One that is set:
          // the sheet, where it can be changed or removed.
          onEdit: (field) {
            final isSet = field == TripTimeField.arrival
                ? _trip.arrivalMinute != null
                : _trip.departureMinute != null;
            _openTripTimes(add: isSet ? null : field);
          },
        );
      }),
    ];
  }

  bool _busyRollover = false;

  /// Owner toggle for "carry unvisited places forward". Persists on the
  /// trip, then — when switched ON — runs the carry-over immediately so the
  /// effect is visible right away instead of at the next launch.
  Future<void> _setAutoRoll(bool enabled) async {
    if (_busyRollover) return;
    setState(() => _busyRollover = true);
    try {
      final updated = await ref
          .read(tripRepositoryProvider)
          .updateTrip(_trip.id, autoRollUnvisited: enabled);
      ref.invalidate(userTripsProvider);
      if (!mounted) return;
      setState(() => _tripOverride = updated);
      if (enabled) {
        final notice = await TripRolloverService.rollNow(ref, updated);
        if (!mounted) return;
        AppToast.success(
          context,
          notice == null
              ? 'On — unvisited places will move to the current day.'
              : notice.message,
          duration: notice == null ? null : const Duration(seconds: 5),
        );
      } else {
        AppToast.info(context, 'Off — places stay on their planned day.');
      }
    } catch (e) {
      if (mounted) {
        AppToast.error(context, 'Couldn\'t update this setting. $e');
      }
    } finally {
      if (mounted) setState(() => _busyRollover = false);
    }
  }

  /// Ongoing trip: open on today. Runs once per screen life, after the
  /// first frame that laid the day list out.
  void _scheduleAutoScrollToToday() {
    if (_didAutoScrollToToday) return;
    _didAutoScrollToToday = true;
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _autoScrollToToday(attempt: 0));
  }

  /// The day list is a lazy sliver: today's section doesn't exist until it
  /// is near the viewport, so `ensureVisible` alone can't reach it. Page
  /// the list down until the keyed section is built, then align it just
  /// under the header. Bounded so a missing key can never loop forever.
  void _autoScrollToToday({required int attempt}) {
    if (!mounted || !_listScrollController.hasClients) return;
    final ctx = _todayDayKey.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.02,
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOutCubic,
      );
      return;
    }
    final pos = _listScrollController.position;
    if (attempt >= 40 || pos.pixels >= pos.maxScrollExtent - 1) return;
    _listScrollController.jumpTo(math.min(
        pos.pixels + pos.viewportDimension * 0.9, pos.maxScrollExtent));
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _autoScrollToToday(attempt: attempt + 1));
  }

  /// Builds the full, gap-free list of dates to display: the contiguous span
  /// from the earliest to the latest date the trip touches — the trip's
  /// declared start..end range unioned with every scheduled location — with
  /// every in-between day filled in. That guarantees an empty interstitial
  /// day (e.g. Jan 2 between stops on Jan 1 and Jan 3) still gets a drop
  /// slot, even when the trip has no explicit date range. Sorted
  /// chronologically. See [contiguousTripDates] — the same helper drives the
  /// trip-plan bottom sheet so both surfaces show identical days.
  List<DateTime> _buildAllDates(List<SavedLocation> locations) {
    return contiguousTripDates([
      _trip.startDate,
      _trip.endDate,
      // Unscheduled rows (null dates) don't stretch the axis — they render
      // in the Unscheduled section, not on a day. Nulls are skipped.
      for (final loc in locations) ...[
        loc.scheduledDate,
        loc.scheduledEndDate,
      ],
    ]);
  }

  Widget _buildLocationsList(
    List<SavedLocation> locations, {
    required bool hasWriteAccess,
  }) {
    // Group locations by every day they cover. Multi-day stays show up on
    // each day in their `[scheduledDate..scheduledEndDate]` range — same
    // SavedLocation instance reused across day groups so edits/drag still
    // work via id.
    // An ended trip's leftovers (never done, never skipped) leave their
    // days for the "Not visited" panel above the list.
    final unvisited = _tripEnded
        ? unvisitedPlaces([for (final l in locations) l.toLocationModel()])
        : const <LocationModel>[];
    final unvisitedIds = {for (final p in unvisited) p.id};
    final unvisitedRows =
        locations.where((l) => unvisitedIds.contains(l.id)).toList();

    final groupedByDay = <DateTime, List<SavedLocation>>{};
    final unscheduled = <SavedLocation>[];
    for (final location in locations) {
      if (unvisitedIds.contains(location.id)) continue;
      final startRaw = location.scheduledDate;
      if (startRaw == null) {
        // No date = the trip's Unscheduled bucket, rendered as its own
        // section above the day list.
        unscheduled.add(location);
        continue;
      }
      final start = _dayKey(startRaw);
      final endRaw = location.scheduledEndDate ?? startRaw;
      final end = _dayKey(endRaw);
      // Step by calendar day (not Duration(days:1)) so keys stay on local
      // midnight across DST transitions and match _buildAllDates' slots.
      for (var d = start;
          !d.isAfter(end);
          d = DateTime(d.year, d.month, d.day + 1)) {
        groupedByDay.putIfAbsent(d, () => []).add(location);
      }
    }

    // Newest added first in every list on the page: what was just added is
    // the first card under its header. A day's header can flip that day to
    // oldest first.
    unscheduled.sort(newestAddedFirst);
    for (final group in groupedByDay.values) {
      group.sort(newestAddedFirst);
    }

    final allDates = _buildAllDates(locations);

    // Ongoing trip = it has started and today is on or before its last day.
    // Only then does every day except today fold up (the page opens on
    // "now", with the rest a tap away); on a finished trip EVERY day is
    // past, and folding them all would hide the whole memory of the trip.
    final today = _dayKey(DateTime.now());
    final tripOngoing = allDates.isNotEmpty &&
        allDates.first.isBefore(today) &&
        !allDates.last.isBefore(today);
    if (tripOngoing && _searchQuery.isEmpty) _scheduleAutoScrollToToday();

    // If the trip has no date range AND no locations anywhere (days or the
    // Unscheduled bucket), fall back to the standard empty state below the
    // trip info card.
    if (allDates.isEmpty && unscheduled.isEmpty) {
      return Column(
        children: [
          _buildTripInfoSection(),
          Expanded(child: _buildEmptyState(false)),
        ],
      );
    }

    return CustomScrollView(
      key: _listViewportKey,
      controller: _listScrollController,
      slivers: [
        // Endorsement: how many people copied this trip — social proof for
        // the OWNER only, and only once it's non-zero (a "0 travelers"
        // badge would read as the opposite of an endorsement). Guests'
        // local trips can never be copied, so the count gate covers them.
        SliverToBoxAdapter(child: _buildCopyEndorsement()),
        SliverToBoxAdapter(
          child: _buildTripInfoSection(),
        ),
        if (unvisited.isNotEmpty)
          SliverToBoxAdapter(
            child: _buildUnvisitedSection(
              unvisited,
              rows: unvisitedRows,
              hasWriteAccess: hasWriteAccess,
            ),
          ),
        // Places that belong to the trip but sit on NO day. Rendered above
        // the day list so leftovers are impossible to miss; each card can
        // be dragged onto any day below (or scheduled via its own sheet).
        if (unscheduled.isNotEmpty)
          SliverToBoxAdapter(
            child: _buildUnscheduledSection(
              unscheduled,
              hasWriteAccess: hasWriteAccess,
            ),
          ),
        SliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) {
              if (index == allDates.length) {
                return _buildAddDayTile(allDates);
              }
              final day = allDates[index];
              final dateGroup = groupedByDay[day] ?? const <SavedLocation>[];
              final section = _buildDateSection(
                day,
                dateGroup,
                hasWriteAccess: hasWriteAccess,
                tripOngoing: tripOngoing,
              );
              // Keyed so the ongoing-trip landing can scroll to it.
              return day == today
                  ? KeyedSubtree(key: _todayDayKey, child: section)
                  : section;
            },
            childCount: allDates.length +
                ((hasWriteAccess && _searchQuery.isEmpty && !_tripEnded)
                    ? 1
                    : 0),
          ),
        ),
        // Bottom padding sized to clear the two stacked extended FABs
        // (~56pt each + 12pt gap + 16pt scaffold margin + SafeArea bottom).
        // Without this the last expanded photo card disappears behind the
        // floating buttons.
        const SliverPadding(padding: EdgeInsets.only(bottom: 200)),
      ],
    );
  }

  Widget _buildEmptyState(bool isLoading) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (!isLoading)
            Icon(
              Icons.location_off_rounded,
              size: 64,
              color: Theme.of(context).colorScheme.primary.withOpacity(0.3),
            ),
          const SizedBox(height: 16),
          Text(
            'No locations added yet',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            'Start adding locations to this trip',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.color
                      ?.withOpacity(0.6),
                ),
          ),
        ],
      ),
    );
  }

  Widget _buildCopyEndorsement() {
    final theme = Theme.of(context);
    final count = widget.trip.copyCount;
    final isOwner =
        ref.watch(isTripOwnerProvider(widget.trip.id)).valueOrNull ?? false;
    if (!isOwner || count <= 0) return const SizedBox.shrink();

    const gold = Color(0xFFF5A623);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          gradient: LinearGradient(
            colors: [
              gold.withValues(alpha: 0.16),
              gold.withValues(alpha: 0.05),
            ],
          ),
          border: Border.all(color: gold.withValues(alpha: 0.45)),
        ),
        child: Row(
          children: [
            const Icon(Icons.favorite_rounded, color: gold, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: '$count traveler${count == 1 ? '' : 's'} ',
                      style: const TextStyle(
                          color: gold, fontWeight: FontWeight.w800),
                    ),
                    TextSpan(
                      text: 'loved this trip and made it their own',
                    ),
                  ],
                ),
                style: theme.textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w500),
              ),
            ),
            const Icon(Icons.auto_awesome_rounded, color: gold, size: 16),
          ],
        ),
      ),
    );
  }

  /// Publish / unpublish from the trip page. Confirms first (publishing is
  /// privacy-affecting; unpublishing revokes every code holder). The server
  /// mints the code on first publish and keeps it across re-publishes.
  ///
  /// Returns whether the change was made. [announce] false skips the toast
  /// (the share button opens the share sheet instead).
  Future<bool> _setTripPublished(bool goPublic, {bool announce = true}) async {
    final trip = _trip;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(goPublic ? 'Make this trip public?' : 'Make it private?'),
        content: Text(
          goPublic
              ? 'You\'ll get a share link and code. Anyone with either '
                  'can copy "${trip.name}" as their own trip — they never see your '
                  'name, your edits, or your progress, and you can turn '
                  'this off any time.'
              : 'People who have your link or code will no longer be able '
                  'to copy this trip, and itinerary links sent with route '
                  'cards stop working. Making it public again restores the '
                  'same link and code.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(goPublic ? 'Publish' : 'Go private'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return false;
    try {
      final code = await ref
          .read(tripRepositoryProvider)
          .setTripPublic(trip.id, goPublic);
      ref.invalidate(userTripsProvider);
      if (!mounted) return false;
      setState(() {
        _tripOverride = trip.copyWith(
          isPublic: goPublic,
          shareCode: goPublic ? (code ?? trip.shareCode) : trip.shareCode,
        );
      });
      if (announce) {
        AppToast.success(
            context,
            goPublic
                ? 'Trip published — tap the code to copy it'
                : 'Trip is private again');
      }
      return true;
    } catch (e) {
      debugPrint('setTripPublic failed: $e');
      if (mounted) {
        AppToast.error(
            context, 'Could not update sharing. Check your connection.');
      }
      return false;
    }
  }

  /// The info card, then (signed-in owner, nobody invited yet) the
  /// travel-buddy nudge — the wizard's buddies step lives here now.
  Widget _buildTripInfoSection() {
    return Column(
      children: [
        _buildTripInfoCard(),
        BuddyNudgeRow(
          tripId: widget.trip.id,
          ownerId: widget.trip.userId,
          onInvite: _showCollaboratorsSheet,
        ),
      ],
    );
  }

  Widget _buildTripInfoCard() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
            width: 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Icon(
                  Icons.trip_origin_rounded,
                  size: 18,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.trip.name,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            if (_trip.startDate != null && _trip.endDate != null) ...[
              const SizedBox(height: 10),
              Consumer(builder: (context, ref, _) {
                final s = dayKey(_trip.startDate!);
                final e = dayKey(_trip.endDate!);
                final dayCount = daySpanDays(s, e) + 1;
                final undated = _trip.isUndated;
                final dateText = undated
                    ? 'No dates yet'
                    : s == e
                        ? DateFormat('MMM d, y').format(s)
                        : '${DateFormat('MMM d').format(s)} - ${DateFormat('MMM d, y').format(e)}';
                final isOwner = ref
                        .watch(isTripOwnerProvider(widget.trip.id))
                        .valueOrNull ??
                    false;
                return Row(
                  children: [
                    Icon(
                      undated
                          ? Icons.event_note_rounded
                          : Icons.calendar_today_rounded,
                      size: 14,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '$dateText  ·  $dayCount day${dayCount == 1 ? '' : 's'}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context).colorScheme.primary,
                              fontWeight: FontWeight.w600,
                            ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    // Owner: give an undated trip dates (Day 1 lands on the
                    // picked day), or take a dated trip's dates off (its
                    // days stay as Day 1 … N). An ended trip keeps its
                    // dates.
                    if (isOwner && undated)
                      TextButton.icon(
                        onPressed: _setTripDates,
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          minimumSize: const Size(0, 30),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        icon:
                            const Icon(Icons.event_available_rounded, size: 16),
                        label: const Text('Set dates'),
                      )
                    else if (isOwner && !_tripEnded)
                      TextButton.icon(
                        onPressed: _clearTripDates,
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          minimumSize: const Size(0, 30),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        icon: const Icon(Icons.event_busy_rounded, size: 16),
                        label: const Text('No Date'),
                      ),
                  ],
                );
              }),
              _buildTripTimesRow(),
            ],
            // ── Carry unvisited places forward (owner, dated trips only) ──
            if (_trip.startDate != null &&
                _trip.endDate != null &&
                !_trip.isUndated)
              Consumer(builder: (context, ref, _) {
                final isOwner = ref
                        .watch(isTripOwnerProvider(widget.trip.id))
                        .valueOrNull ??
                    false;
                if (!isOwner) return const SizedBox.shrink();
                final theme = Theme.of(context);
                final on = _trip.autoRollUnvisited;
                return Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Icon(Icons.update_rounded,
                          size: 16, color: theme.colorScheme.primary),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Carry unvisited places forward',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.primary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              'Each new day, places you didn\'t visit move '
                              'to today. A place already planned that day '
                              'stays where it is.',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Switch.adaptive(
                        value: on,
                        onChanged: _busyRollover ? null : _setAutoRoll,
                      ),
                    ],
                  ),
                );
              }),
            // ── Sharing: publish for copy-by-code; the code (tap to copy)
            // once public. Owner-only and signed-in (the RPC enforces both).
            Consumer(builder: (context, ref, _) {
              final signedIn = ref.watch(currentUserIdProvider) != null;
              final isOwner =
                  ref.watch(isTripOwnerProvider(widget.trip.id)).valueOrNull ??
                      false;
              if (!signedIn || !isOwner) return const SizedBox.shrink();
              final theme = Theme.of(context);
              final primary = theme.colorScheme.primary;
              final trip = _trip;
              final hasCode = trip.isPublic && trip.shareCode != null;
              if (!hasCode) {
                return Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Publish to get a share link and code others '
                          'can copy this trip with.',
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                              height: 1.3),
                        ),
                      ),
                      const SizedBox(width: 12),
                      OutlinedButton.icon(
                        onPressed: () => _setTripPublished(true),
                        icon: const Icon(Icons.public_rounded, size: 16),
                        label: const Text('Publish'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: primary,
                          side:
                              BorderSide(color: primary.withValues(alpha: 0.5)),
                          visualDensity: VisualDensity.compact,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                          textStyle: theme.textTheme.labelLarge
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                );
              }
              final display = 'TRIP-${trip.shareCode}';
              return Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        borderRadius: BorderRadius.circular(11),
                        onTap: () {
                          Clipboard.setData(ClipboardData(text: display));
                          AppToast.success(
                              context, 'Code copied — send it to anyone!');
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 9),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(11),
                            border: Border.all(
                                color: primary.withValues(alpha: 0.45)),
                            color: primary.withValues(alpha: 0.08),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.public_rounded,
                                  size: 16, color: primary),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  display,
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    fontFamily: 'monospace',
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 1.4,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              Icon(Icons.copy_rounded,
                                  size: 16, color: primary),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () => _setTripPublished(false),
                      style: TextButton.styleFrom(
                        foregroundColor: theme.colorScheme.onSurfaceVariant,
                        visualDensity: VisualDensity.compact,
                      ),
                      child: const Text('Go private'),
                    ),
                  ],
                ),
              );
            }),
            if (widget.trip.description != null &&
                widget.trip.description!.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                widget.trip.description!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context)
                          .textTheme
                          .bodyMedium
                          ?.color
                          ?.withValues(alpha: 0.7),
                    ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Framed, transparent "add a day" box after the last date: extends the
  /// trip's range by one day (start pinned to the current first day so
  /// location-derived ranges become explicit).
  Widget _buildAddDayTile(List<DateTime> allDates) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final last = allDates.last;
    final newDay = DateTime(last.year, last.month, last.day + 1);
    final canRemove = allDates.length > 1;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Row(
        children: [
          if (canRemove) ...[
            // Remove the last day (framed, transparent — quiet next to Add).
            Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () => _removeLastTripDay(allDates),
                child: Container(
                  height: 54,
                  width: 54,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                        color: theme.colorScheme.onSurfaceVariant
                            .withValues(alpha: 0.45),
                        width: 1.4),
                  ),
                  child: Icon(Icons.remove_rounded,
                      size: 22, color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            ),
            const SizedBox(width: 10),
          ],
          Expanded(
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () => _addTripDayAtEnd(allDates),
                child: Container(
                  height: 54,
                  decoration: BoxDecoration(
                    color: Colors.transparent,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                        color: primary.withValues(alpha: 0.5), width: 1.4),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.add_rounded, size: 20, color: primary),
                      const SizedBox(width: 8),
                      Text(
                        _labeler.tbd
                            ? 'Add ${_labeler(newDay)}'
                            : 'Add a day (${DateFormat('MMM d').format(newDay)})',
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _removeLastTripDay(List<DateTime> allDates) async {
    final range = await TripDayService.removeLastDay(
      context,
      ref,
      trip: _trip,
      days: allDates,
    );
    if (range != null && mounted) {
      setState(() {
        _tripOverride =
            _trip.copyWith(startDate: range.start, endDate: range.end);
      });
    }
  }

  Future<void> _addTripDayAtEnd(List<DateTime> allDates) async {
    final range = await TripDayService.addDayAtEnd(
      context,
      ref,
      trip: _trip,
      days: allDates,
    );
    if (range != null && mounted) {
      setState(() {
        _tripOverride =
            _trip.copyWith(startDate: range.start, endDate: range.end);
      });
    }
  }

  /// An ended trip's leftovers — the places never ticked off — with the one
  /// thing left to do about them: review (delete, or move to another trip).
  /// Red identity so it reads as a loose end, not a day.
  Widget _buildUnvisitedSection(
    List<LocationModel> unvisited, {
    required List<SavedLocation> rows,
    required bool hasWriteAccess,
  }) {
    final theme = Theme.of(context);
    const red = Color(0xFFFF5252);
    final n = unvisited.length;
    final them = n == 1 ? 'it' : 'them';
    return Padding(
      padding: const EdgeInsets.only(top: 16, left: 16, right: 16),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: red.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: red.withValues(alpha: 0.35), width: 1.2),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: red.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.flag_outlined, size: 15, color: red),
                  const SizedBox(width: 6),
                  Text(
                    'Not visited',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: red,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '$n',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: red.withValues(alpha: 0.8),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'This trip has ended with $n place${n == 1 ? '' : 's'} you '
              'never got to. Delete $them, or move $them to another trip.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 10),
            // The places themselves — same cards as a day, so each still
            // opens its sheet and carries its Options.
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0) const SizedBox(height: 8),
              _buildLocationCard(rows[i], i, rows,
                  hasWriteAccess: hasWriteAccess),
            ],
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonalIcon(
                onPressed: () => showUnvisitedPlacesSheet(context,
                    trip: _trip, places: unvisited),
                icon: const Icon(Icons.checklist_rounded, size: 18),
                label: Text(hasWriteAccess ? 'Review' : 'View'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The trip's Unscheduled bucket: places that belong to the trip but sit
  /// on no day. Mirrors [_buildDateSection]'s visual language (chip header,
  /// drop-target highlight, same cards) with an amber identity so it can't
  /// be mistaken for a day. The whole section is a [DragTarget]: dropping a
  /// dated card here clears its date (guarded — accommodations, completed
  /// places, and multi-day stays keep their days).
  Widget _buildUnscheduledSection(
    List<SavedLocation> unscheduled, {
    required bool hasWriteAccess,
  }) {
    final theme = Theme.of(context);
    const amber = Color(0xFFFFB300);

    return Padding(
      padding: const EdgeInsets.only(top: 16, left: 16, right: 16),
      child: DragTarget<SavedLocation>(
        onWillAcceptWithDetails: (details) {
          if (!hasWriteAccess) return false;
          final loc = details.data;
          // Only dated, movable rows can be un-dated by dropping here.
          return loc.scheduledDate != null &&
              !loc.isAccommodation &&
              !loc.isDone &&
              !loc.isMultiDay;
        },
        onAcceptWithDetails: (details) =>
            _moveLocationToUnscheduled(details.data),
        builder: (context, candidate, rejected) {
          final highlighted = candidate.isNotEmpty;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              color: highlighted
                  ? amber.withValues(alpha: 0.14)
                  : amber.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: highlighted ? amber : amber.withValues(alpha: 0.35),
                width: highlighted ? 2 : 1.2,
              ),
              boxShadow: highlighted
                  ? [
                      BoxShadow(
                        color: amber.withValues(alpha: 0.35),
                        blurRadius: 16,
                      ),
                    ]
                  : null,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Flexible(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: amber.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.inventory_2_outlined,
                                size: 15, color: amber),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                'Unscheduled',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.labelLarge?.copyWith(
                                  color: amber,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '${unscheduled.length}',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: amber.withValues(alpha: 0.8),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // The "I insist" path: put EVERY unscheduled place
                        // on one chosen day, no planner involved. Same-day
                        // duplicates of that day's occupants are skipped and
                        // reported, never silently dropped.
                        if (hasWriteAccess)
                          IconButton(
                            onPressed: () =>
                                _scheduleAllUnscheduled(unscheduled),
                            icon: const Icon(Icons.event_available_rounded,
                                color: amber),
                            iconSize: 22,
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                                minWidth: 40, minHeight: 32),
                            tooltip: 'Put all on one day',
                          ),
                        // One-tap fix for the whole bucket — Auto-plan
                        // spreads these onto days (it makes this the map
                        // trip first; the planner works on that state).
                        if (hasWriteAccess)
                          TextButton.icon(
                            onPressed: _openAutoPlan,
                            icon: const Icon(Icons.auto_awesome_rounded,
                                size: 15),
                            label: const Text('Plan'),
                            style: TextButton.styleFrom(
                              foregroundColor: amber,
                              visualDensity: VisualDensity.compact,
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 8),
                            ),
                          ),
                        IconButton(
                          onPressed: () => setState(() =>
                              _unscheduledCollapsed = !_unscheduledCollapsed),
                          icon: Icon(
                            _unscheduledCollapsed
                                ? Icons.expand_more_rounded
                                : Icons.expand_less_rounded,
                            color: amber,
                          ),
                          iconSize: 22,
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints:
                              const BoxConstraints(minWidth: 40, minHeight: 32),
                          tooltip: _unscheduledCollapsed ? 'Show' : 'Hide',
                        ),
                      ],
                    ),
                  ],
                ),
                if (!_unscheduledCollapsed) ...[
                  const SizedBox(height: 4),
                  Text(
                    'On no day yet — drag each onto a day below, open a '
                    'card to schedule it, or use the buttons above to put '
                    'them all on one day or let Auto-plan spread them.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 12),
                  ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: unscheduled.length,
                    separatorBuilder: (context, index) =>
                        const SizedBox(height: 8),
                    itemBuilder: (context, index) => _buildLocationCard(
                      unscheduled[index],
                      index,
                      unscheduled,
                      hasWriteAccess: hasWriteAccess,
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  /// Bulk "put all on one day": the user picks a day and every unscheduled
  /// place lands on it — however many that is (their call; the optimizer's
  /// over-cap dialog will speak up later if it's too many to route). Runs
  /// the shared same-day duplicate guard once for the whole batch and
  /// writes through the batch path (one Hive commit, one upsert).
  Future<void> _scheduleAllUnscheduled(List<SavedLocation> rows) async {
    if (rows.isEmpty) return;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final all =
        ref.read(savedLocationsProvider).valueOrNull ?? const <SavedLocation>[];
    final tripRows = all.where((l) => l.tripId == widget.trip.id);
    final highlighted = {
      for (final l in tripRows)
        if (l.scheduledDate != null) _dayKey(l.scheduledDate!)
    };
    final DateTime? picked;
    if (_labeler.tbd) {
      picked = await showTripDayPicker(
        context,
        days: _buildAllDates(tripRows.toList()),
        labeler: _labeler,
        marked: highlighted,
        title: 'Schedule on which day?',
      );
    } else {
      // Past days of the trip are pickable too (logging where you went).
      final tripStart = _trip.startDate;
      final earliest = tripStart != null && tripStart.isBefore(today)
          ? _dayKey(tripStart)
          : today;
      picked = await DatePickerUtils.showCustomDatePicker(
        context: context,
        initialDate:
            tripStart != null && !tripStart.isBefore(today) ? tripStart : today,
        firstDate: earliest,
        lastDate: DateTime(now.year + 5),
        highlightedDates: highlighted,
      );
    }
    if (picked == null || !mounted) return;
    final day = _dayKey(picked);

    final dup = filterSameDayDuplicates(
      moving: rows.map(placeKeyOfSaved),
      occupantsOnDay: tripRows
          .where((l) =>
              l.scheduledDate != null &&
              !rows.any((r) => r.id == l.id) &&
              l.isActiveOnDate(day))
          .map(placeKeyOfSaved),
    );
    final allowed = rows.where((r) => dup.allowedIds.contains(r.id)).toList();
    if (allowed.isEmpty) {
      AppToast.warning(
          context, 'All of these are already on ${_labeler(day)}.');
      return;
    }
    try {
      await ref.read(locationRepositoryProvider).updateLocationsBatch({
        for (final r in allowed)
          r.id: {
            'scheduled_date': day.toIso8601String(),
            'scheduled_end_date': null,
          },
      });
      if (!mounted) return;
      final skipped = rows.length - allowed.length;
      AppToast.success(
        context,
        '${allowed.length} ${allowed.length == 1 ? 'place' : 'places'} '
        'scheduled on ${_labeler(day)}'
        '${skipped > 0 ? ' · $skipped already there, skipped' : ''}.',
        duration: const Duration(seconds: 4),
      );
    } catch (e) {
      debugPrint('scheduleAllUnscheduled failed: $e');
      if (!mounted) return;
      AppToast.error(context, "Couldn't schedule them. Try again.");
    }
  }

  /// Clears [location]'s date — it moves to the Unscheduled bucket but
  /// stays in the trip. Repository-direct like [_moveLocationToDate] so it
  /// works on any writable trip, active or not; RLS backstops auth.
  Future<void> _moveLocationToUnscheduled(SavedLocation location) async {
    if (location.isAccommodation) {
      AppToast.warning(context, 'Accommodations need a date.');
      return;
    }
    if (location.isDone || location.isMultiDay) {
      AppToast.info(context, 'Completed places and stays keep their days.');
      return;
    }
    try {
      await ref.read(locationRepositoryProvider).updateLocation(
        location.id,
        {'scheduled_date': null},
      );
      if (!mounted) return;
      AppToast.info(context, '"${location.name}" moved to Unscheduled.');
    } catch (e) {
      debugPrint('moveLocationToUnscheduled failed: $e');
      if (!mounted) return;
      AppToast.error(context, "Couldn't move \"${location.name}\".");
    }
  }

  Widget _buildDateSection(
    DateTime day,
    List<SavedLocation> locations, {
    required bool hasWriteAccess,
    bool tripOngoing = false,
  }) {
    final labeler = _labeler;
    final dateLabel =
        labeler.tbd ? labeler(day) : DateFormat('MMMM dd, yyyy').format(day);
    final theme = Theme.of(context);
    // Adding is allowed on any day, past ones included — the folded
    // summary just switches to the past tense.
    final canAddHere = hasWriteAccess;

    // Every day folds from its header (chevron on the date chip). On an
    // ONGOING trip every day but today starts folded, so the page opens on
    // the day being lived; on any other trip every day starts open. A
    // search shows everything — a hit inside a folded day would otherwise
    // look like a miss.
    final isPast = _isPastDay(day);
    final isToday = labeler.isToday(day);
    final foldable = _searchQuery.isEmpty;
    final foldedByDefault = tripOngoing && !isToday;
    // Today's header is green; every other day keeps the primary tint.
    final accent = isToday ? _todayGreen : theme.colorScheme.primary;
    final folded = foldable && (_dayFoldOverrides[day] ?? foldedByDefault);
    void toggleFold() => setState(() => _dayFoldOverrides[day] = !folded);

    // [locations] arrives newest added first (see _buildLocationsList); the
    // header's toggle flips this day to oldest first and back. Both orders
    // read createdAt — the exact value the card prints as "Added …", so the
    // order is verifiable on screen. View-only: nothing is written.
    final oldestFirst = _oldestFirstDays.contains(day);
    final displayLocations =
        oldestFirst ? locations.reversed.toList() : locations;

    return Padding(
      padding: const EdgeInsets.only(top: 16, left: 16, right: 16),
      // DragTarget around the whole day so users can drop on either the
      // header or anywhere inside the section (including the empty
      // placeholder for a day with no locations yet).
      child: DragTarget<SavedLocation>(
        onWillAcceptWithDetails: (details) {
          if (!hasWriteAccess) return false;
          // Reject re-drops onto the same day to keep highlight feedback
          // honest and avoid a no-op write. A row dragged out of the
          // Unscheduled bucket (null date) is welcome on ANY day.
          final src = details.data.scheduledDate;
          if (src == null) return true;
          return _dayKey(src) != day;
        },
        onAcceptWithDetails: (details) =>
            _moveLocationToDate(details.data, day),
        builder: (context, candidate, rejected) {
          final highlighted = candidate.isNotEmpty;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              // Unmistakable drop target: at 6% the fill was easy to miss
              // while the eye was following the dragged card.
              color: highlighted
                  ? theme.colorScheme.primary.withValues(alpha: 0.16)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: highlighted
                    ? theme.colorScheme.primary
                    : Colors.transparent,
                width: 2,
              ),
              boxShadow: highlighted
                  ? [
                      BoxShadow(
                        color:
                            theme.colorScheme.primary.withValues(alpha: 0.35),
                        blurRadius: 16,
                      ),
                    ]
                  : null,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  // spaceBetween + a grouped icon Row instead of a Spacer.
                  // A Spacer is Expanded(flex:1), so it COMPETED with the
                  // Flexible chip for free space and capped the chip at
                  // roughly half the header — truncating "October 05, 2026"
                  // to "October 05, …" with the right half sitting empty.
                  // Now the chip may use everything the icons don't.
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    // Flexible + ellipsis so a long date label at large
                    // accessibility text scales truncates instead of
                    // overflowing the header Row.
                    Flexible(
                      child: InkWell(
                        // Foldable days toggle from the date chip (and from
                        // the folded summary row below).
                        onTap: foldable ? toggleFold : null,
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color:
                                accent.withValues(alpha: isToday ? 0.22 : 0.15),
                            borderRadius: BorderRadius.circular(8),
                            border: isToday
                                ? Border.all(
                                    color: accent.withValues(alpha: 0.6),
                                    width: 1.2)
                                : null,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (foldable) ...[
                                Icon(
                                  folded
                                      ? Icons.chevron_right_rounded
                                      : Icons.expand_more_rounded,
                                  size: 18,
                                  color: accent,
                                ),
                                const SizedBox(width: 2),
                              ],
                              Flexible(
                                child: Text(
                                  dateLabel,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.labelLarge?.copyWith(
                                    color: accent,
                                    fontWeight: isToday
                                        ? FontWeight.w800
                                        : FontWeight.w600,
                                  ),
                                ),
                              ),
                              if (isToday) ...[
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 1.5),
                                  decoration: BoxDecoration(
                                    color: _todayGreen,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: const Text(
                                    'Today',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: 0.3,
                                    ),
                                  ),
                                ),
                              ],
                              if (locations.isNotEmpty) ...[
                                const SizedBox(width: 8),
                                Text(
                                  '${locations.length}',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: accent.withValues(alpha: 0.8),
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                    // Grouped so the free space lands BETWEEN the chip and
                    // the buttons, never between the buttons themselves.
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Order of this day's cards by when they were
                        // ADDED: newest first (the default — a place just
                        // added is the first card) or oldest first. The
                        // arrow points the way the dates run; it lights up
                        // when the day is off the default.
                        if (locations.length > 1 && !folded)
                          IconButton(
                            onPressed: () => setState(() {
                              if (!_oldestFirstDays.remove(day)) {
                                _oldestFirstDays.add(day);
                              }
                            }),
                            icon: Icon(
                              oldestFirst
                                  ? Icons.arrow_upward_rounded
                                  : Icons.arrow_downward_rounded,
                              color: oldestFirst
                                  ? theme.colorScheme.primary
                                  : theme.textTheme.bodyMedium?.color
                                      ?.withValues(alpha: 0.45),
                            ),
                            iconSize: 22,
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                                minWidth: 40, minHeight: 32),
                            tooltip: oldestFirst
                                ? 'Oldest added first — tap for newest first'
                                : 'Newest added first — tap for oldest first',
                          ),
                        // Per-day quick-add: adds a place already scheduled
                        // to THIS day, so empty gap days can be filled
                        // directly (past days too).
                        if (canAddHere)
                          IconButton(
                            onPressed: () => _showAddLocationForDate(day),
                            icon: Icon(Icons.add_circle_outline,
                                color: theme.colorScheme.primary),
                            iconSize: 22,
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                                minWidth: 40, minHeight: 32),
                            tooltip: 'Add a place on this day',
                          ),
                      ],
                    ),
                  ],
                ),
                ..._buildDayTimeLines(day),
                if (folded)
                  _buildFoldedDaySummary(day, locations, isPast: isPast)
                else ...[
                  const SizedBox(height: 12),
                  if (locations.isEmpty)
                    canAddHere
                        ? InkWell(
                            onTap: () => _showAddLocationForDate(day),
                            borderRadius: BorderRadius.circular(10),
                            child: _buildEmptyDayPlaceholder(
                                highlighted: highlighted, canAdd: true),
                          )
                        : _buildEmptyDayPlaceholder(highlighted: highlighted)
                  else
                    ListView.separated(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: displayLocations.length,
                      separatorBuilder: (context, index) =>
                          const SizedBox(height: 8),
                      // displayLocations everywhere (card, index, group) so
                      // the detail sheet's swipe-through order matches the
                      // screen.
                      itemBuilder: (context, index) => _buildLocationCard(
                        displayLocations[index],
                        index,
                        displayLocations,
                        day: day,
                        hasWriteAccess: hasWriteAccess,
                      ),
                    ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  /// One-line stand-in for a folded day — what's on it and a nudge that it
  /// opens on tap. Tappable itself, so the whole header area unfolds, not
  /// just the date chip. Past days read in the past tense ("was planned").
  Widget _buildFoldedDaySummary(
    DateTime day,
    List<SavedLocation> locations, {
    required bool isPast,
  }) {
    final theme = Theme.of(context);
    final n = locations.length;
    final done = locations.where((l) => l.isDone).length;
    final String summary;
    if (n == 0) {
      summary = isPast ? 'Nothing was planned' : 'Nothing planned yet';
    } else {
      final places = '$n place${n == 1 ? '' : 's'}';
      summary = done == 0
          ? places
          : done == n
              ? '$places · all done'
              : '$places · $done done';
    }
    final muted = theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.75);
    return InkWell(
      onTap: () => setState(() => _dayFoldOverrides[day] = false),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(6, 8, 6, 2),
        child: Row(
          children: [
            Icon(
              isPast ? Icons.history_rounded : Icons.unfold_more_rounded,
              size: 14,
              color: muted,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '$summary · tap to show',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyDayPlaceholder(
      {required bool highlighted, bool canAdd = false}) {
    final theme = Theme.of(context);
    final color = highlighted
        ? theme.colorScheme.primary
        : theme.dividerColor.withValues(alpha: 0.4);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color, width: 1.2),
      ),
      child: Row(
        children: [
          Icon(canAdd && !highlighted ? Icons.add : Icons.add_road_outlined,
              size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              highlighted
                  ? 'Release to move here'
                  : (canAdd
                      ? 'No places yet · tap to add or drag a card here'
                      : 'No locations · drag a card here'),
              style: theme.textTheme.bodySmall?.copyWith(
                color:
                    theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.7),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Small floating chip rendered under the user's finger while dragging a
  /// location card. Lighter than re-rendering the whole card — keeps the
  /// drop targets visible underneath.
  /// Width of the card that rides under the finger while dragging.
  static const double _dragCardWidth = 260;

  /// The dragged location rendered as a miniature of its own card, so the
  /// user is visibly carrying the card rather than a generic chip. Centred
  /// under the finger (see the anchor strategy at the Draggable) and tilted
  /// a touch so it reads as "lifted off the page".
  Widget _buildDragFeedback(SavedLocation location) {
    final theme = Theme.of(context);
    final photoRefs = location.effectivePhotoReferences;
    return Material(
      color: Colors.transparent,
      child: Transform.rotate(
        angle: -0.02,
        child: Opacity(
          opacity: 0.95,
          child: Container(
            width: _dragCardWidth,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: theme.cardColor,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: theme.colorScheme.primary.withValues(alpha: 0.9),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.45),
                  blurRadius: 20,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 44,
                    height: 44,
                    child: photoRefs.isNotEmpty
                        ? LocationPhotoThumbnail(
                            photoRef: photoRefs.first,
                            size: 44,
                          )
                        : ColoredBox(
                            color: theme.colorScheme.primary
                                .withValues(alpha: 0.15),
                            child: Icon(Icons.location_on_rounded,
                                color: theme.colorScheme.primary, size: 22),
                          ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        location.name,
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Drop on a day',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Auto-scroll while dragging ─────────────────────────────────────────
  // Draggable/DragTarget do NOT scroll the enclosing scroll view (unlike
  // ReorderableListView), so a card could never be moved to a day that was
  // off-screen. These drive the list from the drag's pointer position.

  final ScrollController _listScrollController = ScrollController();
  final GlobalKey _listViewportKey = GlobalKey();
  Timer? _autoScrollTimer;
  double? _dragPointerY;

  void _startDragAutoScroll() {
    _autoScrollTimer ??= Timer.periodic(
      const Duration(milliseconds: 16),
      (_) => _autoScrollTick(),
    );
  }

  void _stopDragAutoScroll() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
    _dragPointerY = null;
  }

  void _autoScrollTick() {
    final y = _dragPointerY;
    if (y == null || !_listScrollController.hasClients) return;
    final box =
        _listViewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;

    final top = box.localToGlobal(Offset.zero).dy;
    final bottom = top + box.size.height;
    // Hot zones at each end; speed ramps up the deeper the finger goes in.
    const zone = 130.0;
    const maxStep = 16.0;
    double delta = 0;
    if (y < top + zone) {
      delta = -maxStep * ((top + zone - y) / zone).clamp(0.0, 1.0);
    } else if (y > bottom - zone) {
      delta = maxStep * ((y - (bottom - zone)) / zone).clamp(0.0, 1.0);
    }
    if (delta == 0) return;

    final pos = _listScrollController.position;
    final target =
        (pos.pixels + delta).clamp(pos.minScrollExtent, pos.maxScrollExtent);
    if (target != pos.pixels) _listScrollController.jumpTo(target);
  }

  /// Reassigns [location] to [newDay]. Uses the repository directly (mirrors
  /// the bypass pattern in [_deleteSelected]) so the trip-details screen can
  /// edit any trip the user has write access to, not just the active one.
  /// Backend RLS still enforces auth.
  Future<void> _moveLocationToDate(
      SavedLocation location, DateTime newDay) async {
    try {
      // Captured before the write: dragging onto a previously-empty day
      // materializes a new trip day → ask about accommodation after.
      // (Active-trip data; the prompt self-skips for non-active trips.)
      final dayKey = DateTime(newDay.year, newDay.month, newDay.day);
      // Shared same-day duplicate rule: same place may repeat across days,
      // never within one day.
      final saved = ref.read(savedLocationsProvider).valueOrNull ??
          const <SavedLocation>[];
      final dup = filterSameDayDuplicates(
        moving: [placeKeyOfSaved(location)],
        occupantsOnDay: saved
            .where((l) =>
                l.tripId == widget.trip.id &&
                l.id != location.id &&
                l.scheduledDate != null &&
                l.isActiveOnDate(dayKey))
            .map(placeKeyOfSaved),
      );
      if (dup.allowedIds.isEmpty) {
        AppToast.warning(
            context, '"${location.name}" is already on ${_labeler(dayKey)}');
        return;
      }
      final dayWasEmpty = !ref
          .read(tripProvider)
          .pinnedLocations
          .any((l) => l.isActiveOnDate(dayKey));
      // Multi-day stays move WHOLE: shifting only the start left
      // start > end and the row disappeared from every day section.
      // Unscheduled rows have no span — oldStart is moot (delta zero).
      final newEnd = shiftedSpanEnd(
        oldStart: location.scheduledDate ?? newDay,
        oldEnd: location.scheduledEndDate,
        newStart: newDay,
      );
      await ref.read(locationRepositoryProvider).updateLocation(
        location.id,
        {
          'scheduled_date': newDay.toIso8601String(),
          'scheduled_end_date': newEnd?.toIso8601String(),
        },
      );
      if (!mounted) return;
      AppToast.success(
        context,
        'Moved ${location.name} to ${_labeler(newDay)}',
      );
      if (dayWasEmpty && mounted) {
        await maybePromptAccommodationForNewDays(
          context,
          ref,
          trip: widget.trip,
          newDays: [dayKey],
        );
      }
    } catch (e) {
      if (!mounted) return;
      AppToast.error(context, 'Could not move location: $e');
    }
  }

  Widget _buildLocationCard(
    SavedLocation location,
    int index,
    List<SavedLocation> dateGroup, {
    required bool hasWriteAccess,
    DateTime? day,
  }) {
    String coordAddress(SavedLocation l) =>
        '${l.lat.toStringAsFixed(5)}, ${l.lng.toStringAsFixed(5)}';
    final showDragHandle = hasWriteAccess && !_selectionMode;
    return OptimizedLocationCard(
      key: ValueKey('${day?.toIso8601String() ?? 'bucket'}_${location.id}'),
      location: location.toLocationModel(address: coordAddress(location)),
      number: index + 1,
      showNumber: false,
      scrollController: _listScrollController,
      sheetController: null,
      onLocationTap: null,
      tripId: widget.trip.id,
      day: day,
      labeler: _labeler,
      photosExpandedInitially: true,
      // NOTE: `locations` has no updated_at column, so this is the ADD
      // time — labelled honestly rather than passed off as a modification.
      footnote:
          'Added ${DateFormat('d MMM yyyy, h:mm a').format(location.createdAt.toLocal())}',
      trailing: showDragHandle ? _buildDragHandle(location) : null,
      siblings: [
        for (final l in dateGroup) l.toLocationModel(address: coordAddress(l)),
      ],
      beforeAction: _ensureMapTrip,
      onMapPressed: () => _showOnMap(location, day),
    );
  }

  /// The card's map square: this trip on the Map tab, framed on this stop.
  Future<void> _showOnMap(SavedLocation location, DateTime? day) async {
    await openTripOnMap(ref, _trip);
    if (!mounted) return;
    if (day != null) {
      ref.read(selectedDateProvider.notifier).state = day;
    }
    ref.read(mapZoomToLocationRequestProvider.notifier).state =
        MapZoomToLocationRequest(LatLng(location.lat, location.lng));
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  /// Dedicated drag handle — a handle (vs. wrapping the whole card in
  /// LongPressDraggable) avoids fighting the long-press → selection
  /// gesture.
  Widget _buildDragHandle(SavedLocation location) {
    return Draggable<SavedLocation>(
      data: location,
      // Centre the card horizontally on the finger with the
      // finger just below its top edge, so the card is
      // carried rather than trailing off to one side.
      dragAnchorStrategy: (_, __, ___) => const Offset(_dragCardWidth / 2, 26),
      onDragStarted: () {
        HapticFeedback.mediumImpact();
        _startDragAutoScroll();
      },
      onDragUpdate: (d) => _dragPointerY = d.globalPosition.dy,
      onDragEnd: (_) => _stopDragAutoScroll(),
      onDragCompleted: _stopDragAutoScroll,
      onDraggableCanceled: (_, __) => _stopDragAutoScroll(),
      feedback: _buildDragFeedback(location),
      childWhenDragging: Opacity(
        opacity: 0.35,
        child: Icon(
          Icons.drag_indicator,
          size: 22,
          color: Theme.of(context)
              .textTheme
              .bodyMedium
              ?.color
              ?.withValues(alpha: 0.5),
        ),
      ),
      child: Tooltip(
        message: 'Drag to another day',
        child: MouseRegion(
          cursor: SystemMouseCursors.grab,
          child: Padding(
            // Roomier target: a 22px glyph is a hard thing
            // to land a thumb on mid-scroll.
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
            child: Icon(
              Icons.drag_indicator,
              size: 22,
              color: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.color
                  ?.withValues(alpha: 0.5),
            ),
          ),
        ),
      ),
    );
  }

  /// The day a place added from the page's button lands on: Day 1 of an
  /// undated trip; the first day while today is before the trip; else
  /// today (today after the trip is left to the add flow's confirmation,
  /// which offers to extend the trip).
  DateTime _defaultAddDay() {
    final now = DateTime.now();
    final start = _trip.startDate;
    if (_trip.isUndated && start != null) {
      return DateTime(start.year, start.month, start.day);
    }
    if (start != null) {
      final today = DateTime(now.year, now.month, now.day);
      final startDay = DateTime(start.year, start.month, start.day);
      if (today.isBefore(startDay)) return startDay;
    }
    return now;
  }

  void _showAddLocationDialog() =>
      showAddPlaceSheet(context, trip: _trip, day: _defaultAddDay());

  /// A day's "+" and the empty-day placeholder: the place lands on [day].
  void _showAddLocationForDate(DateTime day) =>
      showAddPlaceSheet(context, trip: _trip, day: day);
}
