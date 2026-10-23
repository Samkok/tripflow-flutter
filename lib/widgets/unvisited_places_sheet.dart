import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/location_model.dart';
import '../models/trip.dart';
import '../providers/trip_collaborator_provider.dart';
import '../providers/trip_provider.dart';
import '../utils/trip_day_labels.dart';
import 'app_toast.dart';
import 'move_to_trip_sheet.dart';

/// The ended trip's review: the places never ticked off, each to delete or
/// to move to another trip. [places] is the list at opening time; the sheet
/// drops rows as they are dealt with and closes once none remain.
Future<void> showUnvisitedPlacesSheet(
  BuildContext context, {
  required Trip trip,
  required List<LocationModel> places,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => UnvisitedPlacesSheet(trip: trip, places: places),
  );
}

class UnvisitedPlacesSheet extends ConsumerStatefulWidget {
  const UnvisitedPlacesSheet({
    super.key,
    required this.trip,
    required this.places,
  });

  final Trip trip;
  final List<LocationModel> places;

  @override
  ConsumerState<UnvisitedPlacesSheet> createState() =>
      _UnvisitedPlacesSheetState();
}

class _UnvisitedPlacesSheetState extends ConsumerState<UnvisitedPlacesSheet> {
  late final List<LocationModel> _places = List.of(widget.places);
  late final Set<String> _selected = {for (final p in _places) p.id};
  bool _busy = false;

  List<LocationModel> get _picked =>
      _places.where((p) => _selected.contains(p.id)).toList();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canWrite =
        ref.watch(hasWriteAccessProvider(widget.trip.id)).valueOrNull ?? false;
    final label = DayLabeler.forTrip(widget.trip);
    final total = _places.length;
    final picked = _selected.length;
    final allPicked = picked == total && total > 0;
    final actionsOn = canWrite && !_busy && picked > 0;

    return DraggableScrollableSheet(
      initialChildSize: 0.65,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: theme.scaffoldBackgroundColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
                child: Row(
                  children: [
                    const SizedBox(width: 48),
                    Expanded(
                      child: Column(
                        children: [
                          Text(
                            'Not visited',
                            style: theme.textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.bold),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${widget.trip.name} has ended · '
                            '$total place${total == 1 ? '' : 's'} you never got to',
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant),
                            textAlign: TextAlign.center,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: 'Close',
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    TextButton.icon(
                      onPressed: canWrite && !_busy
                          ? () => setState(() {
                                if (allPicked) {
                                  _selected.clear();
                                } else {
                                  _selected.addAll(_places.map((p) => p.id));
                                }
                              })
                          : null,
                      icon: Icon(allPicked
                          ? Icons.check_box_rounded
                          : Icons.check_box_outline_blank_rounded),
                      label: Text(allPicked ? 'Clear all' : 'Select all'),
                    ),
                    const Spacer(),
                    Text(
                      '$picked selected',
                      style: theme.textTheme.labelMedium
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              if (!canWrite)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    'You can only view this trip.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              if (_busy)
                const LinearProgressIndicator(minHeight: 2)
              else
                const Divider(height: 1),
              Expanded(
                child: ListView.separated(
                  controller: scrollController,
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                  itemCount: _places.length,
                  separatorBuilder: (_, __) =>
                      const Divider(height: 1, indent: 56),
                  itemBuilder: (context, i) {
                    final p = _places[i];
                    final day = p.scheduledDate;
                    return CheckboxListTile(
                      value: _selected.contains(p.id),
                      onChanged: canWrite && !_busy
                          ? (v) => setState(() {
                                if (v == true) {
                                  _selected.add(p.id);
                                } else {
                                  _selected.remove(p.id);
                                }
                              })
                          : null,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: Text(p.name,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(day == null
                          ? 'Unscheduled'
                          : label(day, pattern: 'EEE, MMM d')),
                      secondary: Icon(Icons.place_outlined,
                          color: theme.colorScheme.onSurfaceVariant),
                    );
                  },
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: actionsOn ? _delete : null,
                          icon: const Icon(Icons.delete_outline),
                          label: const Text('Delete'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: theme.colorScheme.error,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: actionsOn ? _move : null,
                          icon: const Icon(Icons.luggage_outlined),
                          label: const Text('Move to trip'),
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

  Future<void> _move() async {
    final picks = _picked;
    if (picks.isEmpty) return;
    final moved =
        await showMoveToTripSheet(context, ref, picks, sourceTrip: widget.trip);
    if (!mounted || !moved) return;
    _dropRows({for (final p in picks) p.id});
  }

  Future<void> _delete() async {
    final picks = _picked;
    if (picks.isEmpty) return;
    final n = picks.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Delete $n place${n == 1 ? '' : 's'}?'),
        content: Text(
          '${n == 1 ? 'It was' : 'They were'} never visited on '
          '"${widget.trip.name}". This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    final ids = {for (final p in picks) p.id};
    final ok = await ref
        .read(tripProvider.notifier)
        .deleteLocationsOfTrip(ids, tripId: widget.trip.id);
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) {
      AppToast.error(context, 'Could not delete every place. Try again.');
      return;
    }
    AppToast.success(context, 'Deleted $n place${n == 1 ? '' : 's'}');
    _dropRows(ids);
  }

  void _dropRows(Set<String> ids) {
    setState(() {
      _places.removeWhere((p) => ids.contains(p.id));
      _selected.removeAll(ids);
    });
    if (_places.isEmpty) Navigator.of(context).pop();
  }
}
