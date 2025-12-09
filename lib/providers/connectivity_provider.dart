import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
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

  void _init() {
    _subscription = internetConnection.onStatusChange.listen((status) {
      if (status == InternetStatus.connected) {
        state = ConnectivityStatus.isConnected;
      } else {
        state = ConnectivityStatus.isDisconnected;
      }
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}

final connectivityProvider =
    StateNotifierProvider<ConnectivityNotifier, ConnectivityStatus>((ref) {
  return ConnectivityNotifier(InternetConnection());
});
