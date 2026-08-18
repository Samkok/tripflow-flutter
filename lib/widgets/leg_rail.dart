import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/optimized_map_overlay_provider.dart';
import '../models/location_model.dart';
import '../utils/marker_utils.dart';

/// The travel segment BETWEEN two stop cards in the trip plan list — the
/// Google-Maps-itinerary treatment in VoyZa's language: a short vertical
/// rail (dotted for walking, solid in the line's official color for
/// transit) beside one compact fact line, expandable transit details, and
/// a tap-through to the leg sheet (mode switcher lives there).
class LegRail extends ConsumerWidget {
  const LegRail({
    super.key,
    required this.legIndex,
    required this.legData,
    required this.from,
    required this.to,
  });

  final int legIndex;
  final Map<String, dynamic> legData;
  final LocationModel from;
  final LocationModel to;

  Color? _lineColor(String? hex) {
    if (hex == null || hex.isEmpty) return null;
    final cleaned = hex.replaceFirst('#', '');
    if (cleaned.length != 6) return null;
    final value = int.tryParse(cleaned, radix: 16);
    return value == null ? null : Color(0xFF000000 | value);
  }

  String _fact(BuildContext context) {
    final distance = ((legData['distance'] as num?) ?? 0).toDouble();
    final duration = legData['duration'] as Duration?;
    final distanceLabel = distance >= 1000
        ? '${(distance / 1000).toStringAsFixed(1)} km'
        : '${distance.round()} m';
    final durationLabel = duration == null || duration == Duration.zero
        ? null
        : duration.inHours > 0
            ? '${duration.inHours}h ${duration.inMinutes % 60}m'
            : '${duration.inMinutes} min';

    final mode = legData['mode'] as String? ?? 'drive';
    final verb = switch (mode) {
      'walk' => 'Walk',
      'transit' => 'Ride',
      'bicycle' => 'Bike',
      'two_wheeler' => 'Motorbike',
      'direct' => 'No route found',
      _ => 'Drive',
    };
    if (mode == 'direct') return '$verb · $distanceLabel direct';
    return durationLabel == null
        ? '$verb · $distanceLabel'
        : '$verb $durationLabel · $distanceLabel';
  }

  /// The rail's middle: transit legs with step data render a VERTICAL
  /// segment stack (walk › ride › transfer walk › ride, ↓ between each);
  /// every other mode keeps the plain one-fact line.
  Widget _buildChainOrFact(BuildContext context, ThemeData theme) {
    final mode = legData['mode'] as String? ?? 'drive';
    final steps = (legData['transitSteps'] as List?)?.cast<Map>();
    final factStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontWeight: FontWeight.w600,
    );

    final hasChain = mode == 'transit' &&
        steps != null &&
        steps.isNotEmpty &&
        steps.any((s) => ((s['durationSeconds'] as num?) ?? 0) > 0);
    if (!hasChain) {
      return Text(
        _fact(context),
        style: factStyle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }

    String mins(Map s) {
      final m =
          ((((s['durationSeconds'] as num?) ?? 0) / 60).round()).clamp(1, 999);
      return '$m min';
    }

    // Vertically stacked segments in travel order — walk to the station,
    // ride, transfer walk, next ride… — with a small ↓ between each, the
    // itinerary shape users know from Google Maps. Transfer walks are
    // segments too (only curb-length shuffles under ~20s are dropped).
    final rows = <Widget>[];
    for (final s in steps) {
      final isRide = s['mode'] == 'TRANSIT';
      final secs = ((s['durationSeconds'] as num?) ?? 0).toInt();
      if (!isRide && secs < 20) continue;
      if (rows.isNotEmpty) {
        rows.add(Padding(
          padding: const EdgeInsets.only(left: 1, top: 2, bottom: 2),
          child: Icon(Icons.arrow_downward_rounded,
              size: 13,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5)),
        ));
      }
      if (isRide) {
        final color =
            _lineColor(s['lineColor'] as String?) ?? theme.colorScheme.primary;
        final label = (s['lineShort'] as String?) ?? '';
        rows.add(Row(mainAxisSize: MainAxisSize.min, children: [
          if (label.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(5),
              ),
              child: ConstrainedBox(
                // Some route names are whole sentences (e.g. 7327J經高鐵、
                // 長庚、遊客中心) — cap so chip + "Ride · N min" always fit.
                constraints: const BoxConstraints(maxWidth: 120),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w800),
                ),
              ),
            )
          else
            Icon(
              MarkerUtils.legModeIcon('transit',
                  vehicleType: s['vehicleType'] as String?),
              size: 14,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          const SizedBox(width: 5),
          Text('Ride · ${mins(s)}', style: factStyle),
        ]));
      } else {
        rows.add(Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.directions_walk_rounded,
              size: 14, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 5),
          Text('Walk · ${mins(s)}', style: factStyle),
        ]));
      }
    }
    if (rows.isEmpty) {
      return Text(_fact(context),
          style: factStyle, maxLines: 1, overflow: TextOverflow.ellipsis);
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: rows,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final mode = legData['mode'] as String? ?? 'drive';
    final transit = (legData['transit'] as List?)?.cast<Map<String, dynamic>>();
    final firstSeg =
        (transit != null && transit.isNotEmpty) ? transit.first : null;
    final railColor = mode == 'transit'
        ? (_lineColor(firstSeg?['lineColor'] as String?) ??
            theme.colorScheme.primary)
        : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5);

    String? boardTime;
    final dep = firstSeg?['departureTime'] as String?;
    if (dep != null) {
      final parsed = DateTime.tryParse(dep)?.toLocal();
      if (parsed != null) {
        boardTime = MaterialLocalizations.of(context)
            .formatTimeOfDay(TimeOfDay.fromDateTime(parsed));
      }
    }

    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () {
        // Same request bus the map's leg chips use — MapScreen owns the
        // sheet (this list lives inside it).
        final distance = ((legData['distance'] as num?) ?? 0).toDouble();
        ref.read(routeLegSheetRequestProvider.notifier).state =
            RouteLegSheetRequest(
          origin: from,
          destination: to,
          distanceLabel: distance >= 1000
              ? '${(distance / 1000).toStringAsFixed(1)} km'
              : '${distance.round()} m',
          durationLabel: null,
          legIndex: legIndex,
          mode: mode,
          transit: transit,
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          // Multi-segment chains stack vertically — top-align the rail bar,
          // glyph and time against them instead of floating mid-height.
          crossAxisAlignment: (mode == 'transit' &&
                  ((legData['transitSteps'] as List?)?.isNotEmpty ?? false))
              ? CrossAxisAlignment.start
              : CrossAxisAlignment.center,
          children: [
            // The rail: aligned under the cards' leading edge. Dotted for
            // walking (three dots), solid bar otherwise.
            SizedBox(
              width: 34,
              height: 34,
              child: Center(
                child: mode == 'walk' || mode == 'direct'
                    ? Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          for (var i = 0; i < 3; i++)
                            Container(
                              width: 4,
                              height: 4,
                              margin: const EdgeInsets.symmetric(vertical: 2.5),
                              decoration: BoxDecoration(
                                color: railColor,
                                shape: BoxShape.circle,
                              ),
                            ),
                        ],
                      )
                    : Container(
                        width: 5,
                        height: 28,
                        decoration: BoxDecoration(
                          color: railColor,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              MarkerUtils.legModeIcon(mode,
                  vehicleType: firstSeg?['vehicleType'] as String?),
              size: 16,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            // Transit legs with step data render the FULL journey chain —
            // walk 4 min › [87] 30 min › [H] 10 min — matching what the map
            // draws (the old single-badge line hid second rides and the
            // station walks entirely). Other modes keep the one-fact line.
            Expanded(
              child: _buildChainOrFact(context, theme),
            ),
            if (boardTime != null)
              Text(
                boardTime,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            Icon(Icons.chevron_right_rounded,
                size: 16,
                color:
                    theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6)),
          ],
        ),
      ),
    );
  }
}
