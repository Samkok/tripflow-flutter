import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/all_days_route_provider.dart';
import '../providers/trip_provider.dart';
import 'auto_plan_sheet.dart';
import 'day_plan_panel.dart';

/// The planning verb has two scopes.
enum PlanScope { day, trip }

/// THE planning sheet: "This day" (where today's route starts and ends,
/// then Optimize) and "Whole trip" (Auto-plan: cities, order, days). One
/// door from the plan sheet's Plan button and the trip page; the engines
/// behind each segment are untouched.
Future<void> showPlanSheet(BuildContext context,
    {PlanScope initial = PlanScope.day}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => PlanSheet(initial: initial),
  );
}

class PlanSheet extends ConsumerStatefulWidget {
  const PlanSheet({super.key, this.initial = PlanScope.day});

  final PlanScope initial;

  @override
  ConsumerState<PlanSheet> createState() => _PlanSheetState();
}

class _PlanSheetState extends ConsumerState<PlanSheet> {
  late PlanScope _scope = widget.initial;
  bool _tripBusy = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DraggableScrollableSheet(
      initialChildSize: 0.78,
      minChildSize: 0.45,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) => Container(
        decoration: BoxDecoration(
          color: theme.scaffoldBackgroundColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        ),
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 42,
              height: 4,
              decoration: BoxDecoration(
                color: theme.dividerColor.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 8, 4),
              child: Row(
                children: [
                  Icon(Icons.route_rounded,
                      color: theme.colorScheme.primary, size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Plan',
                      style: theme.textTheme.titleLarge
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
              child: SegmentedButton<PlanScope>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                    value: PlanScope.day,
                    icon: Icon(Icons.today_rounded, size: 18),
                    label: Text('This day'),
                  ),
                  ButtonSegment(
                    value: PlanScope.trip,
                    icon: Icon(Icons.auto_awesome_rounded, size: 18),
                    label: Text('Whole trip'),
                  ),
                ],
                selected: {_scope},
                onSelectionChanged: (s) => setState(() => _scope = s.first),
              ),
            ),
            _statusStrip(theme),
            Expanded(
              child: switch (_scope) {
                PlanScope.day => _dayBody(scrollController),
                PlanScope.trip => AutoPlanPanel(
                    scrollController: scrollController,
                    onBusyChanged: (busy) {
                      if (mounted) setState(() => _tripBusy = busy);
                    },
                  ),
              },
            ),
          ],
        ),
      ),
    );
  }

  /// What is in flight, in one place for both scopes.
  Widget _statusStrip(ThemeData theme) {
    final optimizing = ref.watch(isGeneratingRouteProvider);
    final String? label = optimizing
        ? "Optimizing today's route…"
        : _tripBusy
            ? 'Applying the plan…'
            : null;
    if (label == null) return const SizedBox(height: 8);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const LinearProgressIndicator(minHeight: 2),
          const SizedBox(height: 6),
          Text(label,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }

  Widget _dayBody(ScrollController scrollController) {
    final theme = Theme.of(context);
    if (ref.watch(allDaysModeProvider)) {
      return _message(theme, Icons.calendar_view_day_rounded,
          'Pick a day on the map first — a route is planned one day at a time.');
    }
    final count =
        ref.watch(locationsForSelectedDateProvider.select((l) => l.length));
    if (count == 0) {
      return _message(theme, Icons.add_location_alt_outlined,
          'Add places to this day first.');
    }
    final isReoptimizing =
        ref.watch(tripProvider.select((s) => s.optimizedRoute.isNotEmpty));
    return DayPlanPanel(
      key: ValueKey(isReoptimizing),
      scrollController: scrollController,
      isReoptimizing: isReoptimizing,
    );
  }

  Widget _message(ThemeData theme, IconData icon, String text) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(text,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}
