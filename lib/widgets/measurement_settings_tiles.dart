import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/measurement_consent_service.dart';
import '../utils/measurement_decision.dart';

/// The two measurement switches in Settings: "Usage analytics" and "Ads
/// measurement". Each shows what is in force right now and, when flipped,
/// records an explicit choice that holds wherever the person travels.
class MeasurementSettingsTiles extends StatefulWidget {
  const MeasurementSettingsTiles({super.key, this.service});

  final MeasurementConsentService? service;

  @override
  State<MeasurementSettingsTiles> createState() =>
      _MeasurementSettingsTilesState();
}

class _MeasurementSettingsTilesState extends State<MeasurementSettingsTiles> {
  late final MeasurementConsentService _measurement =
      widget.service ?? MeasurementConsentService.instance;

  @override
  void initState() {
    super.initState();
    // Normally decided at startup; this covers a Settings screen opened
    // before that finished.
    _measurement.current();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<MeasurementDecision?>(
      valueListenable: _measurement.decision,
      builder: (context, decision, _) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _tile(
            context,
            key: const ValueKey('settings-usage-analytics'),
            icon: Icons.insights_rounded,
            title: 'Usage analytics',
            subtitle: 'Helps us see which features travellers use. Sent to '
                'Google Analytics.',
            value: decision?.analytics,
            onChanged: _measurement.setAnalytics,
          ),
          const SizedBox(height: 12),
          _tile(
            context,
            key: const ValueKey('settings-ads-measurement'),
            icon: Icons.campaign_outlined,
            title: 'Ads measurement',
            subtitle: 'Tells Meta and Google when one of our ads leads to an '
                'install or subscription. Never includes your trips, places '
                'or location.',
            value: decision?.ads,
            onChanged: _measurement.setAds,
          ),
          // Apple's tracking permission is a second, system-level answer to
          // the same question, and only iOS Settings can change it.
          if (defaultTargetPlatform == TargetPlatform.iOS)
            const _IosTrackingNote(),
        ],
      ),
    );
  }

  Widget _tile(
    BuildContext context, {
    required Key key,
    required IconData icon,
    required String title,
    required String subtitle,
    required bool? value,
    required Future<Object?> Function(bool) onChanged,
  }) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: SwitchListTile(
        key: key,
        value: value ?? false,
        // Disabled until the decision has loaded.
        onChanged: value == null ? null : (v) => onChanged(v),
        secondary: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: theme.colorScheme.primary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: theme.colorScheme.primary),
        ),
        title: Text(title),
        subtitle: Text(subtitle),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
    );
  }
}

class _IosTrackingNote extends StatelessWidget {
  const _IosTrackingNote();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 6,
        children: [
          Text(
            'Tracking permission is managed by iOS.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.68),
            ),
          ),
          TextButton(
            key: const ValueKey('settings-open-ios-settings'),
            // The app's own page in iOS Settings, where the Tracking switch
            // lives.
            onPressed: () => launchUrl(Uri.parse('app-settings:')),
            style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('Open iOS Settings'),
          ),
        ],
      ),
    );
  }
}
