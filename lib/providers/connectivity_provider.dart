import 'dart:async';

import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:internet_connection_checker_plus/internet_connection_checker_plus.dart';

enum ConnectivityStatus {
  isConnected,
  isDisconnected,
  isNotDetermined,
}

class ConnectivityNotifier extends StateNotifier<ConnectivityStatus> {
  ConnectivityNotifier(this.internetConnection)
      : super(ConnectivityStatus.isConnected) {
    _init();
  }

  final InternetConnection internetConnection;
  StreamSubscription<InternetStatus>? _subscription;
  Timer? _disconnectDebounce;

  /// A single failed probe round must not flash the red banner: the checker's
  /// endpoints can blip (network transitions, slow probe hosts, simulators)
  /// while the actual connection is fine. Only surface "disconnected" when it
  /// PERSISTS; recovery is instant.
  static const _disconnectGrace = Duration(seconds: 4);

  void _init() {
    _subscription = internetConnection.onStatusChange.listen((status) {
      if (status == InternetStatus.connected) {
        _disconnectDebounce?.cancel();
        _disconnectDebounce = null;
        state = ConnectivityStatus.isConnected;
      } else {
        _disconnectDebounce ??= Timer(_disconnectGrace, () {
          _disconnectDebounce = null;
          if (mounted) state = ConnectivityStatus.isDisconnected;
        });
      }
    });
  }

  @override
  void dispose() {
    _disconnectDebounce?.cancel();
    _subscription?.cancel();
    super.dispose();
  }
}

final connectivityProvider =
    StateNotifierProvider<ConnectivityNotifier, ConnectivityStatus>((ref) {
  return ConnectivityNotifier(ownHostsConnectionChecker());
});

/// Reachability is probed against VoyZa's own hosts. The package's defaults
/// (Cloudflare, icanhazip, a demo JSON API and the Pokémon API) would hand
/// the device's address to four unrelated companies every ten seconds, and
/// the privacy policy names no such recipients. Any answer short of a server
/// error counts as online: the auth health route answers 401 without a key,
/// which still proves the connection.
/// A full TLS handshake to a far-away host on a slow link can take more
/// than the package's three-second default; a slow answer is still online.
const Duration _probeTimeout = Duration(seconds: 10);

InternetConnection ownHostsConnectionChecker() {
  bool reachable(http.Response response) => response.statusCode < 500;
  String supabaseUrl;
  try {
    supabaseUrl = dotenv.env['SUPABASE_URL'] ?? '';
  } catch (_) {
    supabaseUrl = '';
  }
  return InternetConnection.createInstance(
    useDefaultOptions: false,
    customCheckOptions: [
      if (supabaseUrl.isNotEmpty)
        InternetCheckOption(
          uri: Uri.parse('$supabaseUrl/auth/v1/health'),
          timeout: _probeTimeout,
          responseStatusFn: reachable,
        ),
      InternetCheckOption(
        uri: Uri.parse('https://voyza.xtremon.com/'),
        timeout: _probeTimeout,
        responseStatusFn: reachable,
      ),
    ],
  );
}
