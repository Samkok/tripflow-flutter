import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:dio/dio.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:voyza/models/location_model.dart';
import 'package:voyza/providers/map_ui_state_provider.dart';
import 'package:voyza/providers/trip_listener_provider.dart';
import 'package:voyza/providers/trip_provider.dart';
import 'package:voyza/providers/trip_collaborator_provider.dart';
import 'package:voyza/widgets/location_detail_sheet.dart';
import 'package:voyza/widgets/photo_gallery_viewer.dart';
import 'package:voyza/services/photo_service.dart';
import 'package:voyza/services/photo_cache_service.dart';
import 'package:voyza/utils/date_picker_utils.dart';
import 'package:voyza/utils/trip_date_validator.dart';

/// Optimized location card widget that minimizes rebuilds
/// Uses selective provider watching and RepaintBoundary for better performance.
///
/// The card is collapsible: collapsed shows the standard ListTile, expanded
/// reveals a horizontal scrolling gallery of up to 5 photos that open in a
/// full-screen viewer when tapped.
class OptimizedLocationCard extends ConsumerStatefulWidget {
  final LocationModel location;
  final int number;
  final ScrollController scrollController;
  final DraggableScrollableController? sheetController;
  final Function(LatLng)? onLocationTap;

  const OptimizedLocationCard({
    super.key,
    required this.location,
    required this.number,
    required this.scrollController,
    required this.sheetController,
    required this.onLocationTap,
  });

  @override
  ConsumerState<OptimizedLocationCard> createState() =>
      _OptimizedLocationCardState();
}

class _OptimizedLocationCardState extends ConsumerState<OptimizedLocationCard> {
  // PERFORMANCE: Static cache for photo URL futures to prevent re-fetching on
  // rebuild. Shared across all card instances since photo refs are unique.
  static final Map<String, Future<String?>> _photoUrlCache = {};

  bool _isExpanded = false;

  LocationModel get location => widget.location;
  int get number => widget.number;

  @override
  Widget build(BuildContext context) {
    // OPTIMIZATION: Use .select() to watch only specific values
    // This prevents rebuilds when unrelated state changes
    final pinnedLocations =
        ref.watch(tripProvider.select((s) => s.pinnedLocations));
    final index = pinnedLocations.indexOf(location);

    final isHighlighted = ref.watch(highlightedLocationIndexProvider) == index;
    final isSelectionMode = ref.watch(isSelectionModeProvider);
    final isSelected = ref.watch(
        selectedLocationsProvider.select((s) => s.contains(location.id)));

    final photoRefs = location.photoReferences;
    final hasPhotos = photoRefs.isNotEmpty;

    // OPTIMIZATION: Wrap in RepaintBoundary to isolate repaints
    return RepaintBoundary(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200), // Reduced from 300ms
        decoration: BoxDecoration(
          color: isSelected
              ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.25)
              : (isHighlighted
                  ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.1)
                  : Theme.of(context).cardColor),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isHighlighted
                ? Theme.of(context).colorScheme.primary
                : Colors.transparent,
            width: 2,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.1),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        margin: const EdgeInsets.symmetric(vertical: 8.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ListTile(
              onTap: () =>
                  _handleTap(context, ref, isSelectionMode, isSelected),
              onLongPress: () => _handleLongPress(ref, isSelectionMode),
              leading: _buildFallbackAvatar(context),
              title: _buildTitle(context),
              subtitle: _buildSubtitle(context),
              trailing: isSelectionMode
                  ? _buildCheckbox(ref, isSelected)
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (hasPhotos)
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            tooltip: _isExpanded ? 'Hide photos' : 'Show photos',
                            icon: AnimatedRotation(
                              turns: _isExpanded ? 0.5 : 0,
                              duration: const Duration(milliseconds: 200),
                              child: const Icon(Icons.expand_more),
                            ),
                            onPressed: () => setState(
                                () => _isExpanded = !_isExpanded),
                          ),
                        _buildPopupMenu(context, ref),
                      ],
                    ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOut,
              alignment: Alignment.topCenter,
              child: hasPhotos && _isExpanded
                  ? _buildPhotoGallery(context, photoRefs)
                  : const SizedBox(width: double.infinity, height: 0),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPhotoGallery(BuildContext context, List<String> photoRefs) {
    const double tileWidth = 140;
    const double tileHeight = 100;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: SizedBox(
        height: tileHeight,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: photoRefs.length,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (context, index) {
            final ref = photoRefs[index];
            final future = _photoUrlCache.putIfAbsent(
              ref,
              () => _loadPhotoUrl(ref),
            );
            return FutureBuilder<String?>(
              future: future,
              builder: (context, snapshot) {
                final url = snapshot.data;
                final placeholder = Container(
                  width: tileWidth,
                  height: tileHeight,
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .primary
                        .withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: snapshot.connectionState == ConnectionState.waiting
                      ? const Center(
                          child: SizedBox(
                            width: 24,
                            height: 24,
                            child:
                                CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : Icon(
                          Icons.broken_image_outlined,
                          color: Theme.of(context)
                              .iconTheme
                              .color
                              ?.withValues(alpha: 0.4),
                        ),
                );

                if (url == null) return placeholder;

                return GestureDetector(
                  onTap: () => _openGallery(context, photoRefs, index),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Hero(
                      tag: '${location.id}_photo_$index',
                      child: CachedNetworkImage(
                        imageUrl: url,
                        width: tileWidth,
                        height: tileHeight,
                        fit: BoxFit.cover,
                        memCacheWidth: (tileWidth * 2).round(),
                        memCacheHeight: (tileHeight * 2).round(),
                        placeholder: (_, __) => placeholder,
                        errorWidget: (_, __, ___) => placeholder,
                      ),
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }

  Future<void> _openGallery(
      BuildContext context, List<String> photoRefs, int initialIndex) async {
    // Resolve every ref to its CDN URL up front so the viewer's PageView
    // doesn't have to chase redirects mid-swipe.
    final urls = await Future.wait(photoRefs.map((r) {
      return _photoUrlCache.putIfAbsent(r, () => _loadPhotoUrl(r));
    }));
    final resolved = urls.whereType<String>().toList();
    if (resolved.isEmpty || !context.mounted) return;
    await showPhotoGalleryViewer(
      context: context,
      photoUrls: resolved,
      initialIndex: initialIndex.clamp(0, resolved.length - 1),
      heroTagPrefix: '${location.id}_photo',
      title: location.name,
    );
  }

  Widget _buildFallbackAvatar(BuildContext context, {bool showLoading = false}) {
    final isSkipped = location.isSkipped;
    final isDone = location.isDone;

    Color bgColor;
    if (isDone) {
      bgColor = Colors.green.shade500;
    } else if (isSkipped) {
      bgColor = Colors.grey;
    } else {
      bgColor = Theme.of(context).colorScheme.primary;
    }

    return CircleAvatar(
      backgroundColor: bgColor,
      child: showLoading
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
              ),
            )
          : isDone
              ? const Icon(Icons.check, color: Colors.white, size: 20)
              : Text(
                  isSkipped ? '-' : '$number',
                  style: const TextStyle(
                    color: Colors.black,
                    fontWeight: FontWeight.bold,
                  ),
                ),
    );
  }

  Future<String?> _loadPhotoUrl(String photoReference) async {
    final cache = PhotoCacheService();

    // Check cache first
    String? url = await cache.getPhotoUrl(photoReference);
    if (url != null) return url;

    // Fetch from Google
    try {
      url = PhotoService.getPhotoUrl(photoReference: photoReference);

      // Follow redirect to get actual URL
      final response = await Dio().head(
        url,
        options: Options(followRedirects: true, maxRedirects: 5),
      );
      final actualUrl = response.realUri.toString();

      // Cache it
      await cache.cachePhotoUrl(photoReference, actualUrl);

      return actualUrl;
    } catch (e) {
      debugPrint('Error loading photo: $e');
      return null;
    }
  }

  void _handleTap(BuildContext context, WidgetRef ref, bool isSelectionMode,
      bool isSelected) {
    if (isSelectionMode) {
      final selectedNotifier = ref.read(selectedLocationsProvider.notifier);
      if (isSelected) {
        selectedNotifier.update((state) => state.difference({location.id}));
      } else {
        selectedNotifier.update((state) => state.union({location.id}));
      }
    } else {
      showModalBottomSheet(
        context: context,
        backgroundColor: Colors.transparent,
        isScrollControlled: true,
        builder: (modalContext) => LocationDetailSheet(
          location: location,
          number: number,
          parentScrollController: widget.scrollController,
          parentSheetController: widget.sheetController,
          onLocationTap: widget.onLocationTap,
        ),
      );
    }
  }

  void _handleLongPress(WidgetRef ref, bool isSelectionMode) {
    if (!isSelectionMode) {
      ref.read(isSelectionModeProvider.notifier).state = true;
      ref
          .read(selectedLocationsProvider.notifier)
          .update((state) => state.union({location.id}));
    }
  }

  Widget _buildTitle(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                location.name,
                style: Theme.of(context).textTheme.titleMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        if (location.travelTimeFromPrevious != null &&
            location.distanceFromPrevious != null) ...[
          const SizedBox(height: 4),
          _buildTravelInfo(context),
        ],
      ],
    );
  }

  Widget _buildTravelInfo(BuildContext context) {
    return Row(
      children: [
        Icon(
          Icons.access_time,
          size: 14,
          color: Theme.of(context).colorScheme.primary,
        ),
        const SizedBox(width: 4),
        Text(
          _formatDuration(location.travelTimeFromPrevious!),
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w500,
              ),
        ),
        const SizedBox(width: 12),
        Icon(
          Icons.straighten,
          size: 14,
          color: Theme.of(context).colorScheme.primary,
        ),
        const SizedBox(width: 4),
        Text(
          _formatDistance(location.distanceFromPrevious!),
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w500,
              ),
        ),
      ],
    );
  }

  Widget _buildSubtitle(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        location.address,
        style: Theme.of(context).textTheme.bodyMedium,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  Widget _buildCheckbox(WidgetRef ref, bool isSelected) {
    return Checkbox(
      value: isSelected,
      onChanged: (bool? value) {
        final selectedNotifier = ref.read(selectedLocationsProvider.notifier);
        if (value == true) {
          selectedNotifier.update((state) => state.union({location.id}));
        } else {
          selectedNotifier.update((state) => state.difference({location.id}));
        }
      },
    );
  }

  Widget _buildPopupMenu(BuildContext context, WidgetRef ref) {
    // Check if user has write access to the active trip
    final hasWriteAccessAsync = ref.watch(hasActiveTripWriteAccessProvider);
    final hasWriteAccess = hasWriteAccessAsync.asData?.value ?? false;

    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert),
      onSelected: (value) {
        // Check write access for all write operations except copy
        if (!hasWriteAccess && value != 'copy') {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('You don\'t have permission to modify locations in this trip.'),
              backgroundColor: Colors.orange,
            ),
          );
          return;
        }
        _handleMenuSelection(context, value, ref);
      },
      itemBuilder: (context) {
        final isPastDate = ref.read(selectedDateProvider).isBefore(DateTime(
            DateTime.now().year, DateTime.now().month, DateTime.now().day));

        // Can edit only if not past date AND has write access
        final canEdit = !isPastDate && hasWriteAccess;

        return [
          if (location.isSkipped)
            PopupMenuItem<String>(
              value: 'unskip',
              enabled: canEdit,
              child: ListTile(
                  leading: Icon(Icons.add_circle_outline,
                      color: canEdit ? null : Colors.grey),
                  title: Text('Un-skip',
                      style: TextStyle(color: canEdit ? null : Colors.grey))),
            )
          else
            PopupMenuItem<String>(
              value: 'skip',
              enabled: canEdit,
              child: ListTile(
                  leading: Icon(Icons.remove_circle_outline,
                      color: canEdit ? null : Colors.grey),
                  title: Text('Skip',
                      style: TextStyle(color: canEdit ? null : Colors.grey))),
            ),
          PopupMenuItem<String>(
            value: location.isDone ? 'undone' : 'done',
            enabled: hasWriteAccess,
            child: ListTile(
              leading: Icon(
                location.isDone ? Icons.cancel_outlined : Icons.check_circle_outline,
                color: hasWriteAccess ? Colors.green : Colors.grey,
              ),
              title: Text(
                location.isDone ? 'Unmark as Done' : 'Mark as Done',
                style: TextStyle(color: hasWriteAccess ? Colors.green : Colors.grey),
              ),
            ),
          ),
          PopupMenuItem<String>(
            value: 'move',
            enabled: canEdit,
            child: ListTile(
                leading: Icon(Icons.calendar_today_outlined,
                    color: canEdit ? null : Colors.grey),
                title: Text('Move to...',
                    style: TextStyle(color: canEdit ? null : Colors.grey))),
          ),
          const PopupMenuItem<String>(
            value: 'copy',
            child:
                ListTile(leading: Icon(Icons.copy), title: Text('Copy to...')),
          ),
          const PopupMenuDivider(),
          PopupMenuItem<String>(
              value: 'delete',
              enabled: hasWriteAccess,
              child: ListTile(
                  leading: Icon(Icons.delete_outline,
                      color: hasWriteAccess ? Colors.red : Colors.grey),
                  title: Text('Delete',
                      style: TextStyle(
                          color: hasWriteAccess ? Colors.red : Colors.grey)))),
        ];
      },
    );
  }

  void _handleMenuSelection(BuildContext context, String value, WidgetRef ref) {
    final selectedIds = {location.id};

    if (value == 'delete') {
      _showDeleteConfirmationDialog(context, ref);
    } else if (value == 'skip') {
      ref.read(tripProvider.notifier).skipMultipleLocations(selectedIds);
    } else if (value == 'unskip') {
      ref.read(tripProvider.notifier).unskipMultipleLocations(selectedIds);
    } else if (value == 'move') {
      _showMoveCopyDialog(context, ref, isCopy: false);
    } else if (value == 'copy') {
      _showMoveCopyDialog(context, ref, isCopy: true);
    } else if (value == 'done') {
      ref.read(tripProvider.notifier).markLocationsAsDone({location.id});
    } else if (value == 'undone') {
      ref.read(tripProvider.notifier).unmarkLocationsAsDone({location.id});
    }
  }

  void _showMoveCopyDialog(BuildContext context, WidgetRef ref, {required bool isCopy}) async {
    final highlightedDates = ref.read(datesWithLocationsProvider);
    final earliestDate = highlightedDates.isNotEmpty
        ? highlightedDates.reduce((a, b) => a.isBefore(b) ? a : b)
        : DateTime.now();

    final newDate = await DatePickerUtils.showCustomDatePicker(
      context: context,
      initialDate: ref.read(selectedDateProvider),
      firstDate: earliestDate,
      lastDate: DateTime.now().add(const Duration(days: 365 * 5)),
      highlightedDates: highlightedDates,
    );

    if (newDate != null) {
      final activeTrip = ref.read(realtimeActiveTripProvider).asData?.value;
      if (!context.mounted) return;
      final allowed = await ensureScheduledDateAllowed(
        context,
        activeTrip,
        newDate,
        actionLabel: isCopy ? 'Copy anyway' : 'Move anyway',
      );
      if (!allowed) return;

      final selectedIds = {location.id};
      if (isCopy) {
        await ref.read(tripProvider.notifier).copyMultipleLocationsToDate(selectedIds, newDate);
      } else {
        await ref.read(tripProvider.notifier).updateMultipleLocationsScheduledDate(selectedIds, newDate);
      }
      ref.read(selectedDateProvider.notifier).state = newDate;
    }
  }

  void _showDeleteConfirmationDialog(BuildContext context, WidgetRef ref) {
    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: Theme.of(context).cardColor,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('Delete Location'),
          content: Text(
              'Are you sure you want to delete "${location.name}"? This action cannot be undone.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text('Cancel',
                  style: TextStyle(
                      color: Theme.of(context).textTheme.bodyMedium?.color)),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                ref.read(tripProvider.notifier).removeLocation(location.id);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Deleted ${location.name}'),
                    backgroundColor: Theme.of(context).colorScheme.error,
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
                foregroundColor: Theme.of(context).colorScheme.onError,
              ),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes % 60;

    if (hours > 0) {
      return '${hours}h ${minutes}m';
    } else {
      return '${minutes}m';
    }
  }

  String _formatDistance(double distanceInMeters) {
    if (distanceInMeters < 1000) {
      return '${distanceInMeters.toInt()}m';
    } else {
      final kilometers = distanceInMeters / 1000;
      return '${kilometers.toStringAsFixed(1)}km';
    }
  }
}
