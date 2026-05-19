import 'package:flutter/material.dart';
import 'package:voyza/services/places_service.dart';
import 'package:voyza/widgets/location_photo_gallery.dart';

/// Bottom sheet shown after a long-press on the map: lists every POI within
/// the configured radius (Google Places Nearby Search), lets the user
/// multi-select, and returns the chosen [NearbyPlace]s on confirm.
///
/// Returns an empty list / null on cancel — callers should treat both as
/// "no add". Distance to each place is shown in the subtitle so the user
/// can quickly see what they're picking from.
class NearbyPlacesPickerSheet extends StatefulWidget {
  final List<NearbyPlace> places;
  final int radiusMeters;

  const NearbyPlacesPickerSheet({
    super.key,
    required this.places,
    required this.radiusMeters,
  });

  @override
  State<NearbyPlacesPickerSheet> createState() =>
      _NearbyPlacesPickerSheetState();
}

class _NearbyPlacesPickerSheetState extends State<NearbyPlacesPickerSheet> {
  final Set<String> _selected = {};
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Case-insensitive substring match on name, vicinity, and humanized
  /// primary type — same fields that feed the tile's title/subtitle so
  /// the user can filter by what they actually see on screen.
  List<NearbyPlace> _filtered(List<NearbyPlace> source) {
    if (_query.isEmpty) return source;
    final q = _query.toLowerCase();
    return source.where((p) {
      if (p.name.toLowerCase().contains(q)) return true;
      if (p.vicinity.toLowerCase().contains(q)) return true;
      final type = p.primaryType;
      if (type != null && _humanizeType(type).toLowerCase().contains(q)) {
        return true;
      }
      return false;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final places = widget.places;
    final visible = _filtered(places);
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.4,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) {
        return Column(
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(top: 12, bottom: 12),
                decoration: BoxDecoration(
                  color: theme.dividerColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          places.isEmpty
                              ? 'No places found'
                              : 'Nearby places',
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          places.isEmpty
                              ? 'Try a larger radius in Settings.'
                              : 'Within ${_formatRadius(widget.radiusMeters)} of where you tapped',
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
                    tooltip: 'Cancel',
                  ),
                ],
              ),
            ),
            if (places.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                child: TextField(
                  controller: _searchController,
                  onChanged: (v) => setState(() => _query = v.trim()),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'Search this list…',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: _query.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Clear',
                            icon: const Icon(Icons.clear, size: 18),
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _query = '');
                            },
                          ),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(
                        color: theme.dividerColor.withValues(alpha: 0.4),
                      ),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(
                        color: theme.dividerColor.withValues(alpha: 0.4),
                      ),
                    ),
                  ),
                ),
              ),
            const Divider(height: 1),
            Expanded(
              child: places.isEmpty
                  ? _buildEmpty(context)
                  : visible.isEmpty
                      ? _buildNoMatches(context)
                      : ListView.separated(
                          controller: scrollController,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          itemCount: visible.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 4),
                          itemBuilder: (context, i) =>
                              _buildPlaceTile(context, visible[i]),
                        ),
            ),
            if (places.isNotEmpty)
              _buildBottomBar(context, scrollController),
          ],
        );
      },
    );
  }

  Widget _buildNoMatches(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_off,
                size: 40, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              'No places match "$_query".',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlaceTile(BuildContext context, NearbyPlace place) {
    final theme = Theme.of(context);
    final isSelected = _selected.contains(place.placeId);
    return Material(
      color: isSelected
          ? theme.colorScheme.primary.withValues(alpha: 0.08)
          : theme.cardColor,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => setState(() {
          if (isSelected) {
            _selected.remove(place.placeId);
          } else {
            _selected.add(place.placeId);
          }
        }),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (place.photoReference != null)
                LocationPhotoThumbnail(
                  photoRef: place.photoReference!,
                  size: 56,
                )
              else
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color:
                        theme.colorScheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.place_outlined,
                    color: theme.colorScheme.primary,
                  ),
                ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      place.name,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _formatSubtitle(place),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Checkbox(
                value: isSelected,
                onChanged: (_) => setState(() {
                  if (isSelected) {
                    _selected.remove(place.placeId);
                  } else {
                    _selected.add(place.placeId);
                  }
                }),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmpty(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.search_off,
              size: 40,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              'No places within ${_formatRadius(widget.radiusMeters)}.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar(
      BuildContext context, ScrollController scrollController) {
    final theme = Theme.of(context);
    final count = _selected.length;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: ElevatedButton.icon(
                onPressed: count == 0
                    ? null
                    : () {
                        final picked = widget.places
                            .where((p) => _selected.contains(p.placeId))
                            .toList();
                        Navigator.of(context).pop(picked);
                      },
                icon: const Icon(Icons.add_location_alt_outlined, size: 18),
                label: Text(count == 0
                    ? 'Add to Trip'
                    : count == 1
                        ? 'Add 1 location'
                        : 'Add $count locations'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: theme.colorScheme.primary,
                  foregroundColor: theme.colorScheme.onPrimary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatSubtitle(NearbyPlace place) {
    final parts = <String>[
      _formatDistance(place.distanceMeters),
      if (place.primaryType != null) _humanizeType(place.primaryType!),
      if (place.vicinity.isNotEmpty) place.vicinity,
    ];
    return parts.join(' • ');
  }

  String _humanizeType(String type) {
    return type
        .split('_')
        .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
        .join(' ');
  }
}

String _formatDistance(double meters) {
  if (meters < 1000) return '${meters.round()} m';
  return '${(meters / 1000).toStringAsFixed(1)} km';
}

String _formatRadius(int meters) {
  if (meters < 1000) return '${meters}m';
  return '${(meters / 1000).toStringAsFixed(meters % 1000 == 0 ? 0 : 1)}km';
}

/// Convenience wrapper that presents the picker and returns the chosen
/// [NearbyPlace]s, or an empty list on cancel/dismiss.
Future<List<NearbyPlace>> showNearbyPlacesPicker(
  BuildContext context, {
  required List<NearbyPlace> places,
  required int radiusMeters,
}) async {
  final result = await showModalBottomSheet<List<NearbyPlace>>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).scaffoldBackgroundColor,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => NearbyPlacesPickerSheet(
      places: places,
      radiusMeters: radiusMeters,
    ),
  );
  return result ?? const [];
}
