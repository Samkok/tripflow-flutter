import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/connectivity_provider.dart';

class ConnectivityWrapper extends ConsumerStatefulWidget {
  final Widget child;

  const ConnectivityWrapper({super.key, required this.child});

  @override
  ConsumerState<ConnectivityWrapper> createState() =>
      _ConnectivityWrapperState();
}

class _ConnectivityWrapperState extends ConsumerState<ConnectivityWrapper> {
  bool _dismissed = false;

  @override
  Widget build(BuildContext context) {
    final connectivityStatus = ref.watch(connectivityProvider);

    // Reset dismissed state when connection is restored
    if (connectivityStatus != ConnectivityStatus.isDisconnected) {
      _dismissed = false;
    }

    final showBanner =
        connectivityStatus == ConnectivityStatus.isDisconnected && !_dismissed;

    return Stack(
      children: [
        widget.child,
        if (showBanner)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Material(
              color: Colors.transparent,
              child: Container(
                color: Colors.red.withValues(alpha: 0.9),
                padding: EdgeInsets.only(
                  top: MediaQuery.of(context).padding.top + 8,
                  bottom: 8,
                  left: 16,
                  right: 8,
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.wifi_off_rounded,
                      color: Colors.white,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'No Internet Connection',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    GestureDetector(
                      onTap: () => setState(() => _dismissed = true),
                      child: const Padding(
                        padding: EdgeInsets.all(8.0),
                        child: Icon(
                          Icons.close,
                          color: Colors.white,
                          size: 18,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
