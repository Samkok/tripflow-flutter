import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:voyza/services/photo_cache_service.dart';
import 'package:voyza/services/photo_service.dart';
import 'package:voyza/widgets/photo_gallery_viewer.dart';

/// Process-wide cache of photo-reference -> resolved CDN URL futures so
/// rebuilds don't re-fetch the same image. Shared across all card instances
/// (and across the trip-plan + trip-details screens) since photo refs are
/// globally unique.
final Map<String, Future<String?>> _photoUrlCache = {};

Future<String?> resolveLocationPhotoUrl(String photoReference) {
  return _photoUrlCache.putIfAbsent(photoReference, () async {
    final cache = PhotoCacheService();
    String? url = await cache.getPhotoUrl(photoReference);
    if (url != null) return url;
    try {
      url = PhotoService.getPhotoUrl(photoReference: photoReference);
      final response = await Dio().head(
        url,
        options: Options(followRedirects: true, maxRedirects: 5),
      );
      final actualUrl = response.realUri.toString();
      await cache.cachePhotoUrl(photoReference, actualUrl);
      return actualUrl;
    } catch (_) {
      return null;
    }
  });
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
            final ref = photoRefs[index];
            return FutureBuilder<String?>(
              future: resolveLocationPhotoUrl(ref),
              builder: (context, snapshot) {
                final placeholder = _placeholder(
                  context,
                  width: tileWidth,
                  height: tileHeight,
                  loading: snapshot.connectionState == ConnectionState.waiting,
                );
                final url = snapshot.data;
                if (url == null) return placeholder;
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

  Future<void> _openGallery(BuildContext context, int initialIndex) async {
    final urls = await Future.wait(photoRefs.map(resolveLocationPhotoUrl));
    final resolved = urls.whereType<String>().toList();
    if (resolved.isEmpty || !context.mounted) return;
    await showPhotoGalleryViewer(
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
    return FutureBuilder<String?>(
      future: resolveLocationPhotoUrl(photoRef),
      builder: (context, snapshot) {
        final placeholder = _placeholder(
          context,
          width: size,
          height: size,
          radius: radius,
        );
        final url = snapshot.data;
        Widget content;
        if (url == null) {
          content = placeholder;
        } else {
          content = ClipRRect(
            borderRadius: radius,
            child: CachedNetworkImage(
              imageUrl: url,
              width: size,
              height: size,
              fit: BoxFit.cover,
              memCacheWidth: (size * 2).round(),
              memCacheHeight: (size * 2).round(),
              placeholder: (_, __) => placeholder,
              errorWidget: (_, __, ___) => placeholder,
            ),
          );
        }

        Widget child = content;
        if (extraCount != null && extraCount! > 0) {
          child = Stack(
            children: [
              content,
              Positioned(
                right: 4,
                bottom: 4,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
      },
    );
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
      color:
          Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
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
            color:
                Theme.of(context).iconTheme.color?.withValues(alpha: 0.4),
          ),
  );
}
