import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// Opens a black-backdropped full-screen viewer over [photoUrls]. Swipes
/// horizontally between photos and pinch-zooms within each. Closes via the
/// X button or by swiping down on the topmost (un-zoomed) view.
Future<void> showPhotoGalleryViewer({
  required BuildContext context,
  required List<String> photoUrls,
  required int initialIndex,
  String? heroTagPrefix,
  String? title,
}) {
  if (photoUrls.isEmpty) return Future.value();
  return Navigator.of(context).push(
    PageRouteBuilder(
      opaque: false,
      barrierColor: Colors.black,
      pageBuilder: (_, __, ___) => PhotoGalleryViewer(
        photoUrls: photoUrls,
        initialIndex: initialIndex,
        heroTagPrefix: heroTagPrefix,
        title: title,
      ),
      transitionsBuilder: (_, animation, __, child) =>
          FadeTransition(opacity: animation, child: child),
    ),
  );
}

class PhotoGalleryViewer extends StatefulWidget {
  final List<String> photoUrls;
  final int initialIndex;
  final String? heroTagPrefix;
  final String? title;

  const PhotoGalleryViewer({
    super.key,
    required this.photoUrls,
    required this.initialIndex,
    this.heroTagPrefix,
    this.title,
  });

  @override
  State<PhotoGalleryViewer> createState() => _PhotoGalleryViewerState();
}

class _PhotoGalleryViewerState extends State<PhotoGalleryViewer> {
  late final PageController _controller;
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex.clamp(0, widget.photoUrls.length - 1);
    _controller = PageController(initialPage: _currentIndex);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.black.withValues(alpha: 0.4),
        foregroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          widget.photoUrls.length == 1
              ? (widget.title ?? '')
              : '${_currentIndex + 1} / ${widget.photoUrls.length}',
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w500,
          ),
        ),
        centerTitle: true,
      ),
      body: PageView.builder(
        controller: _controller,
        itemCount: widget.photoUrls.length,
        onPageChanged: (i) => setState(() => _currentIndex = i),
        itemBuilder: (context, index) {
          final url = widget.photoUrls[index];
          final image = CachedNetworkImage(
            imageUrl: url,
            fit: BoxFit.contain,
            placeholder: (_, __) => const Center(
              child: CircularProgressIndicator(
                valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
              ),
            ),
            errorWidget: (_, __, ___) => const Icon(
              Icons.broken_image_outlined,
              color: Colors.white54,
              size: 64,
            ),
          );
          return InteractiveViewer(
            minScale: 1,
            maxScale: 5,
            child: Center(
              child: widget.heroTagPrefix == null
                  ? image
                  : Hero(tag: '${widget.heroTagPrefix}_$index', child: image),
            ),
          );
        },
      ),
    );
  }
}
