import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// Opens a black-backdropped full-screen viewer over [photoUrls]. Swipes
/// horizontally between photos and pinch-zooms within each. Closes via the
/// X button or by swiping down on an un-zoomed photo — the image follows
/// the finger while the backdrop fades, and releasing past the threshold
/// dismisses (releasing early springs back).
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
      // The black backdrop is painted INSIDE the page (not as a route
      // barrier) so the swipe-down gesture can fade it out with the drag.
      barrierColor: Colors.transparent,
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

class _PhotoGalleryViewerState extends State<PhotoGalleryViewer>
    with SingleTickerProviderStateMixin {
  late final PageController _controller;
  late int _currentIndex;

  /// Per-page zoom controllers so we know whether the CURRENT photo is
  /// zoomed in. While zoomed, single-finger drags must pan the photo
  /// (InteractiveViewer), so the dismiss gesture is disabled; at rest the
  /// photo doesn't need panning, so vertical drags dismiss and horizontal
  /// drags page.
  final Map<int, TransformationController> _zoomControllers = {};
  bool _zoomed = false;

  /// Current vertical displacement of the content while swipe-dismissing.
  double _dragOffset = 0;

  /// Springs [_dragOffset] back to 0 when a drag is released early.
  late final AnimationController _settle;
  Animation<double>? _settleAnim;

  static const double _dismissDistance = 140;
  static const double _dismissVelocity = 700;

  /// Drag distance over which the backdrop fades to its minimum.
  static const double _fadeRange = 400;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex.clamp(0, widget.photoUrls.length - 1);
    _controller = PageController(initialPage: _currentIndex);
    _settle = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    )..addListener(() {
        setState(() => _dragOffset = _settleAnim?.value ?? 0);
      });
  }

  @override
  void dispose() {
    _settle.dispose();
    _controller.dispose();
    for (final c in _zoomControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  TransformationController _zoomControllerFor(int index) =>
      _zoomControllers.putIfAbsent(index, TransformationController.new);

  void _syncZoomState() {
    final scale = _zoomControllers[_currentIndex]?.value.getMaxScaleOnAxis();
    final zoomed = (scale ?? 1.0) > 1.01;
    if (zoomed != _zoomed) setState(() => _zoomed = zoomed);
  }

  void _onPageChanged(int index) {
    setState(() => _currentIndex = index);
    _syncZoomState();
  }

  /// Once the page scroll settles, reset the zoom of every non-visible page
  /// so returning to one starts clean. Deferring this to scroll-end (rather
  /// than doing it in onPageChanged) avoids a visible snap while the
  /// outgoing page is still half on screen, and preserves the zoom when a
  /// half-swipe is cancelled and settles back onto the same page.
  void _onScrollSettled() {
    for (final entry in _zoomControllers.entries) {
      if (entry.key != _currentIndex) {
        entry.value.value = Matrix4.identity();
      }
    }
    _syncZoomState();
  }

  /// While a second finger is down this is a pinch, not a pull-down —
  /// tracked via [Listener] so the dismiss drag can't hijack an
  /// asymmetric pinch. Gated INSIDE the callbacks (instead of nulling
  /// them) so the recognizer isn't torn down mid-gesture, which would
  /// strand a partial [_dragOffset].
  int _activePointers = 0;

  bool get _dismissBlocked => _zoomed || _activePointers >= 2;

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    if (_dismissBlocked) return;
    _settle.stop();
    setState(() {
      // Downward only — upward drags are clamped so the gesture always
      // reads as "pull down to close".
      _dragOffset = (_dragOffset + details.delta.dy).clamp(0.0, 1000.0);
    });
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    if (_dragOffset == 0) return;
    final velocity = details.velocity.pixelsPerSecond.dy;
    // A decisive upward fling is the universal "changed my mind" gesture —
    // it must spring back even if the finger is past the distance
    // threshold at release.
    final flungUp = velocity < -_dismissVelocity;
    if (!flungUp &&
        (_dragOffset > _dismissDistance || velocity > _dismissVelocity)) {
      Navigator.of(context).pop();
      return;
    }
    _springBack();
  }

  void _springBack() {
    if (_dragOffset == 0) return;
    _settleAnim = Tween<double>(begin: _dragOffset, end: 0).animate(
      CurvedAnimation(parent: _settle, curve: Curves.easeOut),
    );
    _settle.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    // Fade the backdrop and chrome as the photo is pulled down.
    final progress = (_dragOffset / _fadeRange).clamp(0.0, 1.0);
    final backdropAlpha = (1.0 - progress * 0.75).clamp(0.0, 1.0);

    return ColoredBox(
      color: Colors.black.withValues(alpha: backdropAlpha),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          backgroundColor: Colors.black.withValues(alpha: 0.4 * (1 - progress)),
          foregroundColor: Colors.white,
          elevation: 0,
          leading: Opacity(
            opacity: 1 - progress,
            child: IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
          title: Opacity(
            opacity: 1 - progress,
            child: Text(
              widget.photoUrls.length == 1
                  ? (widget.title ?? '')
                  : '${_currentIndex + 1} / ${widget.photoUrls.length}',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          centerTitle: true,
        ),
        body: Listener(
          onPointerDown: (_) => setState(() => _activePointers++),
          onPointerUp: (_) => setState(
              () => _activePointers = (_activePointers - 1).clamp(0, 32)),
          onPointerCancel: (_) => setState(
              () => _activePointers = (_activePointers - 1).clamp(0, 32)),
          child: GestureDetector(
            // Only claim vertical drags when the photo is at rest — while
            // zoomed, InteractiveViewer needs them for panning. (The
            // pinch/pointer-count gate lives inside the callbacks; see
            // _dismissBlocked.)
            onVerticalDragUpdate: _zoomed ? null : _onVerticalDragUpdate,
            onVerticalDragEnd: _zoomed ? null : _onVerticalDragEnd,
            // A system-cancelled drag (incoming call, OS edge gesture) must
            // not strand the photo mid-translation.
            onVerticalDragCancel: _zoomed ? null : _springBack,
            child: Transform.translate(
              offset: Offset(0, _dragOffset),
              child: NotificationListener<ScrollEndNotification>(
                onNotification: (_) {
                  _onScrollSettled();
                  return false;
                },
                child: PageView.builder(
                  controller: _controller,
                  // While zoomed, single-finger drags must PAN the photo. The
                  // PageView's horizontal recognizer accepts at kTouchSlop
                  // (18px) while InteractiveViewer's scale recognizer needs
                  // kPanSlop (36px) — so unless paging is frozen here, the
                  // PageView always steals the drag and flips pages instead of
                  // panning. Paging resumes when the user zooms back out.
                  physics:
                      _zoomed ? const NeverScrollableScrollPhysics() : null,
                  itemCount: widget.photoUrls.length,
                  onPageChanged: _onPageChanged,
                  itemBuilder: (context, index) {
                    final url = widget.photoUrls[index];
                    final image = CachedNetworkImage(
                      imageUrl: url,
                      fit: BoxFit.contain,
                      placeholder: (_, __) => const Center(
                        child: CircularProgressIndicator(
                          valueColor:
                              AlwaysStoppedAnimation<Color>(Colors.white),
                        ),
                      ),
                      errorWidget: (_, __, ___) => const Icon(
                        Icons.broken_image_outlined,
                        color: Colors.white54,
                        size: 64,
                      ),
                    );
                    return InteractiveViewer(
                      transformationController: _zoomControllerFor(index),
                      minScale: 1,
                      maxScale: 5,
                      // At rest the photo fits the screen and has nothing to
                      // pan, so leave single-finger drags to the PageView
                      // (horizontal) and the dismiss gesture (vertical).
                      // Pinch-zooming stays enabled; once zoomed, panning
                      // takes over and dismissal pauses until zoomed back out.
                      panEnabled: _zoomed,
                      onInteractionEnd: (_) => _syncZoomState(),
                      child: Center(
                        child: widget.heroTagPrefix == null
                            ? image
                            : Hero(
                                tag: '${widget.heroTagPrefix}_$index',
                                child: image,
                              ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
