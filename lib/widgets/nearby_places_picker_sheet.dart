import 'dart:async';
import 'dart:ui' show ImageFilter;
import 'package:voyza/core/theme.dart';
import 'package:flutter/material.dart';
import 'package:voyza/providers/nearby_radius_provider.dart'
    show NearbyRadiusNotifier;
import 'package:voyza/services/places_service.dart';
import 'package:voyza/utils/place_tags.dart';
import 'package:voyza/utils/same_day_place_guard.dart';
import 'package:voyza/utils/search_text.dart';
import 'package:voyza/widgets/location_photo_gallery.dart';
import 'package:voyza/widgets/place_tag_sheet.dart';

/// Bottom sheet shown after a long-press on the map: lists every POI within
/// the search radius (Google Places Nearby Search), lets the user widen or
/// narrow that radius and re-query IN PLACE, multi-select, and returns the
/// chosen [NearbyPlace]s on confirm.
///
/// The radius lives here, not in Settings: the moment the user sees "no
/// places within 300m" is the moment they want to widen it, so the slider
/// sits right above the list and Apply re-runs the search without leaving
/// the sheet. The caller persists the applied radius as the new default.
///
/// Returns an empty list / null on cancel — callers should treat both as
/// "no add". Each row leads with its distance from the pressed point (own
/// highlighted line, not buried in the address) so the user can quickly
/// see what they're picking from.
class NearbyPlacesPickerSheet extends StatefulWidget {
  final List<NearbyPlace> places;
  final int radiusMeters;

  /// Re-runs the nearby search around the same press point for a new
  /// radius. Called when the user slides the radius and taps Apply; the
  /// caller also persists the radius so it's the default next time.
  final Future<List<NearbyPlace>> Function(int radiusMeters) onRequery;

  /// Places already planned on the day being added to. A nearby result
  /// that is (likely) one of them — same place_id, or the same name within
  /// a kilometre, see [isLikelySamePlace] — is shown as "On this day" and
  /// can't be ticked: the add gate would refuse it anyway, so the picker
  /// says so up front.
  final List<PlaceKey> occupantsOnDay;

  /// Set when the caller's FIRST search failed: the sheet opens straight in
  /// its error state with a retry, instead of the caller toasting an error
  /// and the user having nothing to act on.
  final String? initialError;

  /// Name search around the same press point, behind the search box. The
  /// loaded list is Google's Nearby Search: at most 20 PROMINENT places per
  /// category, so in a busy area a specific café or shop the user knows is
  /// right there is often not in it — even though the search bar finds it,
  /// because the search bar searches by name. Typing here therefore also
  /// asks Google for that name near the point and lists the extra hits
  /// under the list's own matches. Null disables the name search.
  final Future<List<NearbyPlace>> Function(String query, int radiusMeters)?
      onSearchText;

  const NearbyPlacesPickerSheet({
    super.key,
    required this.places,
    required this.radiusMeters,
    required this.onRequery,
    this.occupantsOnDay = const [],
    this.initialError,
    this.onSearchText,
  });

  @override
  State<NearbyPlacesPickerSheet> createState() =>
      _NearbyPlacesPickerSheetState();
}

class _NearbyPlacesPickerSheetState extends State<NearbyPlacesPickerSheet> {
  final Set<String> _selected = {};

  /// Per-row tag: the user's explicit choice (null = "no tag") once they
  /// tapped the chip; otherwise the suggestion from Google's types.
  final Map<String, PlaceTag?> _tagByPlaceId = {};
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  /// The list currently shown — the caller's initial results until the
  /// user applies a new radius, then whatever that re-query returned.
  late List<NearbyPlace> _places = widget.places;

  /// Radius the shown list was fetched with, vs. the slider's live value.
  late int _appliedRadius = widget.radiusMeters;
  late double _pendingRadius = widget.radiusMeters.toDouble();
  bool _loading = false;
  late String? _error = widget.initialError;

  /// Google name-search hits for the current query (deduped against the
  /// loaded list at render time) and that request's state. Reset whenever
  /// the query changes; [_searchSeq] makes a late answer to an old query
  /// harmless.
  List<NearbyPlace> _textResults = const [];
  bool _searching = false;
  bool _textFailed = false;
  Timer? _debounce;
  int _searchSeq = 0;
  static const _textSearchMinChars = 2;

  static const _loadErrorText =
      'Couldn\'t load places — check your connection and try again.';

  bool get _radiusDirty => _pendingRadius.round() != _appliedRadius;

  PlaceTag? _tagFor(NearbyPlace place) =>
      _tagByPlaceId.containsKey(place.placeId)
          ? _tagByPlaceId[place.placeId]
          : suggestPlaceTag(place.types);

  Future<void> _editTag(BuildContext context, NearbyPlace place) async {
    final pick = await showPlaceTagSheet(
      context,
      placeName: place.name,
      suggested: suggestPlaceTag(place.types),
      current: _tagFor(place),
      placeTypes: place.types,
      confirmLabel: 'Use',
    );
    if (pick == null || !mounted) return;
    setState(() => _tagByPlaceId[place.placeId] = pick.tag);
  }

  /// The row's tag chip — the suggestion made visible, so adding IS the
  /// confirmation; tap to change or drop it.
  Widget _buildRowTag(BuildContext context, NearbyPlace place) {
    final theme = Theme.of(context);
    final tag = _tagFor(place);
    if (tag != null) {
      return Align(
        alignment: Alignment.centerLeft,
        child: PlaceTagChip(
          tag: tag,
          selected: true,
          dense: true,
          placeTypes: place.types,
          onTap: () => _editTag(context, place),
        ),
      );
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: () => _editTag(context, place),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border:
                Border.all(color: theme.dividerColor.withValues(alpha: 0.6)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.label_outline_rounded,
                  size: 12, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 4),
              Text(
                'Add tag',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  /// Apply: re-query for the slider's radius and swap the list in place.
  /// Picks that still exist in the new results stay ticked; the rest are
  /// dropped silently (they're outside the new radius, so they couldn't be
  /// added from this list anyway).
  Future<void> _applyRadius() => _requery(_pendingRadius.round());

  /// Search again around the same press point — with the slider's radius
  /// (Apply) or the current one (the refresh button / "Try again").
  Future<void> _requery(int radius) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final fresh = await widget.onRequery(radius);
      if (!mounted) return;
      setState(() {
        _places = fresh;
        _appliedRadius = radius;
        _pendingRadius = radius.toDouble();
        final ids = {
          for (final p in fresh) p.placeId,
          for (final p in _textResults) p.placeId,
        };
        _selected.removeWhere((id) => !ids.contains(id));
        _loading = false;
      });
    } catch (e) {
      debugPrint('Nearby re-query failed: $e');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _loadErrorText;
      });
    }
  }

  /// Radius slider + Apply, above the list. Apply lights up only when the
  /// slider has moved away from the radius the list was fetched with, so
  /// it always means "something will change".
  Widget _buildRadiusControl(BuildContext context) {
    final theme = Theme.of(context);
    final dirty = _radiusDirty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.radar_outlined,
                  size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Text(
                'Search radius',
                style: theme.textTheme.labelLarge
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              Text(
                _formatRadius(_pendingRadius.round()),
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          Row(
            children: [
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(trackHeight: 3),
                  child: Slider(
                    value: _pendingRadius,
                    min: NearbyRadiusNotifier.minRadius,
                    max: NearbyRadiusNotifier.maxRadius,
                    divisions: 19,
                    label: _formatRadius(_pendingRadius.round()),
                    onChanged: _loading
                        ? null
                        : (v) => setState(() => _pendingRadius = v),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              FilledButton.tonal(
                onPressed: dirty && !_loading ? _applyRadius : null,
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                ),
                child: Text(_loading ? 'Loading…' : 'Apply'),
              ),
            ],
          ),
          // With an empty list the error owns the whole empty state below;
          // only repeat it inline when stale results are still showing.
          if (_error != null && _places.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                _error!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ),
        ],
      ),
    );
  }

  /// Forgiving match (case- and diacritic-insensitive, any word order — see
  /// [matchesSearchQuery]) on name, vicinity, and humanized primary type —
  /// same fields that feed the tile's title/subtitle so the user can filter
  /// by what they actually see on screen.
  List<NearbyPlace> _filtered(List<NearbyPlace> source) {
    if (_query.isEmpty) return source;
    return source.where((p) {
      if (matchesSearchQuery(p.name, _query)) return true;
      if (matchesSearchQuery(p.vicinity, _query)) return true;
      final type = p.primaryType;
      if (type != null && matchesSearchQuery(_humanizeType(type), _query)) {
        return true;
      }
      return false;
    }).toList();
  }

  bool get _canSearchText => widget.onSearchText != null;

  /// Typing filters the loaded list at once and, after a short pause, asks
  /// Google for that name around the press point (see
  /// [NearbyPlacesPickerSheet.onSearchText]).
  void _onQueryChanged(String raw) {
    final q = raw.trim();
    _debounce?.cancel();
    _searchSeq++; // whatever is in flight now answers an old query
    final willSearch = _canSearchText && q.length >= _textSearchMinChars;
    setState(() {
      _query = q;
      _textResults = const [];
      _textFailed = false;
      _searching = willSearch;
    });
    if (!willSearch) return;
    final seq = _searchSeq;
    _debounce = Timer(
      const Duration(milliseconds: 500),
      () => _runTextSearch(q, seq),
    );
  }

  Future<void> _runTextSearch(String q, int seq) async {
    try {
      final found = await widget.onSearchText!(q, _appliedRadius);
      if (!mounted || seq != _searchSeq) return;
      setState(() {
        _textResults = found;
        _searching = false;
      });
    } catch (e) {
      debugPrint('Nearby name search failed: $e');
      if (!mounted || seq != _searchSeq) return;
      setState(() {
        _textFailed = true;
        _searching = false;
      });
    }
  }

  /// Name-search hits the loaded list doesn't already have.
  List<NearbyPlace> get _extraResults {
    if (_textResults.isEmpty) return const [];
    final known = {for (final p in _places) p.placeId};
    return [
      for (final p in _textResults)
        if (known.add(p.placeId)) p,
    ];
  }

  /// Everything a tick can refer to: the loaded list plus name-search hits.
  List<NearbyPlace> get _allKnown => [..._places, ..._extraResults];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final places = _places;
    final visible = _filtered(places);
    final extra = _query.length >= _textSearchMinChars
        ? _extraResults
        : const <NearbyPlace>[];
    final String title;
    final String subtitle;
    if (places.isEmpty && _error != null) {
      title = 'Couldn\'t load places';
      subtitle = 'Check your connection, then try again.';
    } else if (places.isEmpty && _query.isEmpty) {
      title = 'No places found';
      subtitle =
          'Nothing within ${_formatRadius(_appliedRadius)} — widen the radius below and apply.';
    } else {
      title = 'Nearby places';
      subtitle = 'Within ${_formatRadius(_appliedRadius)} of where you tapped';
    }
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      child: BackdropFilter(
        filter: ImageFilter.blur(
            sigmaX: AppTheme.sheetBlurSigma, sigmaY: AppTheme.sheetBlurSigma),
        child: Container(
          decoration: BoxDecoration(
            color: theme.scaffoldBackgroundColor
                .withValues(alpha: AppTheme.sheetFillAlpha(context)),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            border: Border.all(
              color: AppTheme.sheetBorderColor(context),
              width: 0.8,
            ),
          ),
          child: DraggableScrollableSheet(
            initialChildSize: 0.68,
            minChildSize: 0.4,
            maxChildSize: 0.92,
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
                                title,
                                style: theme.textTheme.titleLarge?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                subtitle,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        // Search the same spot again — for the transient
                        // failures and the odd empty answer from Google.
                        IconButton(
                          icon: const Icon(Icons.refresh_rounded),
                          onPressed:
                              _loading ? null : () => _requery(_appliedRadius),
                          tooltip: 'Search again',
                        ),
                        IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => Navigator.of(context).pop(),
                          tooltip: 'Cancel',
                        ),
                      ],
                    ),
                  ),
                  _buildRadiusControl(context),
                  if (places.isNotEmpty || (_error == null && _canSearchText))
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                      child: TextField(
                        cursorOpacityAnimates: false,
                        controller: _searchController,
                        onChanged: _onQueryChanged,
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: _canSearchText
                              ? 'Find a place near here…'
                              : 'Search this list…',
                          prefixIcon: const Icon(Icons.search, size: 20),
                          suffixIcon: _query.isEmpty
                              ? null
                              : IconButton(
                                  tooltip: 'Clear',
                                  icon: const Icon(Icons.clear, size: 18),
                                  onPressed: () {
                                    _searchController.clear();
                                    _onQueryChanged('');
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
                  if (_loading || _searching)
                    const LinearProgressIndicator(minHeight: 2)
                  else
                    const Divider(height: 1),
                  Expanded(
                    child: _query.isEmpty && places.isEmpty
                        ? _buildEmpty(context)
                        : visible.isEmpty && extra.isEmpty
                            ? _buildNoMatches(context)
                            : _buildList(scrollController, visible, extra),
                  ),
                  if (places.isNotEmpty || extra.isNotEmpty)
                    _buildBottomBar(context, scrollController),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildNoMatches(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final String text;
    final String? hint;
    if (_searching) {
      text = 'Searching Google near where you tapped…';
      hint = null;
    } else if (_textFailed) {
      text = 'No places match "$_query" in this list.';
      hint = 'Couldn\'t reach Google to look further — check your connection.';
    } else if (_canSearchText && _query.length >= _textSearchMinChars) {
      text = 'No places match "$_query" near where you tapped.';
      hint = 'Try another spelling, or widen the radius and apply.';
    } else {
      text = 'No places match "$_query".';
      hint = null;
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _searching ? Icons.travel_explore : Icons.search_off,
              size: 40,
              color: muted,
            ),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: muted),
            ),
            if (hint != null) ...[
              const SizedBox(height: 6),
              Text(
                hint,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Loaded-list matches first, then — under a small label — the name
  /// search's extra hits, all through the same tile so ticking, the
  /// distance line and the "On this day" badge behave identically.
  Widget _buildList(
    ScrollController controller,
    List<NearbyPlace> local,
    List<NearbyPlace> extra,
  ) {
    final hasLabel = extra.isNotEmpty;
    final count = local.length + (hasLabel ? 1 : 0) + extra.length;
    return ListView.separated(
      controller: controller,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: count,
      separatorBuilder: (_, __) => const SizedBox(height: 4),
      itemBuilder: (context, i) {
        if (i < local.length) return _buildPlaceTile(context, local[i]);
        if (hasLabel && i == local.length) {
          return _buildSectionLabel(
            context,
            local.isEmpty
                ? 'From Google, near where you tapped'
                : 'More from Google, near where you tapped',
          );
        }
        final j = i - local.length - (hasLabel ? 1 : 0);
        return _buildPlaceTile(context, extra[j]);
      },
    );
  }

  Widget _buildSectionLabel(BuildContext context, String text) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 2),
      child: Text(
        text,
        style: theme.textTheme.labelMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          letterSpacing: 0.2,
        ),
      ),
    );
  }

  Widget _buildPlaceTile(BuildContext context, NearbyPlace place) {
    final theme = Theme.of(context);
    final PlaceKey candidate = (
      id: '',
      placeId: place.placeId,
      name: place.name,
      lat: place.coordinates.latitude,
      lng: place.coordinates.longitude,
    );
    final alreadyOnDay =
        widget.occupantsOnDay.any((o) => isLikelySamePlace(o, candidate));
    final isSelected = !alreadyOnDay && _selected.contains(place.placeId);
    return Material(
      color: isSelected
          ? theme.colorScheme.primary.withValues(alpha: 0.08)
          : theme.cardColor,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: alreadyOnDay
            ? null
            : () => setState(() {
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
                    color: theme.colorScheme.primary.withValues(alpha: 0.12),
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
                    const SizedBox(height: 3),
                    // Distance from the pressed point — the number people
                    // scan for when choosing between nearby options, so it
                    // gets its own line in the accent colour (same style as
                    // the "Xkm away" line in the search screens) instead of
                    // leading the grey address text.
                    Row(
                      children: [
                        Icon(Icons.near_me,
                            size: 12, color: theme.colorScheme.primary),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            '${_formatDistance(place.distanceMeters)} from where you tapped',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (_formatSubtitle(place).isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        _formatSubtitle(place),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    if (!alreadyOnDay) ...[
                      const SizedBox(height: 6),
                      _buildRowTag(context, place),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (alreadyOnDay)
                // Already planned for this day — the same-day rule would
                // refuse it, so say so instead of offering a checkbox.
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.check_circle_rounded,
                          size: 14, color: theme.colorScheme.primary),
                      const SizedBox(width: 4),
                      Text(
                        'On this day',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                )
              else
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

  /// Empty list. Two very different reasons, told apart: the request
  /// FAILED (offline, a Google hiccup) → say so and offer a retry; Google
  /// answered with nothing → suggest a wider radius, with a retry too.
  Widget _buildEmpty(BuildContext context) {
    final theme = Theme.of(context);
    final failed = _error != null;
    final muted = theme.colorScheme.onSurfaceVariant;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              failed ? Icons.cloud_off_rounded : Icons.search_off,
              size: 40,
              color: failed ? theme.colorScheme.error : muted,
            ),
            const SizedBox(height: 12),
            Text(
              failed
                  ? _loadErrorText
                  : 'No places within ${_formatRadius(_appliedRadius)}.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: muted),
            ),
            if (!failed) ...[
              const SizedBox(height: 6),
              Text(
                'Slide the radius up and tap Apply to look further out.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
            ],
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              onPressed: _loading ? null : () => _requery(_appliedRadius),
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: Text(failed ? 'Try again' : 'Search again'),
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
                onPressed: count == 0 || _loading
                    ? null
                    : () {
                        final picked = _allKnown
                            .where((p) => _selected.contains(p.placeId))
                            .map((p) => p.withTag(_tagFor(p)?.key))
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

  /// Category + address. Distance has its own line above (see the tile).
  String _formatSubtitle(NearbyPlace place) {
    final parts = <String>[
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
  required Future<List<NearbyPlace>> Function(int radiusMeters) onRequery,
  List<PlaceKey> occupantsOnDay = const [],
  String? initialError,
  Future<List<NearbyPlace>> Function(String query, int radiusMeters)?
      onSearchText,
}) async {
  final result = await showModalBottomSheet<List<NearbyPlace>>(
    context: context,
    isScrollControlled: true,
    // Glass: the sheet paints its own frosted pane (see build), so the
    // modal itself stays transparent with a light barrier — same treatment
    // as the trip plan / search / collaborators sheets.
    backgroundColor: Colors.transparent,
    barrierColor: AppTheme.sheetBarrierColor(context),
    builder: (_) => NearbyPlacesPickerSheet(
      places: places,
      radiusMeters: radiusMeters,
      onRequery: onRequery,
      occupantsOnDay: occupantsOnDay,
      initialError: initialError,
      onSearchText: onSearchText,
    ),
  );
  return result ?? const [];
}
