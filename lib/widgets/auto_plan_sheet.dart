import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../models/location_model.dart';
import '../providers/day_distribution_provider.dart';
import '../providers/subscription_provider.dart';
import '../providers/trip_listener_provider.dart';
import '../providers/trip_provider.dart';
import '../providers/user_trip_provider.dart';
import '../providers/all_days_route_provider.dart';
import '../services/analytics_service.dart';
import '../services/day_distribution/distribution_models.dart';
import '../services/leg_mode_prefs.dart';
import '../services/trip_day_service.dart';
import '../screens/paywall_screen.dart';
import 'app_toast.dart';

/// Opens the Auto-plan sheet: cluster the active trip's places into cities,
/// propose a visit order and per-day assignment, and (Pro) apply it as one
/// batch of date writes. The PREVIEW is free — the aha is the pitch.
Future<void> showAutoPlanSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const AutoPlanSheet(),
  );
}

class AutoPlanSheet extends ConsumerStatefulWidget {
  const AutoPlanSheet({super.key});

  @override
  ConsumerState<AutoPlanSheet> createState() => _AutoPlanSheetState();
}

class _AutoPlanSheetState extends ConsumerState<AutoPlanSheet> {
  bool _applying = false;
  bool _previewLogged = false;

  @override
  void initState() {
    super.initState();
    // A previous sheet's "Add a day" override / fresh-arrangement intent
    // must not leak into this one.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(autoPlanRangeOverrideProvider.notifier).state = null;
      ref.read(autoPlanKeepCurrentProvider.notifier).state = true;
    });
    // Seed the live cap + fill style from the saved preferences. If the
    // user already tapped a chip before the read resolved, their tap wins
    // (compare against the value at open, not the current one).
    final capAtOpen = ref.read(autoPlanMaxStopsProvider);
    LegModePrefs.autoPlanMaxStops().then((saved) {
      if (!mounted) return;
      if (ref.read(autoPlanMaxStopsProvider) == capAtOpen && saved != capAtOpen) {
        ref.read(autoPlanMaxStopsProvider.notifier).state = saved;
      }
    });
    final styleAtOpen = ref.read(autoPlanFillStyleProvider);
    LegModePrefs.autoPlanFillStyle().then((saved) {
      if (!mounted) return;
      final style = saved == 'pack' ? FillStyle.pack : FillStyle.balanced;
      if (ref.read(autoPlanFillStyleProvider) == styleAtOpen &&
          style != styleAtOpen) {
        ref.read(autoPlanFillStyleProvider.notifier).state = style;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final planAsync = ref.watch(autoPlanProvider);

    return DraggableScrollableSheet(
      initialChildSize: 0.65,
      minChildSize: 0.4,
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
                  Icon(Icons.auto_awesome_rounded,
                      color: theme.colorScheme.primary, size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Plan my days',
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
            Expanded(
              child: planAsync.when(
                loading: () =>
                    const Center(child: CircularProgressIndicator()),
                error: (e, _) => const _Message(
                  icon: Icons.error_outline_rounded,
                  text: "Couldn't compute a plan. Try again.",
                ),
                data: (plan) =>
                    _buildForPlan(context, plan, scrollController),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildForPlan(BuildContext context, DistributionPlan plan,
      ScrollController scrollController) {
    switch (plan.gate) {
      case DistributionGate.needsTripDates:
        return _NeedsDates(onSet: _setTripDates);
      case DistributionGate.allDaysPast:
        return const _Message(
          icon: Icons.history_rounded,
          text: 'This trip is entirely in the past — nothing left to plan.',
        );
      case DistributionGate.nothingMovable:
        return const _Message(
          icon: Icons.lock_outline_rounded,
          text: 'Nothing to rearrange: every place is completed, pinned, '
              'or an accommodation.',
        );
      case DistributionGate.ok:
        if (!_previewLogged) {
          _previewLogged = true;
          AnalyticsService.instance.autoPlanPreviewed(
            stops: plan.perDay.fold(0, (s, d) => s + d.stopIds.length) +
                plan.unscheduledIds.length,
            cities: plan.clusterOrder.length,
            days: plan.perDay.length,
            unscheduled: plan.unscheduledIds.length,
          );
        }
        // No-op plans still render: the user sees the day cards the engine
        // considers already right, with Apply disabled — never a dead end.
        return _buildProposal(context, plan, scrollController);
    }
  }

  Future<void> _setTripDates() async {
    final trip = ref.read(realtimeActiveTripProvider).valueOrNull;
    if (trip == null) return;
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: DateTime(now.year + 5),
    );
    if (picked == null || !mounted) return;
    try {
      await ref.read(tripRepositoryProvider).updateTrip(
            trip.id,
            startDate: picked.start,
            endDate: picked.end,
          );
      ref.invalidate(userTripsProvider);
      ref.invalidate(autoPlanProvider);
    } catch (e) {
      if (mounted) AppToast.error(context, "Couldn't save the dates.");
    }
  }

  Widget _buildProposal(BuildContext context, DistributionPlan plan,
      ScrollController scrollController) {
    final theme = Theme.of(context);
    final byId = {
      for (final l in ref.read(tripProvider).pinnedLocations) l.id: l
    };
    final oldDayById = {for (final c in plan.changes) c.id: c.oldDay};
    final trip = ref.read(realtimeActiveTripProvider).valueOrNull;
    final tripStart = trip?.startDate;
    final dayColors = ref.watch(tripDayColorsProvider);

    final closedCount = plan.warnings
        .where((w) => w.kind == DistributionWarningKind.closedOnDay)
        .length;
    final farCount = plan.warnings
        .where((w) => w.kind == DistributionWarningKind.accommodationFar)
        .length;
    final mismatchCount = plan.warnings
        .where((w) => w.kind == DistributionWarningKind.pinnedMismatch)
        .length;
    final packedCount = plan.warnings
        .where((w) => w.kind == DistributionWarningKind.overBudgetDay)
        .length;
    final capNow = ref.watch(autoPlanMaxStopsProvider);
    final overflow = plan.warnings
        .where((w) => w.kind == DistributionWarningKind.overflow)
        .toList();

    return Column(
      children: [
        Expanded(
          child: ListView(
            controller: scrollController,
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            children: [
              const _MaxStopsSelector(),
              const SizedBox(height: 8),
              const _KeepCurrentSwitch(),
              const SizedBox(height: 8),
              if (plan.isNoOp)
                Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF30D158).withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: const Color(0xFF30D158).withValues(alpha: 0.4)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.check_circle_outline_rounded,
                          size: 18, color: Color(0xFF30D158)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'This already matches how your days are arranged '
                          '— nothing to apply. Change the limit or fill '
                          'style, or turn off "Keep current days" for a '
                          'fresh arrangement.',
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurface),
                        ),
                      ),
                    ],
                  ),
                ),
              if (plan.clusterOrder.length > 1) ...[
                _CityOrderStrip(clusters: plan.clusterOrder),
                const SizedBox(height: 12),
              ],
              for (final day in plan.perDay)
                _DayCard(
                  planned: day,
                  byId: byId,
                  oldDayById: oldDayById,
                  tripStart: tripStart,
                  color: dayColors[day.day] ?? theme.colorScheme.primary,
                  cluster: day.clusterIndex >= 0 &&
                          day.clusterIndex < plan.clusterOrder.length
                      ? plan.clusterOrder[day.clusterIndex]
                      : null,
                  warnings: plan.warnings,
                ),
              for (final day in plan.freeDays)
                _FreeDayCard(day: day, tripStart: tripStart),
              if (plan.unscheduledIds.isNotEmpty)
                _OverflowSection(
                  ids: plan.unscheduledIds,
                  byId: byId,
                  maxStops: ref.watch(autoPlanMaxStopsProvider),
                  deficitMinutes:
                      overflow.isEmpty ? null : overflow.first.amount,
                  onAddDay: trip == null
                      ? null
                      : () async {
                          final days = ref.read(activeTripDayAxisProvider);
                          final range = await TripDayService.addDayAtEnd(
                              context, ref,
                              trip: trip, days: days);
                          if (range == null || !mounted) return;
                          // Plan against the NEW range immediately — the
                          // trip provider reloads asynchronously and the
                          // recompute used to race it (new day ignored).
                          ref.read(autoPlanRangeOverrideProvider.notifier)
                              .state = (start: range.start, end: range.end);
                        },
                ),
              if (closedCount > 0 ||
                  farCount > 0 ||
                  mismatchCount > 0 ||
                  packedCount > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (packedCount > 0)
                        Text(
                          '⚠ $packedCount ${packedCount == 1 ? 'day is' : 'days are'} '
                          'packed — over ~8½ h of visits'
                          '${capNow != null ? ' at your limit of $capNow places a day. Lower the limit' : '. Set a places-per-day limit'}'
                          ' or add a day for a lighter pace.',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: const Color(0xFFFFB300)),
                        ),
                      if (closedCount > 0)
                        Text(
                          '⚠ $closedCount ${closedCount == 1 ? 'place lands' : 'places land'} '
                          'on a weekday it may be closed — check the ⚠ rows.',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: const Color(0xFFFFB300)),
                        ),
                      if (farCount > 0)
                        Text(
                          '⚠ $farCount ${farCount == 1 ? 'day ends' : 'days end'} '
                          'far from that night\'s stay.',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: const Color(0xFFFFB300)),
                        ),
                      if (mismatchCount > 0)
                        Text(
                          '⚠ $mismatchCount pinned ${mismatchCount == 1 ? 'place sits' : 'places sit'} '
                          'on a day planned for a different city (completed '
                          'or multi-day places are never moved).',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: const Color(0xFFFFB300)),
                        ),
                    ],
                  ),
                ),
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
                    onPressed:
                        _applying ? null : () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: Consumer(builder: (context, ref, _) {
                    final isPro = ref.watch(isProProvider);
                    final noOp = plan.isNoOp;
                    return FilledButton.icon(
                      onPressed:
                          _applying || noOp ? null : () => _apply(plan),
                      icon: _applying
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child:
                                  CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(noOp
                              ? Icons.check_circle_outline_rounded
                              : isPro
                                  ? Icons.check_rounded
                                  : Icons.lock_rounded),
                      label: Text(noOp
                          ? 'Already applied'
                          : 'Apply plan — ${plan.changes.length} '
                              '${plan.changes.length == 1 ? 'move' : 'moves'}'),
                    );
                  }),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _apply(DistributionPlan plan) async {
    setState(() => _applying = true);
    try {
      // Preview is free; APPLY is the Pro gate — with copy that speaks to
      // the plan they're already looking at.
      if (!ref.read(isProProvider)) {
        AnalyticsService.instance.paywallViewed('auto_plan');
        final upgraded =
            await showPaywall(context, trigger: PaywallTrigger.autoPlan);
        if (!upgraded || !mounted) return;
      }

      final result =
          await ref.read(tripProvider.notifier).applyDistribution(plan);
      if (!mounted) return;
      switch (result.status) {
        case ApplyDistributionStatus.denied:
          AppToast.error(context, "You don't have edit access to this trip.");
        case ApplyDistributionStatus.stale:
          AppToast.info(context, 'Trip changed — updated the preview.');
          ref.invalidate(autoPlanProvider);
        case ApplyDistributionStatus.applied:
          AnalyticsService.instance.autoPlanApplied(
              moved: result.moved, toBucket: result.toBucket);
          final notifier = ref.read(tripProvider.notifier);
          final buckets = result.toBucket;
          // Outlives this sheet: the root navigator's context stays valid
          // for the follow-up toasts fired from the Undo callback.
          final rootCtx = Navigator.of(context, rootNavigator: true).context;
          // App-style toast with an inline Undo + the close X. It lives in
          // the ROOT overlay, so it's shown first and survives the pop.
          AppToast.success(
            context,
            'Days planned — ${result.moved} moved'
            '${buckets > 0 ? ', $buckets to Unscheduled' : ''}.',
            duration: const Duration(seconds: 8),
            actionLabel: 'Undo',
            onAction: () async {
              final reverted = await notifier.revertDistribution();
              if (!rootCtx.mounted) return;
              if (reverted) {
                AnalyticsService.instance.autoPlanUndone();
                AppToast.info(rootCtx, 'Plan undone — days restored.');
              } else {
                AppToast.warning(
                    rootCtx, "Trip changed since — couldn't undo.");
              }
            },
          );
          Navigator.of(context).pop();
      }
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }
}

class _Message extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Message({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon,
                size: 44,
                color: theme.colorScheme.primary.withValues(alpha: 0.5)),
            const SizedBox(height: 14),
            Text(text,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }
}

class _NeedsDates extends StatelessWidget {
  final VoidCallback onSet;
  const _NeedsDates({required this.onSet});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.calendar_month_rounded,
                size: 44,
                color: theme.colorScheme.primary.withValues(alpha: 0.6)),
            const SizedBox(height: 14),
            Text(
              'Set the trip dates first — the planner needs to know how '
              'many days it can fill.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onSet,
              icon: const Icon(Icons.edit_calendar_rounded),
              label: const Text('Set trip dates'),
            ),
          ],
        ),
      ),
    );
  }
}

class _CityOrderStrip extends ConsumerWidget {
  final List<CityCluster> clusters;
  const _CityOrderStrip({required this.clusters});

  /// Offline/unknown-locality fallback: name of the member closest to the
  /// cluster centroid.
  String _fallbackLabel(CityCluster c) {
    if (c.members.isEmpty) return 'Area';
    var best = c.members.first;
    var bestD = double.infinity;
    for (final m in c.members) {
      final d = (m.lat - c.centroidLat) * (m.lat - c.centroidLat) +
          (m.lng - c.centroidLng) * (m.lng - c.centroidLng);
      if (d < bestD) {
        bestD = d;
        best = m;
      }
    }
    return 'Around ${best.name}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      runSpacing: 6,
      children: [
        for (var i = 0; i < clusters.length; i++) ...[
          if (i > 0)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Icon(Icons.arrow_forward_rounded,
                  size: 15,
                  color:
                      theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6)),
            ),
          Consumer(builder: (context, ref, _) {
            final label = ref.watch(clusterLabelProvider((
              lat: clusters[i].centroidLat,
              lng: clusters[i].centroidLng,
            )));
            final text = label.valueOrNull ?? _fallbackLabel(clusters[i]);
            return Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(9),
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 150),
                child: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            );
          }),
        ],
      ],
    );
  }
}

class _DayCard extends StatelessWidget {
  final PlannedDay planned;
  final Map<String, LocationModel> byId;
  final Map<String, DateTime?> oldDayById;
  final DateTime? tripStart;
  final Color color;
  final CityCluster? cluster;
  final List<DistributionWarning> warnings;

  const _DayCard({
    required this.planned,
    required this.byId,
    required this.oldDayById,
    required this.tripStart,
    required this.color,
    required this.cluster,
    required this.warnings,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dayNumber = tripStart == null
        ? null
        : planned.day
                .difference(DateTime(
                    tripStart!.year, tripStart!.month, tripStart!.day))
                .inDays +
            1;
    final hours = (planned.usedMinutes / 60).toStringAsFixed(1);
    final closedIdsToday = {
      for (final w in warnings)
        if (w.kind == DistributionWarningKind.closedOnDay &&
            w.day == planned.day)
          w.placeId
    };

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: theme.cardColor.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(14),
        border:
            Border.all(color: theme.dividerColor.withValues(alpha: 0.4)),
      ),
      child: Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 12),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
          leading: Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          title: Text(
            '${dayNumber != null ? 'Day $dayNumber · ' : ''}'
            '${DateFormat('EEE, MMM d').format(planned.day)}',
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          subtitle: Text(
            '${planned.stopIds.length} '
            '${planned.stopIds.length == 1 ? 'place' : 'places'} · ~${hours}h'
            '${planned.hopMinutes > 0 ? ' · travel morning' : ''}'
            '${planned.accommodationId != null ? '\n🏨 ${byId[planned.accommodationId]?.name ?? 'Your stay'}' : ''}',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          children: [
            for (final id in planned.stopIds)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    if (closedIdsToday.contains(id))
                      const Padding(
                        padding: EdgeInsets.only(right: 6),
                        child: Text('⚠', style: TextStyle(fontSize: 13)),
                      ),
                    Expanded(
                      child: Text(
                        byId[id]?.name ?? id,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    if (oldDayById.containsKey(id))
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary
                              .withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          oldDayById[id] == null
                              ? 'was Unscheduled'
                              : 'was ${DateFormat('MMM d').format(oldDayById[id]!)}',
                          style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.w600),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _OverflowSection extends StatelessWidget {
  final List<String> ids;
  final Map<String, LocationModel> byId;
  final int? maxStops;
  final int? deficitMinutes;
  final Future<void> Function()? onAddDay;

  const _OverflowSection({
    required this.ids,
    required this.byId,
    required this.maxStops,
    required this.deficitMinutes,
    required this.onAddDay,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const amber = Color(0xFFFFB300);
    final deficitH =
        deficitMinutes == null ? null : (deficitMinutes! / 60).ceil();

    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: amber.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: amber.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.inventory_2_outlined, size: 16, color: amber),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  "${ids.length} ${ids.length == 1 ? "place doesn't" : "places don't"} "
                  'fit — they\'ll wait in Unscheduled',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(color: amber, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              maxStops != null
                  ? 'With a limit of $maxStops places a day, these are '
                      'left over — add days or raise the limit.'
                  : deficitH != null
                      ? 'Fitting everything needs roughly $deficitH more '
                          '${deficitH == 1 ? 'hour' : 'hours'} of trip time.'
                      : 'Add a day to fit them.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            [for (final id in ids.take(6)) byId[id]?.name ?? id].join(' · ') +
                (ids.length > 6 ? ' · +${ids.length - 6} more' : ''),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
          if (onAddDay != null)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () => onAddDay!(),
                icon: const Icon(Icons.add_rounded, size: 16),
                label: const Text('Add a day'),
                style: TextButton.styleFrom(foregroundColor: amber),
              ),
            ),
        ],
      ),
    );
  }
}

/// "Places per day" chips: Auto (capacity only) or a hard cap. Writes the
/// live provider (the plan recomputes instantly — the engine is pure and
/// fast) and persists the choice as a traveller preference.
class _MaxStopsSelector extends ConsumerWidget {
  const _MaxStopsSelector();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final current = ref.watch(autoPlanMaxStopsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Max places per day',
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.3,
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            for (final choice in LegModePrefs.autoPlanMaxStopsChoices)
              ChoiceChip(
                label: Text(choice == null ? 'Auto' : '$choice'),
                selected: current == choice,
                onSelected: (_) {
                  ref.read(autoPlanMaxStopsProvider.notifier).state = choice;
                  LegModePrefs.setAutoPlanMaxStops(choice);
                },
                showCheckmark: false,
                visualDensity: VisualDensity.compact,
                labelStyle: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: current == choice
                      ? theme.colorScheme.onPrimary
                      : theme.colorScheme.onSurface,
                ),
                selectedColor: theme.colorScheme.primary,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(9)),
              ),
          ],
        ),
        if (current == null) ...[
          const SizedBox(height: 4),
          Text(
            'Auto fits every place across your days, balanced by city. '
            'Packed days get a warning; pick a number to cap each day '
            'instead.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
        // With a limit set, HOW to use it is a real choice: even days, or
        // full days with the rest left free.
        if (current != null) ...[
          const SizedBox(height: 10),
          Consumer(builder: (context, ref, _) {
            final style = ref.watch(autoPlanFillStyleProvider);
            Widget chip(FillStyle value, String label, String hint) {
              final selected = style == value;
              return Tooltip(
                message: hint,
                child: ChoiceChip(
                  label: Text(label),
                  selected: selected,
                  onSelected: (_) {
                    ref.read(autoPlanFillStyleProvider.notifier).state = value;
                    LegModePrefs.setAutoPlanFillStyle(
                        value == FillStyle.pack ? 'pack' : 'balanced');
                  },
                  showCheckmark: false,
                  visualDensity: VisualDensity.compact,
                  labelStyle: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: selected
                        ? theme.colorScheme.onPrimary
                        : theme.colorScheme.onSurface,
                  ),
                  selectedColor: theme.colorScheme.primary,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(9)),
                ),
              );
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    chip(FillStyle.balanced, 'Spread evenly',
                        'Even counts across all your days'),
                    chip(FillStyle.pack, 'Fill up to the limit',
                        'Full days first; leftover days stay free'),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  style == FillStyle.pack
                      ? 'Each day takes up to $current places; any days left '
                          'over stay free.'
                      : 'Your places are split evenly across the days, never '
                          'more than $current a day.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            );
          }),
        ],
      ],
    );
  }
}

/// A day the plan deliberately leaves empty (pack style).
class _FreeDayCard extends StatelessWidget {
  final DateTime day;
  final DateTime? tripStart;
  const _FreeDayCard({required this.day, required this.tripStart});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dayNumber = tripStart == null
        ? null
        : day
                .difference(DateTime(
                    tripStart!.year, tripStart!.month, tripStart!.day))
                .inDays +
            1;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: theme.dividerColor.withValues(alpha: 0.5), width: 1.2),
      ),
      child: Row(
        children: [
          Icon(Icons.self_improvement_rounded,
              size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '${dayNumber != null ? 'Day $dayNumber · ' : ''}'
              '${DateFormat('EEE, MMM d').format(day)} — free day',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

/// "Keep places on their current days when possible" — on by default
/// (minimal disruption). Off = plan from scratch: the engine's ideal
/// arrangement regardless of today's placements.
class _KeepCurrentSwitch extends ConsumerWidget {
  const _KeepCurrentSwitch();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final keep = ref.watch(autoPlanKeepCurrentProvider);
    return Container(
      decoration: BoxDecoration(
        color: theme.cardColor.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.dividerColor.withValues(alpha: 0.4)),
      ),
      child: SwitchListTile.adaptive(
        value: keep,
        onChanged: (v) =>
            ref.read(autoPlanKeepCurrentProvider.notifier).state = v,
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
        title: Text('Keep places on their current days when possible',
            style: theme.textTheme.bodyMedium
                ?.copyWith(fontWeight: FontWeight.w600)),
        subtitle: Text(
          keep
              ? 'Only moves what has to move.'
              : 'Fresh arrangement: regroups every day by geography and '
                  'balance.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        activeTrackColor: theme.colorScheme.primary,
      ),
    );
  }
}
