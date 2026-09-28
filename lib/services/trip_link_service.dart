import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';

import '../utils/trip_share_link.dart';

/// Opens the copy flow for a share code that arrived through a link.
/// Returns true when it took the request (the wizard is on screen), false
/// to keep the code for later — nobody is signed in yet.
typedef TripCopyLinkHandler = bool Function(String shareCode);

/// Listens for trip links (`https://voyza.xtremon.com/c/<CODE>`,
/// `voyza://copy/<CODE>`) and hands the code to the app once the app can
/// show something.
///
/// A link can arrive before there is anywhere to put a screen: it may be
/// what launched the app, and the splash REPLACES itself with the home
/// screen — a route pushed over the splash would be the one replaced. So a
/// code waits until the home screen is mounted, and keeps waiting while
/// nobody is signed in (copying a trip needs an account).
///
/// Links that are not trip links — sign-in callbacks, referral links — are
/// ignored; supabase_flutter listens to the same stream for its own.
class TripLinkService {
  TripLinkService({Stream<Uri>? links}) : _links = links;

  static final TripLinkService instance = TripLinkService();

  /// Injected in tests; the platform's link stream otherwise.
  final Stream<Uri>? _links;

  StreamSubscription<Uri>? _subscription;
  TripCopyLinkHandler? _handler;
  int _homeScreens = 0;
  String? _pendingCode;

  /// The code waiting to be opened, if any.
  String? get pendingCode => _pendingCode;

  /// Whether a trip link arrived during this run of the app. Someone who
  /// came for a shared trip skips the first-run tour: their first screen is
  /// the trip they were sent.
  bool get linkSeen => _linkSeen;
  bool _linkSeen = false;

  /// Starts listening. Safe to call again — the handler is replaced, the
  /// subscription is kept.
  void start({required TripCopyLinkHandler onCopyTrip}) {
    _handler = onCopyTrip;
    _subscription ??= (_links ?? AppLinks().uriLinkStream).listen(
      handleLink,
      onError: (Object e) => debugPrint('TripLinkService: link stream: $e'),
    );
    _deliver();
  }

  /// One incoming link. The newest trip link wins: a second tap before the
  /// first was opened replaces it.
  void handleLink(Uri uri) {
    final code = tripShareCodeFromUri(uri);
    if (code == null) return;
    debugPrint('TripLinkService: trip link for $code');
    _linkSeen = true;
    _pendingCode = code;
    _deliver();
  }

  /// The home screen is on the navigator. Counted, not flagged: signing in
  /// replaces one home screen with another, and the new one mounts before
  /// the old one is disposed.
  void homeScreenMounted() {
    _homeScreens++;
    _deliver();
  }

  void homeScreenDisposed() {
    if (_homeScreens > 0) _homeScreens--;
  }

  /// Tries the waiting code again — after a sign-in, say.
  void retryPending() => _deliver();

  void _deliver() {
    final code = _pendingCode;
    final handler = _handler;
    if (code == null || handler == null || _homeScreens == 0) return;
    _pendingCode = null;
    final taken = handler(code);
    // Kept for later unless a newer link arrived while the handler ran.
    if (!taken) _pendingCode ??= code;
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
    _handler = null;
    _pendingCode = null;
    _homeScreens = 0;
    _linkSeen = false;
  }
}
