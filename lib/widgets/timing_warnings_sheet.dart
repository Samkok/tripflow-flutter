import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../models/location_model.dart';
import '../providers/map_ui_state_provider.dart';
import '../providers/trip_provider.dart';
import '../providers/trip_simulation_provider.dart';
import '../services/timing_simulation.dart';
import 'app_toast.dart';

/// Modal sheet shown after the user taps Optimize when the timing simulation
/// flags one or more stops. The user picks Skip or Move-to-next-day per
/// flagged stop, those choices are STAGED locally (the live route isn't
/// touched yet), and a single Cancel / Confirm bar at the bottom applies
/// everything at once and re-runs the optimizer. Confirm stays disabled
/// until every flagged stop has a staged choice.
///
/// Captured snapshot model: at open time we freeze the list of problems
/// from [tripSimulationProvider]. The provider isn't watched, so live
/// state changes (e.g. the sim re-running mid-staging) can't shift rows
/// out from under the user.
class TimingWarningsSheet extends ConsumerStatefulWidget {
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
  ConsumerState<TimingWarningsSheet> createState() =>
      _TimingWarningsSheetState();
}

/// What the user has decided to do about a flagged stop.
///   • [skip] — drop from the route via `skipMultipleLocations`.
///   • [moveNextDay] — push to the next day via
///     `updateMultipleLocationsScheduledDate`.
///   • [goAnyway] — acknowledge the warning but keep the stop in the
///     route as-is; no repository write happens for this choice.
enum _ActionKind { skip, moveNextDay, goAnyway }

class _ProblemEntry {
  final StopTiming stop;
  final LocationModel location;
  const _ProblemEntry({required this.stop, required this.location});
}

class _TimingWarningsSheetState extends ConsumerState<TimingWarningsSheet> {
  /// Snapshot at open time. Not reactive — staging choices below don't
  /// re-run the simulator, so we don't need a live view.
  late final List<_ProblemEntry> _problems;

  /// Per-location staged choice. Missing key = not yet decided.
  final Map<String, _ActionKind> _staged = {};

  bool _applying = false;

  @override
  void initState() {
    super.initState();
    final result = ref.read(tripSimulationProvider);
    final ordered =
        ref.read(tripProvider).optimizedLocationsForSelectedDate;
    final byId = {for (final l in ordered) l.id: l};

    _problems = result == null
        ? const []
        : result.stops
            .where((s) => s.warnings.isNotEmpty)
            .map((s) {
              final loc = byId[s.locationId];
              if (loc == null) return null;
              return _ProblemEntry(stop: s, location: loc);
            })
            .whereType<_ProblemEntry>()
            .toList();
  }

  bool get _allResolved =>
      _problems.isNotEmpty &&
      _problems.every((p) => _staged.containsKey(p.location.id));

  void _stage(String locationId, _ActionKind action) {
    setState(() {
      // Toggle: tapping the same choice again clears it (lets users
      // change their mind back to "undecided").
      if (_staged[locationId] == action) {
        _staged.remove(locationId);
      } else {
        _staged[locationId] = action;
      }
    });
  }

  Future<void> _confirm() async {
    if (!_allResolved || _applying) return;
    setState(() => _applying = true);

    final navigator = Navigator.of(context);
    final notifier = ref.read(tripProvider.notifier);
    // Capture the user's chosen starting anchor BEFORE the awaits so the
    // re-optimize below preserves it. Without this, generateOptimizedRoute
    // falls back to the device GPS and the route silently re-anchors away
    // from whatever the user picked in the Optimize sheet.
    final currentStartId = ref.read(tripProvider).startLocationId;

    // Group actions to minimize repository writes.
    final toSkip = <String>{};
    final movesByDate = <DateTime, Set<String>>{};
    final goAnyway = <String>{};
    for (final p in _problems) {
      final action = _staged[p.location.id]!;
      switch (action) {
        case _ActionKind.skip:
          toSkip.add(p.location.id);
        case _ActionKind.moveNextDay:
          final cur = p.location.scheduledDate ?? DateTime.now();
          final next = DateTime(cur.year, cur.month, cur.day)
              .add(const Duration(days: 1));
          movesByDate.putIfAbsent(next, () => {}).add(p.location.id);
        case _ActionKind.goAnyway:
          // User accepted the warning — keep the stop in the route
          // exactly as-is. No repository write needed.
          goAnyway.add(p.location.id);
      }
    }

    // Mark Go-anyway stops as acknowledged BEFORE the re-optimize call
    // below fires zoomToFitRouteTrigger. The listener in trip_bottom_sheet
    // reads this set to decide whether to re-open the sheet — without
    // this, the same warnings would resurface and we'd loop. Acked ids
    // are unioned (not replaced) so prior acknowledgements persist
    // across multiple confirm cycles in the same session.
    if (goAnyway.isNotEmpty) {
      final notifier =
          ref.read(acknowledgedTimingWarningsProvider.notifier);
      notifier.state = {...notifier.state, ...goAnyway};
    }

    try {
      if (toSkip.isNotEmpty) {
        await notifier.skipMultipleLocations(toSkip);
      }
      for (final entry in movesByDate.entries) {
        await notifier.updateMultipleLocationsScheduledDate(
            entry.value, entry.key);
      }

      // Re-run the optimizer now that the day's stops have settled.
      final selectedDate = ref.read(selectedDateProvider);
      await notifier.generateOptimizedRoute(
        selectedDate: selectedDate,
        startLocationId: currentStartId.isEmpty ? null : currentStartId,
      );

      if (mounted) navigator.pop();
    } catch (e) {
      if (mounted) {
        setState(() => _applying = false);
        AppToast.error(context, 'Could not apply changes: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_problems.isEmpty) {
      // Nothing to resolve — close immediately. Shouldn't happen since
      // the sheet is opened in response to warnings existing, but kept
      // defensive in case the sim cleared between trigger and mount.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        }
      });
      return const SizedBox.shrink();
    }

    final resolvedCount = _staged.length;
    final totalCount = _problems.length;

    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.35,
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
                padding: const EdgeInsets.fromLTRB(20, 4, 12, 8),
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
                            totalCount == 1
                                ? '1 stop has a timing issue'
                                : '$totalCount stops have timing issues',
                            style: theme.textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Pick an action for each. Nothing changes '
                            'until you tap Apply.',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 6),
                          // Progress line — gives the user a clear sense
                          // of how many are left, since Apply is locked
                          // until everything's resolved.
                          Text(
                            '$resolvedCount of $totalCount resolved',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: resolvedCount == totalCount
                                  ? Colors.green.shade700
                                  : theme.colorScheme.onSurfaceVariant,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed:
                          _applying ? null : () => Navigator.of(context).pop(),
                      tooltip: 'Cancel',
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.separated(
                  controller: scrollController,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 8),
                  itemCount: _problems.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 4),
                  itemBuilder: (context, i) {
                    final entry = _problems[i];
                    return _WarningRow(
                      stop: entry.stop,
                      location: entry.location,
                      staged: _staged[entry.location.id],
                      onStage: _applying
                          ? null
                          : (action) =>
                              _stage(entry.location.id, action),
                    );
                  },
                ),
              ),
              const Divider(height: 1),
              SafeArea(
                top: false,
                child: Padding(
                  padding:
                      const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _applying
                              ? null
                              : () => Navigator.of(context).pop(),
                          style: OutlinedButton.styleFrom(
                            padding:
                                const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: const Text('Cancel'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 2,
                        child: FilledButton(
                          onPressed:
                              _allResolved && !_applying ? _confirm : null,
                          style: FilledButton.styleFrom(
                            backgroundColor: theme.colorScheme.primary,
                            foregroundColor: Colors.black,
                            padding:
                                const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: _applying
                              ? const SizedBox(
                                  height: 20,
                                  width: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.black,
                                  ),
                                )
                              : const Text(
                                  'Apply & re-optimize',
                                  style: TextStyle(
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
          ),
        );
      },
    );
  }
}

class _WarningRow extends StatelessWidget {
  final StopTiming stop;
  final LocationModel location;
  final _ActionKind? staged;

  /// Null when the sheet is mid-apply — disables row-level toggling so
  /// the staged set can't change while [TimingWarningsSheet._confirm]
  /// is iterating it.
  final void Function(_ActionKind)? onStage;

  const _WarningRow({
    required this.stop,
    required this.location,
    required this.staged,
    required this.onStage,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // The simulation guarantees at least one warning per row in this sheet —
    // pick the most severe (highest enum index per WarningKind ordering).
    final warning = stop.warnings
        .reduce((a, b) => a.kind.index >= b.kind.index ? a : b);

    final tone = _toneFor(warning.kind, theme);
    final resolved = staged != null;

    return Material(
      color: resolved
          ? theme.colorScheme.primary.withValues(alpha: 0.06)
          : theme.cardColor,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: resolved
                ? theme.colorScheme.primary.withValues(alpha: 0.4)
                : theme.dividerColor.withValues(alpha: 0.3),
            width: resolved ? 1.5 : 1,
          ),
        ),
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
                    child: Icon(tone.icon,
                        color: tone.foreground, size: 18),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          location.name,
                          style: theme.textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w600),
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
                  if (resolved)
                    Icon(Icons.check_circle,
                        color: theme.colorScheme.primary, size: 22),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  _ChoiceButton(
                    icon: Icons.remove_circle_outline,
                    label: 'Skip',
                    selected: staged == _ActionKind.skip,
                    onTap: onStage == null
                        ? null
                        : () => onStage!(_ActionKind.skip),
                  ),
                  _ChoiceButton(
                    icon: Icons.calendar_today_outlined,
                    label: 'Next day',
                    selected: staged == _ActionKind.moveNextDay,
                    onTap: onStage == null
                        ? null
                        : () => onStage!(_ActionKind.moveNextDay),
                  ),
                  _ChoiceButton(
                    icon: Icons.arrow_forward_rounded,
                    label: 'Go anyway',
                    selected: staged == _ActionKind.goAnyway,
                    onTap: onStage == null
                        ? null
                        : () => onStage!(_ActionKind.goAnyway),
                  ),
                ],
              ),
            ],
          ),
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

/// A toggleable per-row choice chip. Filled when [selected]; outlined
/// otherwise. Both Skip and Next-day use the same component so the user
/// reads them as a binary picker.
class _ChoiceButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  const _ChoiceButton({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;

    if (selected) {
      return FilledButton.icon(
        icon: Icon(icon, size: 16),
        label: Text(label),
        onPressed: onTap,
        style: FilledButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: Colors.black,
          visualDensity: VisualDensity.compact,
          padding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        ),
      );
    }
    return OutlinedButton.icon(
      icon: Icon(icon, size: 16),
      label: Text(label),
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        side: BorderSide(color: primary.withValues(alpha: 0.4)),
        foregroundColor: primary,
      ),
    );
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
