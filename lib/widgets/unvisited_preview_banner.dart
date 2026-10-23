import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/trip_provider.dart';
import '../providers/unvisited_places_provider.dart';

/// One line under the search column while the map previews an ended trip's
/// unvisited places: says what the pins are (the day's own stops and route
/// are hidden meanwhile) and switches the preview off. Sits in the chrome's
/// layout flow like [DayLegend], so the map's fit window clears it.
class UnvisitedPreviewBanner extends ConsumerWidget {
  const UnvisitedPreviewBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(showUnvisitedOnMapProvider)) return const SizedBox.shrink();
    final count = ref.watch(endedTripUnvisitedProvider.select((l) => l.length));
    if (count == 0) return const SizedBox.shrink();
    final theme = Theme.of(context);
    const red = Color(0xFFFF5252);
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Material(
          color: theme.colorScheme.surface.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () =>
                ref.read(showUnvisitedOnMapProvider.notifier).state = false,
            child: Container(
              padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: red.withValues(alpha: 0.5)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.flag_outlined, size: 15, color: red),
                  const SizedBox(width: 6),
                  Text(
                    'Showing the $count place${count == 1 ? '' : 's'} you '
                    "didn't visit",
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: red,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(Icons.close_rounded,
                      size: 16, color: red.withValues(alpha: 0.8)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
