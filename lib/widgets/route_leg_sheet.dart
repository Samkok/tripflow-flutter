import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme.dart';
import '../models/location_model.dart';
import '../providers/map_ui_state_provider.dart';
import '../providers/trip_provider.dart';
import '../services/multi_modal_router.dart';
import '../utils/external_app_links.dart';
import '../utils/marker_utils.dart';
import 'app_toast.dart';

/// Bottom sheet for one leg of an optimized route — now multi-modal.
///
/// Opened by tapping the leg chip on the map or a timeline rail in the plan
/// sheet. Shows the leg's mode and facts; for transit legs, the ride
/// itinerary (line badge in its official color, board/alight stops,
/// scheduled times, stop count); and a mode switcher that re-routes JUST
/// this leg and remembers the choice for future optimizes.
///
/// Deliberately SOLID, unlike the trip plan / search / collaborators sheets:
/// it's a small pane over a busy map, where a blurred one made the leg names
/// hard to read. Only the barrier and border come from `AppTheme.sheet*`.
///
/// NOTE: a ride-provider section belongs here (Grab / Uber / Bolt …), gated
/// on the leg's country. It is deliberately absent until the country →
/// provider table in `docs/ride-providers.md` is approved — showing a
/// provider that doesn't operate locally is the bug that started this work.
Future<void> showRouteLegSheet(
  BuildContext context, {
  required LocationModel origin,
  required LocationModel destination,
  required String distanceLabel,
  String? durationLabel,
  int legIndex = -1,
  String mode = 'drive',
  List<Map<String, dynamic>>? transit,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    barrierColor: AppTheme.sheetBarrierColor(context),
    builder: (sheetContext) => _RouteLegSheet(
      origin: origin,
      destination: destination,
      distanceLabel: distanceLabel,
      durationLabel: durationLabel,
      legIndex: legIndex,
      mode: mode,
      transit: transit,
    ),
  );
}

String _modeLabel(String mode) => switch (mode) {
      'walk' => 'on foot',
      'transit' => 'by transit',
      'bicycle' => 'by bike',
      'two_wheeler' => 'by motorcycle',
      'direct' => 'no route found — straight-line estimate',
      _ => 'by car',
    };

Color? _lineColor(String? hex) {
  if (hex == null || hex.isEmpty) return null;
  final cleaned = hex.replaceFirst('#', '');
  if (cleaned.length != 6) return null;
  final value = int.tryParse(cleaned, radix: 16);
  return value == null ? null : Color(0xFF000000 | value);
}

class _RouteLegSheet extends ConsumerStatefulWidget {
  const _RouteLegSheet({
    required this.origin,
    required this.destination,
    required this.distanceLabel,
    this.durationLabel,
    required this.legIndex,
    required this.mode,
    this.transit,
  });

  final LocationModel origin;
  final LocationModel destination;
  final String distanceLabel;
  final String? durationLabel;
  final int legIndex;
  final String mode;
  final List<Map<String, dynamic>>? transit;

  @override
  ConsumerState<_RouteLegSheet> createState() => _RouteLegSheetState();
}

class _RouteLegSheetState extends ConsumerState<_RouteLegSheet> {
  /// Mode being fetched by the switcher; null when idle.
  String? _switching;

  /// Per-mode availability for THIS leg, probed on open. Probes go through
  /// the router's leg cache, so they double as pre-warming: by the time the
  /// user picks a mode, the route is usually already fetched — and modes
  /// with no route render as disabled chips instead of failing on tap.
  /// null = probe still running (chips stay optimistically enabled).
  Map<String, bool>? _available;

  static const _switchableModes = [
    ('walk', Icons.directions_walk_rounded, 'Walk'),
    ('transit', Icons.directions_transit_rounded, 'Transit'),
    ('drive', Icons.directions_car_rounded, 'Drive'),
    ('bicycle', Icons.directions_bike_rounded, 'Bike'),
    ('two_wheeler', Icons.two_wheeler_rounded, 'Moto'),
  ];

  /// Ranked route options for THIS leg in its current mode. null = still
  /// loading; empty = nothing routed (quiet empty line). Google's default
  /// route leads the list — that's the recommended one.
  List<LegRoute>? _alternatives;
  int? _appliedAltIndex;
  int? _applyingAltIndex;

  @override
  void initState() {
    super.initState();
    _probeAvailability();
    _loadAlternatives();
  }

  Future<void> _loadAlternatives() async {
    if (widget.legIndex < 0 || widget.mode == 'direct') {
      setState(() => _alternatives = const []);
      return;
    }
    // Anchor to the leg's planned board time when it has one, so options
    // rank against the itinerary's clock, not "now".
    DateTime? departure;
    final plannedBoard = widget.transit?.isNotEmpty == true
        ? DateTime.tryParse(
            (widget.transit!.first['departureTime'] as String?) ?? '')
        : null;
    departure = plannedBoard ?? DateTime.now().add(const Duration(minutes: 10));
    final options = await MultiModalRouter.fetchLegAlternatives(
      from: widget.origin.coordinates,
      to: widget.destination.coordinates,
      mode: widget.mode,
      departureTime: departure,
    ).catchError((Object _) => const <LegRoute>[]);
    if (!mounted) return;
    // Mark the option matching the currently applied leg; the recommended
    // top row is only "selected" when it actually is the applied route.
    int? applied;
    final legsNow = ref.read(tripProvider).legDetails;
    Duration? currentDuration;
    double? currentDistance;
    if (widget.legIndex >= 0 && widget.legIndex < legsNow.length) {
      currentDuration = legsNow[widget.legIndex]['duration'] as Duration?;
      currentDistance =
          (legsNow[widget.legIndex]['distance'] as num?)?.toDouble();
    }
    for (var i = 0; i < options.length; i++) {
      if (options[i].duration == currentDuration &&
          options[i].distance == currentDistance) {
        applied = i;
        break;
      }
    }
    setState(() {
      _alternatives = options;
      _appliedAltIndex = applied ?? (options.isEmpty ? null : 0);
    });
  }

  Future<void> _applyAlternative(int index) async {
    final options = _alternatives;
    if (options == null || index >= options.length) return;
    if (_applyingAltIndex != null || index == _appliedAltIndex) return;
    setState(() => _applyingAltIndex = index);
    final ok = await ref
        .read(tripProvider.notifier)
        .applyLegRoute(widget.legIndex, options[index]);
    if (!mounted) return;
    setState(() {
      _applyingAltIndex = null;
      if (ok) _appliedAltIndex = index;
    });
    if (ok) {
      // Sheet stays open on purpose: picking a route is a comparison flow,
      // and the map updates live behind the sheet.
      AppToast.success(context, 'Route updated');
    } else {
      AppToast.warning(context, 'Couldn\'t apply that route');
    }
  }

  Future<void> _probeAvailability() async {
    if (widget.legIndex < 0) return;
    final entries = await Future.wait([
      for (final (m, _, _) in _switchableModes)
        m == widget.mode
            ? Future.value(MapEntry(m, true))
            : MultiModalRouter.routeSingleLeg(
                from: widget.origin.coordinates,
                to: widget.destination.coordinates,
                mode: m,
                departureTime: DateTime.now().add(const Duration(minutes: 10)),
              )
                .then((r) => MapEntry(m, r != null))
                .catchError((Object _) => MapEntry(m, false)),
    ]);
    if (!mounted) return;
    setState(() => _available = {for (final e in entries) e.key: e.value});
  }

  Future<void> _switchMode(String mode) async {
    if (_switching != null || mode == widget.mode) return;
    setState(() => _switching = mode);
    final ok = await ref
        .read(tripProvider.notifier)
        .overrideLegMode(widget.legIndex, mode);
    if (!mounted) return;
    setState(() => _switching = null);
    if (ok) {
      Navigator.of(context).pop();
      AppToast.success(context, 'Leg updated — this choice is remembered');
    } else {
      AppToast.warning(
          context,
          'No ${_modeLabel(mode).replaceFirst('by ', '')} '
          'route found for this leg');
    }
  }

  String? _localTime(String? rfc3339) {
    if (rfc3339 == null) return null;
    final parsed = DateTime.tryParse(rfc3339)?.toLocal();
    if (parsed == null) return null;
    return MaterialLocalizations.of(context)
        .formatTimeOfDay(TimeOfDay.fromDateTime(parsed));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mode = widget.mode;
    final subtitle = (widget.durationLabel == null ||
            widget.durationLabel!.isEmpty)
        ? '${widget.distanceLabel} · ${_modeLabel(mode)}'
        : '${widget.distanceLabel} · ${widget.durationLabel} ${_modeLabel(mode)}';

    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: Container(
        // Solid, NOT glass. This sheet is small and sits directly over a
        // busy map; a see-through pane made the leg names hard to read.
        decoration: BoxDecoration(
          color: theme.scaffoldBackgroundColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border.all(
            color: AppTheme.sheetBorderColor(context),
            width: 0.8,
          ),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Header = drag zone ─────────────────────────────────────
              // Handle + title + subtitle live OUTSIDE the scroll view: a
              // scrollable eats vertical drags, so with the whole sheet
              // scrollable the ONLY way to drag-dismiss was the 4px pill.
              // Everything in this block drags the sheet natively.
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.grey[400],
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          MarkerUtils.legModeIcon(mode,
                              vehicleType: widget.transit?.isNotEmpty == true
                                  ? widget.transit!.first['vehicleType']
                                      as String?
                                  : null),
                          size: 26,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            '${widget.origin.name} → ${widget.destination.name}',
                            style: theme.textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.bold),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          icon: const Icon(Icons.close),
                          tooltip: 'Close',
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // ── Transit itinerary — every segment, walks included ──
                        if (widget.transit != null &&
                            widget.transit!.isNotEmpty) ...[
                          const SizedBox(height: 14),
                          ..._buildJourneySegments(),
                        ],

                        // ── Mode switcher (only for real legs of a route) ─────
                        if (widget.legIndex >= 0) ...[
                          const SizedBox(height: 18),
                          Text(
                            'TRAVEL THIS LEG',
                            style: theme.textTheme.labelSmall?.copyWith(
                              letterSpacing: 1.1,
                              fontWeight: FontWeight.w800,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final (m, icon, label) in _switchableModes)
                                _modeChip(m, icon, label),
                            ],
                          ),

                          // ── Route options: the departure board ────────
                          // Google's ranking IS the structure: the default
                          // route leads with a RECOMMENDED chip; alternates
                          // follow. Tapping applies live — the sheet stays
                          // open so options can be compared on the map.
                          if (widget.mode != 'direct') ...[
                            const SizedBox(height: 18),
                            Text(
                              'ROUTE OPTIONS',
                              style: theme.textTheme.labelSmall?.copyWith(
                                letterSpacing: 1.1,
                                fontWeight: FontWeight.w800,
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 8),
                            if (_alternatives == null)
                              Row(children: [
                                const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                ),
                                const SizedBox(width: 8),
                                Text('Finding routes…',
                                    style: theme.textTheme.bodySmall?.copyWith(
                                        color: theme
                                            .colorScheme.onSurfaceVariant)),
                              ])
                            else if (_alternatives!.length <= 1)
                              Text(
                                _alternatives!.isEmpty
                                    ? 'No route options here.'
                                    : 'Only one route here.',
                                style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant),
                              )
                            else
                              for (var i = 0; i < _alternatives!.length; i++)
                                _optionRow(i, _alternatives![i]),
                          ],
                        ],

                        const SizedBox(height: 20),
                        // Frame this leg on the map (real legs only — previews
                        // have no leg identity to zoom to).
                        if (widget.legIndex >= 0) ...[
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              onPressed: () {
                                Navigator.of(context).pop();
                                ref
                                    .read(mapZoomToLegRequestProvider.notifier)
                                    .state = MapZoomToLegRequest(widget.legIndex);
                              },
                              icon: const Icon(
                                  Icons.center_focus_strong_rounded,
                                  size: 20),
                              label: const Text('Show on map'),
                              style: OutlinedButton.styleFrom(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 14),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(28),
                                ),
                                textStyle: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                        ],
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: () {
                              Navigator.of(context).pop();
                              openDirectionsInGoogleMaps(
                                origin: widget.origin,
                                destination: widget.destination,
                                mode: mode,
                              );
                            },
                            icon: const Icon(Icons.map_rounded, size: 20),
                            label: const Text('Open in Google Maps'),
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(28),
                              ),
                              textStyle: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),

                        // ── Compliance footnotes ──────────────────────────────
                        // Beta-mode warning is a Google Maps Platform display
                        // REQUIREMENT for walk / two-wheeler results; the
                        // attribution line covers the derived route facts shown
                        // in this sheet.
                        if (mode == 'walk' || mode == 'two_wheeler') ...[
                          const SizedBox(height: 12),
                          Text(
                            mode == 'walk'
                                ? 'Walking routes are in beta and might sometimes be '
                                    'missing clear sidewalks or pedestrian paths.'
                                : 'Two-wheeled routes are in beta and might sometimes '
                                    'be missing suitable paths.',
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant
                                    .withValues(alpha: 0.8)),
                          ),
                        ],
                        const SizedBox(height: 8),
                        Text(
                          'Route data: Google Maps',
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant
                                  .withValues(alpha: 0.6)),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The transit journey as a vertical stack — EVERY segment in travel
  /// order, arrows between: walk to the station, each ride (full card),
  /// transfer walks between stations, walk from the last stop. Built from
  /// the leg's step runs when available (route state), falling back to the
  /// ride cards alone for legs routed before step data existed.
  List<Widget> _buildJourneySegments() {
    final rides = widget.transit ?? const [];
    List<Map>? runs;
    if (widget.legIndex >= 0) {
      final legs = ref.read(tripProvider).legDetails;
      if (widget.legIndex < legs.length) {
        runs = (legs[widget.legIndex]['transitSteps'] as List?)?.cast<Map>();
      }
    }

    Widget arrow() => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Icon(Icons.arrow_downward_rounded,
              size: 16,
              color: Theme.of(context)
                  .colorScheme
                  .onSurfaceVariant
                  .withValues(alpha: 0.55)),
        );

    final rideCount = runs?.where((r) => r['mode'] == 'TRANSIT').length ?? -1;
    if (runs == null || runs.isEmpty || rideCount != rides.length) {
      // Fallback: rides only, still vertically stacked with arrows.
      final out = <Widget>[];
      for (var i = 0; i < rides.length; i++) {
        if (i > 0) out.add(arrow());
        out.add(_transitSegment(rides[i]));
      }
      return out;
    }

    final out = <Widget>[];
    var rideIdx = 0;
    for (final run in runs) {
      final isRide = run['mode'] == 'TRANSIT';
      final secs = ((run['durationSeconds'] as num?) ?? 0).toInt();
      if (!isRide && secs < 20) continue; // curb-length shuffles
      if (out.isNotEmpty) out.add(arrow());
      if (isRide) {
        out.add(_transitSegment(rides[rideIdx++]));
      } else {
        out.add(_walkSegment(secs));
      }
    }
    return out;
  }

  Widget _walkSegment(int seconds) {
    final theme = Theme.of(context);
    final mins = (seconds / 60).round().clamp(1, 999);
    return Row(children: [
      Icon(Icons.directions_walk_rounded,
          size: 18, color: theme.colorScheme.onSurfaceVariant),
      const SizedBox(width: 8),
      Text(
        'Walk · $mins min',
        style: theme.textTheme.bodyMedium?.copyWith(
          fontWeight: FontWeight.w600,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    ]);
  }

  /// Minutes the recommended [option] saves over the APPLIED route; 0 when
  /// it IS the applied route (or nothing is applied).
  int _fasterByMinutes(LegRoute option) {
    final applied = _appliedAltIndex;
    final options = _alternatives;
    if (options == null || applied == null || applied == 0) return 0;
    if (applied >= options.length) return 0;
    final delta = options[applied].duration - option.duration;
    return delta.isNegative ? 0 : delta.inMinutes;
  }

  /// One route option, departure-board style: bold duration (the decision
  /// fact), identity line (transit badge chain + times / "via …" for
  /// roads), radio-style selection at the right. Index 0 = Google's
  /// default route, chipped RECOMMENDED.
  Widget _optionRow(int index, LegRoute option) {
    final theme = Theme.of(context);
    final selected = index == _appliedAltIndex;
    final applying = index == _applyingAltIndex;
    final minutes = option.duration.inMinutes;
    final durationLabel = option.duration.inHours > 0
        ? '${option.duration.inHours}h ${minutes % 60}m'
        : '$minutes min';
    final distanceLabel = option.distance >= 1000
        ? '${(option.distance / 1000).toStringAsFixed(1)} km'
        : '${option.distance.round()} m';

    Widget identity;
    if (option.transit != null && option.transit!.isNotEmpty) {
      final dep = _localTime(option.departureTime);
      final arr = _localTime(option.arrivalTime);
      identity = Row(children: [
        for (var s = 0; s < option.transit!.length; s++) ...[
          if (s > 0)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text('›',
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant
                          .withValues(alpha: 0.5))),
            ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
            decoration: BoxDecoration(
              color: _lineColor(option.transit![s]['lineColor'] as String?) ??
                  theme.colorScheme.primary,
              borderRadius: BorderRadius.circular(5),
            ),
            child: Text(
              (option.transit![s]['lineShort'] as String?) ?? 'Ride',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w800),
            ),
          ),
        ],
        if (dep != null && arr != null) ...[
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              '$dep – $arr',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ]);
    } else {
      final via = option.description;
      identity = Text(
        via == null || via.trim().isEmpty
            ? distanceLabel
            : '$distanceLabel · $via',
        style: theme.textTheme.bodySmall
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected
            ? theme.colorScheme.primary.withValues(alpha: 0.08)
            : theme.cardColor.withValues(alpha: 0.6),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
            color: selected
                ? theme.colorScheme.primary
                : theme.dividerColor.withValues(alpha: 0.4),
            width: selected ? 1.4 : 1,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap:
              _applyingAltIndex != null ? null : () => _applyAlternative(index),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Text(
                          durationLabel,
                          style: theme.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        if (index == 0) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primary
                                  .withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(5),
                            ),
                            child: Text(
                              'RECOMMENDED',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.primary,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.6,
                              ),
                            ),
                          ),
                          // The actionable nudge: how much the recommended
                          // option beats the APPLIED route by, right now.
                          if (_fasterByMinutes(option) >= 2) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: const Color(0xFF30D158)
                                    .withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(5),
                              ),
                              child: Text(
                                '${_fasterByMinutes(option)} MIN FASTER',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: const Color(0xFF30D158),
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.6,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ]),
                      const SizedBox(height: 3),
                      identity,
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                applying
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        selected
                            ? Icons.check_circle_rounded
                            : Icons.radio_button_unchecked_rounded,
                        size: 20,
                        color: selected
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurfaceVariant
                                .withValues(alpha: 0.6),
                      ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _modeChip(String m, IconData icon, String label) {
    final theme = Theme.of(context);
    final selected = m == widget.mode;
    final loading = _switching == m;
    // Probed-and-unavailable modes are DISABLED, not fail-on-tap. While the
    // probe runs, chips stay optimistically enabled (results are cached, so
    // a tap during that window just resolves a beat slower).
    final unavailable = _available != null && _available![m] == false;
    final disabledColor = theme.disabledColor;
    return FilterChip(
      selected: selected,
      showCheckmark: false,
      avatar: loading
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(icon,
              size: 16,
              color: unavailable
                  ? disabledColor
                  : selected
                      ? theme.colorScheme.onPrimary
                      : theme.colorScheme.primary),
      label: Text(label),
      labelStyle: TextStyle(
        fontWeight: FontWeight.w700,
        color: unavailable
            ? disabledColor
            : selected
                ? theme.colorScheme.onPrimary
                : theme.textTheme.bodyMedium?.color,
      ),
      selectedColor: theme.colorScheme.primary,
      backgroundColor: theme.cardColor.withValues(alpha: 0.6),
      side: BorderSide(
        color: unavailable
            ? theme.dividerColor.withValues(alpha: 0.3)
            : selected
                ? theme.colorScheme.primary
                : theme.dividerColor.withValues(alpha: 0.5),
      ),
      onSelected:
          (_switching != null || unavailable) ? null : (_) => _switchMode(m),
    );
  }

  /// One ridden vehicle: [badge] line · headsign, board → alight, times.
  Widget _transitSegment(Map<String, dynamic> seg) {
    final theme = Theme.of(context);
    final color =
        _lineColor(seg['lineColor'] as String?) ?? theme.colorScheme.primary;
    final lineShort = (seg['lineShort'] as String?) ?? '';
    final headsign = (seg['headsign'] as String?) ?? '';
    final stops = (seg['stopCount'] as num?)?.toInt() ?? 0;
    final board = (seg['boardStop'] as String?) ?? '';
    final alight = (seg['alightStop'] as String?) ?? '';
    final dep = _localTime(seg['departureTime'] as String?);
    final arr = _localTime(seg['arrivalTime'] as String?);

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (lineShort.isNotEmpty)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      lineShort,
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          fontSize: 13),
                    ),
                  ),
                if (lineShort.isNotEmpty) const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    headsign.isEmpty ? 'Ride' : 'to $headsign',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (stops > 0)
                  Text(
                    '$stops stop${stops == 1 ? '' : 's'}',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            _stopRow(board, dep, isBoard: true),
            const SizedBox(height: 4),
            _stopRow(alight, arr, isBoard: false),
          ],
        ),
      ),
    );
  }

  Widget _stopRow(String stop, String? time, {required bool isBoard}) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(
          isBoard ? Icons.radio_button_checked : Icons.place_rounded,
          size: 14,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            stop.isEmpty ? (isBoard ? 'Board' : 'Alight') : stop,
            style: theme.textTheme.bodySmall,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (time != null)
          Text(
            time,
            style: theme.textTheme.bodySmall
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
      ],
    );
  }
}
