import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../models/location_model.dart';
import '../utils/external_app_links.dart';

/// Bottom sheet for one leg of an optimized route.
///
/// Opened by tapping the leg chip on the map (see
/// `MarkerUtils.getRouteLegChipMarker`). Replaces the old pair of bitmap
/// buttons that sat on the polyline: the map now carries only a compact
/// chip, and the actions live here where there's room to label them.
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
    ),
  );
}

class _RouteLegSheet extends StatelessWidget {
  const _RouteLegSheet({
    required this.origin,
    required this.destination,
    required this.distanceLabel,
    this.durationLabel,
  });

  final LocationModel origin;
  final LocationModel destination;
  final String distanceLabel;
  final String? durationLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subtitle = (durationLabel == null || durationLabel!.isEmpty)
        ? distanceLabel
        : '$distanceLabel · $durationLabel by car';

    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: Container(
        // Solid, NOT glass. This sheet is small and sits directly over a
        // busy map; a see-through pane made the leg names hard to read.
        // (The trip plan / search / collaborators sheets stay glass —
        // they're large enough that the blur reads as depth, not noise.)
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
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
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
                    Expanded(
                      child: Text(
                        '${origin.name} → ${destination.name}',
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
                const SizedBox(height: 22),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: () {
                      Navigator.of(context).pop();
                      openDirectionsInGoogleMaps(
                        origin: origin,
                        destination: destination,
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
              ],
            ),
          ),
        ),
      ),
    );
  }
}
