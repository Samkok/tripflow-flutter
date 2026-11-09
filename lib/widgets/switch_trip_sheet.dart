import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../models/trip.dart';
import '../providers/local_active_trip_provider.dart';
import '../providers/onboarding_provider.dart';
import '../providers/trip_collaborator_provider.dart';
import '../providers/user_trip_provider.dart';
import '../utils/countries.dart';
import '../utils/open_trip_on_map.dart';

/// "Which trip should the map show?" — every trip the user can open, the
/// current one marked. Picking one makes it the map trip and lands on its
/// day. With no trips at all it points to the Trips tab instead.
Future<void> showSwitchTripSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const SwitchTripSheet(),
  );
}

typedef _Row = ({Trip trip, String? permission});

class SwitchTripSheet extends ConsumerWidget {
  const SwitchTripSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final own = ref.watch(userTripsProvider);
    final shared = ref.watch(sharedTripsProvider);
    final onMapId = ref.watch(localActiveTripIdProvider);

    return DraggableScrollableSheet(
      initialChildSize: 0.55,
      minChildSize: 0.35,
      maxChildSize: 0.92,
      expand: false,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: theme.scaffoldBackgroundColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 8, 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Show on the map',
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: own.isLoading && !own.hasValue
                    ? const Center(
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : _list(context, ref, scrollController,
                        _rows(own.valueOrNull, shared.valueOrNull), onMapId),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Own trips first, then shared ones, each group by start date (undated
  /// trips sit on the far-future anchor, so they fall last on their own).
  List<_Row> _rows(List<Trip>? own, List<Map<String, dynamic>>? shared) {
    int byStart(_Row a, _Row b) {
      final x = a.trip.startDate, y = b.trip.startDate;
      if (x == null || y == null) return x == null ? (y == null ? 0 : 1) : -1;
      return x.compareTo(y);
    }

    final mine = [
      for (final t in own ?? const <Trip>[]) (trip: t, permission: null)
    ]..sort(byStart);
    final theirs = <_Row>[];
    for (final row in shared ?? const <Map<String, dynamic>>[]) {
      final raw = row['trips'];
      if (raw is! Map) continue;
      try {
        theirs.add((
          trip: Trip.fromJson(Map<String, dynamic>.from(raw)),
          permission: row['permission']?.toString(),
        ));
      } catch (_) {
        // An incomplete embed row is left out rather than crashing the list.
      }
    }
    theirs.sort(byStart);
    return [...mine, ...theirs];
  }

  Widget _list(BuildContext context, WidgetRef ref, ScrollController controller,
      List<_Row> rows, String? onMapId) {
    final theme = Theme.of(context);
    if (rows.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Create a trip first — the map draws one trip at a time.',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () {
                Navigator.of(context).pop();
                ref.read(mainTabRequestProvider.notifier).state = 0;
              },
              icon: const Icon(Icons.add),
              label: const Text('Create a trip'),
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 24),
      itemCount: rows.length,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 56),
      itemBuilder: (context, i) {
        final row = rows[i];
        final trip = row.trip;
        final onMap = trip.id == onMapId;
        return ListTile(
          leading: Icon(
            onMap ? Icons.map_rounded : Icons.luggage_outlined,
            color: theme.colorScheme.primary,
          ),
          title: Text(trip.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(_subtitle(row),
              maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: onMap
              ? Text('On the map',
                  style: theme.textTheme.labelMedium
                      ?.copyWith(color: theme.colorScheme.primary))
              : const Icon(Icons.chevron_right),
          selected: onMap,
          onTap: onMap
              ? () => Navigator.of(context).pop()
              : () async {
                  await openTripOnMap(ref, trip);
                  if (context.mounted) Navigator.of(context).pop();
                },
        );
      },
    );
  }

  /// "Japan · Nov 5 – Nov 9", "No dates yet", "Shared · View only · …".
  String _subtitle(_Row row) {
    final trip = row.trip;
    final parts = <String>[];
    if (row.permission != null) {
      parts.add(row.permission == 'write'
          ? 'Shared · Can edit'
          : 'Shared · View only');
    }
    final country = findCountryByCode(trip.countryCode)?.name;
    if (country != null) parts.add(country);
    if (trip.isUndated) {
      parts.add('No dates yet');
    } else if (trip.startDate != null && trip.endDate != null) {
      final fmt = DateFormat('MMM d');
      parts
          .add('${fmt.format(trip.startDate!)} – ${fmt.format(trip.endDate!)}');
    }
    return parts.join(' · ');
  }
}
