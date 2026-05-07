import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../models/location_model.dart';
import '../providers/trip_provider.dart';
import '../providers/trip_simulation_provider.dart';
import '../services/timing_simulation.dart';

/// Modal sheet shown after the user taps Optimize when the timing simulation
/// flags one or more stops. Lists each problem stop with the most severe
/// warning + quick actions (Skip · Move to next day · Dismiss). The plan
/// itself is unchanged on the map until the user acts on a row.
class TimingWarningsSheet extends ConsumerWidget {
  const TimingWarningsSheet({super.key});

  /// Convenience opener so callers don't repeat the showModalBottomSheet
  /// boilerplate. Pass the sheet's own context so it inherits theme.
  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => const TimingWarningsSheet(),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final result = ref.watch(tripSimulationProvider);

    // The sheet is always opened in response to warnings existing, but the
    // simulation can shift while it's open (user accepts a suggestion → sim
    // re-runs). When the last warning is gone, dismiss automatically.
    if (result == null || result.fullyFeasible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted && Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        }
      });
      return const SizedBox.shrink();
    }

    final problems = result.stops.where((s) => s.warnings.isNotEmpty).toList();
    final ordered = ref.read(tripProvider).optimizedLocationsForSelectedDate;
    final byId = {for (final l in ordered) l.id: l};

    return DraggableScrollableSheet(
      initialChildSize: 0.55,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: theme.scaffoldBackgroundColor,
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(top: 12, bottom: 8),
                  decoration: BoxDecoration(
                    color: theme.dividerColor,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.warning_amber_rounded,
                        color: Colors.orange.shade700, size: 26),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            problems.length == 1
                                ? '1 stop has a timing issue'
                                : '${problems.length} stops have timing issues',
                            style: theme.textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Review and adjust — the route on the map is '
                            'unchanged until you act.',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(context).pop(),
                      tooltip: 'Dismiss',
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.separated(
                  controller: scrollController,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  itemCount: problems.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 4),
                  itemBuilder: (context, i) {
                    final stop = problems[i];
                    final loc = byId[stop.locationId];
                    if (loc == null) return const SizedBox.shrink();
                    return _WarningRow(stop: stop, location: loc);
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _WarningRow extends ConsumerWidget {
  final StopTiming stop;
  final LocationModel location;

  const _WarningRow({required this.stop, required this.location});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // The simulation guarantees at least one warning per row in this sheet —
    // pick the most severe (highest enum index per WarningKind ordering).
    final warning = stop.warnings.reduce(
        (a, b) => a.kind.index >= b.kind.index ? a : b);

    final tone = _toneFor(warning.kind, theme);

    return Material(
      color: theme.cardColor,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: tone.background,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(tone.icon, color: tone.foreground, size: 18),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        location.name,
                        style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        warning.message,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: tone.foreground,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Arrives at ${_fmtTime(stop.arrival)} · '
                        'leaves at ${_fmtTime(stop.departure)}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                TextButton.icon(
                  icon: const Icon(Icons.remove_circle_outline, size: 16),
                  label: const Text('Skip'),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  ),
                  onPressed: () {
                    ref
                        .read(tripProvider.notifier)
                        .skipMultipleLocations({location.id});
                  },
                ),
                TextButton.icon(
                  icon: const Icon(Icons.calendar_today_outlined, size: 16),
                  label: const Text('Next day'),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  ),
                  onPressed: () {
                    final current = location.scheduledDate ?? DateTime.now();
                    final next = DateTime(current.year, current.month,
                            current.day)
                        .add(const Duration(days: 1));
                    ref
                        .read(tripProvider.notifier)
                        .updateMultipleLocationsScheduledDate(
                            {location.id}, next);
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _fmtTime(DateTime dt) => DateFormat('HH:mm').format(dt);

  _Tone _toneFor(WarningKind kind, ThemeData theme) {
    switch (kind) {
      case WarningKind.willOverrunClose:
        return _Tone(
          icon: Icons.timer_outlined,
          foreground: Colors.orange.shade700,
          background: Colors.orange.withValues(alpha: 0.12),
        );
      case WarningKind.notOpenYet:
        return _Tone(
          icon: Icons.schedule_outlined,
          foreground: Colors.blue.shade700,
          background: Colors.blue.withValues(alpha: 0.10),
        );
      case WarningKind.closedOnArrival:
      case WarningKind.closedAllDay:
        return _Tone(
          icon: Icons.do_not_disturb_on_outlined,
          foreground: theme.colorScheme.error,
          background: theme.colorScheme.error.withValues(alpha: 0.10),
        );
    }
  }
}

class _Tone {
  final IconData icon;
  final Color foreground;
  final Color background;
  const _Tone({
    required this.icon,
    required this.foreground,
    required this.background,
  });
}
