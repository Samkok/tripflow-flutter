import 'dart:async';
import 'package:internet_connection_checker_plus/internet_connection_checker_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
  return ConnectivityNotifier(InternetConnection());
});
