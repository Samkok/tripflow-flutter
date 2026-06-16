import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:voyza/services/photo_service.dart';
import 'package:voyza/widgets/photo_gallery_viewer.dart';

/// Stable, fetchable URL for a Google Places photo reference.
///
/// We hand [CachedNetworkImage] the Places Photo *endpoint* — NOT its redirect
/// target. The endpoint 302-redirects to a freshly-signed Google CDN URL on
/// every request; CachedNetworkImage follows that redirect and caches the
/// resulting image *bytes* keyed by this stable URL.
///
/// The previous implementation did a HEAD request, captured the redirected
/// signed CDN URL, and persisted *that*. Two bugs fell out of it and made
/// photos intermittently render blank:
///   1. The signed CDN URL is short-lived — once it expired the cached copy
///      403/404'd and the card showed only its placeholder. (This is the
///      "does it have an expiry date?" symptom.)
///   2. A single transient HEAD failure cached a `null` result in a
///      process-wide map, so that photo never retried for the rest of the
///      app session — it only came back after a restart.
/// Returning the stable endpoint removes both, plus a network round-trip per
/// photo. Byte caching/expiry is now handled entirely by CachedNetworkImage's
/// own cache manager.
String resolveLocationPhotoUrl(String photoReference) {
  return PhotoService.getPhotoUrl(photoReference: photoReference);
}

/// Horizontal photo strip displayed inside an expanded location card.
/// Tapping a thumbnail opens the full-screen [PhotoGalleryViewer].
class LocationPhotoGallery extends StatelessWidget {
  final List<String> photoRefs;
  final String heroTagPrefix;
  final String title;
  final EdgeInsetsGeometry padding;
  final double tileWidth;
  final double tileHeight;

  const LocationPhotoGallery({
    super.key,
    required this.photoRefs,
    required this.heroTagPrefix,
    required this.title,
    this.padding = const EdgeInsets.fromLTRB(16, 0, 16, 12),
    this.tileWidth = 140,
    this.tileHeight = 100,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: SizedBox(
        height: tileHeight,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: photoRefs.length,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (context, index) {
            final url = resolveLocationPhotoUrl(photoRefs[index]);
            return GestureDetector(
              onTap: () => _openGallery(context, index),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Hero(
                  tag: '${heroTagPrefix}_$index',
                  child: CachedNetworkImage(
                    imageUrl: url,
                    width: tileWidth,
                    height: tileHeight,
                    fit: BoxFit.cover,
                    memCacheWidth: (tileWidth * 2).round(),
                    memCacheHeight: (tileHeight * 2).round(),
                    placeholder: (_, __) => _placeholder(
                      context,
                      width: tileWidth,
                      height: tileHeight,
                      loading: true,
                    ),
                    errorWidget: (_, __, ___) => _placeholder(
                      context,
                      width: tileWidth,
                      height: tileHeight,
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  void _openGallery(BuildContext context, int initialIndex) {
    final resolved = photoRefs.map(resolveLocationPhotoUrl).toList();
    if (resolved.isEmpty) return;
    showPhotoGalleryViewer(
      context: context,
      photoUrls: resolved,
      initialIndex: initialIndex.clamp(0, resolved.length - 1),
      heroTagPrefix: heroTagPrefix,
      title: title,
    );
  }
}

/// Compact square thumbnail showing the first photo of a location.
/// Used as a preview on the collapsed card to make photo-rich locations
/// visually distinct at a glance.
class LocationPhotoThumbnail extends StatelessWidget {
  final String photoRef;
  final double size;
  final BorderRadius? borderRadius;
  final int? extraCount;
  final VoidCallback? onTap;

  const LocationPhotoThumbnail({
    super.key,
    required this.photoRef,
    this.size = 56,
    this.borderRadius,
    this.extraCount,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final radius = borderRadius ?? BorderRadius.circular(12);

    Widget content = ClipRRect(
      borderRadius: radius,
      child: CachedNetworkImage(
        imageUrl: resolveLocationPhotoUrl(photoRef),
        width: size,
        height: size,
        fit: BoxFit.cover,
        memCacheWidth: (size * 2).round(),
        memCacheHeight: (size * 2).round(),
        placeholder: (_, __) =>
            _placeholder(context, width: size, height: size, radius: radius),
        errorWidget: (_, __, ___) =>
            _placeholder(context, width: size, height: size, radius: radius),
      ),
    );

    Widget child = content;
    if (extraCount != null && extraCount! > 0) {
      child = Stack(
        children: [
          content,
          Positioned(
            right: 4,
            bottom: 4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '+$extraCount',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ],
      );
    }

    if (onTap != null) {
      child = Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: radius,
          child: child,
        ),
      );
    }
    return child;
  }
}

Widget _placeholder(
  BuildContext context, {
  required double width,
  required double height,
  bool loading = false,
  BorderRadius? radius,
}) {
  return Container(
    width: width,
    height: height,
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
      borderRadius: radius ?? BorderRadius.circular(10),
    ),
    child: loading
        ? const Center(
            child: SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          )
        : Icon(
            Icons.image_outlined,
            color: Theme.of(context).iconTheme.color?.withValues(alpha: 0.4),
          ),
  );
}
