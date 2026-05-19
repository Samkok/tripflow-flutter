import 'dart:async';

import 'package:flutter/material.dart';

/// Severity buckets for [AppToast]. Each maps to one accent color used
/// for the leading dot.
enum ToastKind { success, error, warning, info }

/// App-wide toast service that replaces `ScaffoldMessenger.showSnackBar`.
///
/// A toast renders as a top-anchored rounded card with a small colored
/// dot in front of the message and a close button. It sits in the root
/// [Overlay] so it always paints above modals, sheets, and keyboards,
/// and respects `MediaQuery.viewPadding.top` so it clears the Dynamic
/// Island / notch / status bar.
///
/// Only one toast is shown at a time — calling any of the four type
/// helpers while a toast is visible dismisses the current one and
/// replaces it with the new one. Default duration is 2 seconds; users
/// can also tap the X to dismiss early.
///
/// Usage:
/// ```dart
/// AppToast.success(context, 'Saved');
/// AppToast.error(context, 'Could not connect');
/// AppToast.warning(context, 'Trial ends in 3 days');
/// AppToast.info(context, 'Tip: long-press to reorder');
/// ```
class AppToast {
  AppToast._();

  static OverlayEntry? _currentEntry;
  static _AppToastState? _currentState;

  static const Duration _defaultDuration = Duration(seconds: 2);

  static void success(BuildContext context, String message,
          {Duration? duration}) =>
      _show(context, ToastKind.success, message, duration);

  static void error(BuildContext context, String message,
          {Duration? duration}) =>
      _show(context, ToastKind.error, message, duration);

  static void warning(BuildContext context, String message,
          {Duration? duration}) =>
      _show(context, ToastKind.warning, message, duration);

  static void info(BuildContext context, String message,
          {Duration? duration}) =>
      _show(context, ToastKind.info, message, duration);

  /// Generic entry point if the caller already has a [ToastKind] in hand
  /// (e.g. derived from an enum/state). Prefer the type-specific helpers
  /// above when possible — they read more clearly at the call site.
  static void show(
    BuildContext context,
    ToastKind kind,
    String message, {
    Duration? duration,
  }) =>
      _show(context, kind, message, duration);

  static void dismiss() {
    _currentState?.startReverse();
  }

  static void _show(
    BuildContext context,
    ToastKind kind,
    String message,
    Duration? duration,
  ) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;

    // If a toast is already on screen, snap it off so the new one can
    // take its slot without two overlapping.
    _currentEntry?.remove();
    _currentEntry = null;
    _currentState = null;

    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _AppToast(
        kind: kind,
        message: message,
        duration: duration ?? _defaultDuration,
        onRemove: () {
          if (identical(_currentEntry, entry)) {
            _currentEntry = null;
            _currentState = null;
          }
          entry.remove();
        },
        onMounted: (state) {
          if (identical(_currentEntry, entry)) {
            _currentState = state;
          }
        },
      ),
    );
    _currentEntry = entry;
    overlay.insert(entry);
  }
}

class _AppToast extends StatefulWidget {
  final ToastKind kind;
  final String message;
  final Duration duration;
  final VoidCallback onRemove;
  final void Function(_AppToastState state) onMounted;

  const _AppToast({
    required this.kind,
    required this.message,
    required this.duration,
    required this.onRemove,
    required this.onMounted,
  });

  @override
  State<_AppToast> createState() => _AppToastState();
}

class _AppToastState extends State<_AppToast>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _opacity;
  late final Animation<Offset> _offset;
  Timer? _timer;
  bool _dismissed = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _opacity = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _offset = Tween<Offset>(
      begin: const Offset(0, -0.6),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onMounted(this);
      _ctrl.forward();
      _timer = Timer(widget.duration, startReverse);
    });
  }

  void startReverse() {
    if (_dismissed || !mounted) return;
    _dismissed = true;
    _timer?.cancel();
    _ctrl.reverse().whenComplete(() {
      if (mounted) widget.onRemove();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  Color _dotColor(BuildContext context) {
    switch (widget.kind) {
      case ToastKind.success:
        return const Color(0xFF22C55E); // green
      case ToastKind.error:
        return const Color(0xFFEF4444); // red
      case ToastKind.warning:
        return const Color(0xFFF59E0B); // amber/yellow
      case ToastKind.info:
        return const Color(0xFF3B82F6); // blue
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final media = MediaQuery.of(context);
    // viewPadding.top covers status bar + Dynamic Island / notch and
    // doesn't shrink when the keyboard is open (unlike `padding.top`
    // on Android in some configurations). Always clears system chrome.
    final topInset = media.viewPadding.top;
    final dot = _dotColor(context);

    return Positioned(
      top: topInset + 8,
      left: 12,
      right: 12,
      child: IgnorePointer(
        ignoring: false,
        child: SafeArea(
          top: false,
          bottom: false,
          child: FadeTransition(
            opacity: _opacity,
            child: SlideTransition(
              position: _offset,
              child: Material(
                color: Colors.transparent,
                child: GestureDetector(
                  onTap: startReverse,
                  child: Container(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: theme.dividerColor.withValues(alpha: 0.4),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.18),
                          blurRadius: 16,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
                    child: Row(
                      children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: dot,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: dot.withValues(alpha: 0.5),
                                blurRadius: 6,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            widget.message,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurface,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        IconButton(
                          tooltip: 'Dismiss',
                          icon: Icon(
                            Icons.close,
                            size: 18,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(
                              minWidth: 32, minHeight: 32),
                          onPressed: startReverse,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
