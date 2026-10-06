import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/measurement_consent_service.dart';
import '../services/tracking_permission.dart';
import '../utils/measurement_decision.dart';

const String _privacyPolicyUrl = 'https://voyza.xtremon.com/privacy';

// The app theme's body styles are muted greys, so the two voices these
// prompts need are spelled out: what is being asked, and the small print.
TextStyle? _strong(ThemeData theme) => theme.textTheme.bodyMedium
    ?.copyWith(color: theme.colorScheme.onSurface, height: 1.35);

TextStyle? _quiet(ThemeData theme) => theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurface.withValues(alpha: 0.68),
      height: 1.35,
    );

/// The answer to the opt-in prompt: one yes or no per purpose.
typedef MeasurementConsentAnswer = ({bool analytics, bool ads});

/// Puts the right question in front of the person, if there is one: the
/// opt-in prompt in consent regions, the one-time notice elsewhere, nothing
/// when they have already chosen or we cannot yet tell where they are.
/// Records the answer. Safe to call on every launch.
Future<void> maybeShowMeasurementPrompts(
  BuildContext context, {
  MeasurementConsentService? service,
}) async {
  final measurement = service ?? MeasurementConsentService.instance;
  final decision = await measurement.whenRegionSettled();
  if (!context.mounted) return;

  switch (decision.ask) {
    case MeasurementAsk.nothing:
      return;
    case MeasurementAsk.consent:
      final answer = await showMeasurementConsentDialog(
        context,
        // An earlier yes to analytics still stands; ads measurement is new
        // and starts unticked.
        analytics: measurement.choices.analytics ?? false,
      );
      await measurement.recordConsent(
        analytics: answer.analytics,
        ads: answer.ads,
      );
    case MeasurementAsk.notice:
      final keepOn = await showMeasurementNotice(context);
      await measurement.acknowledgeNotice(keepOn: keepOn);
  }
}

/// The opt-in prompt for the EEA, the UK and Switzerland.
///
/// Two purposes, chosen separately, both unticked unless the person agreed
/// to one before. All three buttons look the same: refusing takes exactly
/// as much effort as accepting. It cannot be dismissed without choosing.
Future<MeasurementConsentAnswer> showMeasurementConsentDialog(
  BuildContext context, {
  bool analytics = false,
  bool ads = false,
}) async {
  final answer = await showDialog<MeasurementConsentAnswer>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _ConsentDialog(analytics: analytics, ads: ads),
  );
  return answer ?? (analytics: false, ads: false);
}

class _ConsentDialog extends StatefulWidget {
  const _ConsentDialog({required this.analytics, required this.ads});

  final bool analytics;
  final bool ads;

  @override
  State<_ConsentDialog> createState() => _ConsentDialogState();
}

class _ConsentDialogState extends State<_ConsentDialog> {
  late bool _analytics = widget.analytics;
  late bool _ads = widget.ads;

  void _close(MeasurementConsentAnswer answer) =>
      Navigator.of(context).pop(answer);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final quiet = _quiet(theme);
    return PopScope(
      canPop: false,
      child: AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        // Wider and taller than the default dialog: on a 6.3-inch phone the
        // default left the privacy policy link half a line below the fold.
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        title: const Text('Your privacy choices'),
        contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'VoyZa works fully either way. You decide whether we may '
                'also do these two things:',
                style: _strong(theme),
              ),
              const SizedBox(height: 12),
              _PurposeTile(
                key: const ValueKey('measurement-analytics'),
                value: _analytics,
                onChanged: (v) => setState(() => _analytics = v),
                title: 'Usage analytics',
                body: 'See which features travellers use, so we can improve '
                    'the app. Sent to Google Analytics.',
              ),
              const SizedBox(height: 8),
              _PurposeTile(
                key: const ValueKey('measurement-ads'),
                value: _ads,
                onChanged: (v) => setState(() => _ads = v),
                title: 'Ads measurement',
                body: 'Tell Meta (Facebook, Instagram) and Google when one '
                    'of our ads leads to an install, a trial or a '
                    'subscription, using your device\'s advertising ID. '
                    'They may use this to show VoyZa ads to people likely '
                    'to be interested and to personalise ads on their own '
                    'services.',
              ),
              const SizedBox(height: 12),
              Text(
                'We never send your name, email, trips, places or location '
                'to advertisers. Change this anytime in Settings.',
                style: quiet,
              ),
              const SizedBox(height: 8),
              Text(
                'By allowing either, you confirm you are 16 or older, or '
                'old enough to consent in your country.',
                style: quiet,
              ),
              const _PrivacyPolicyLink(),
            ],
          ),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
        actions: [
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              OutlinedButton(
                onPressed: () => _close((analytics: false, ads: false)),
                child: const Text("Don't allow"),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: _analytics || _ads
                    ? () => _close((analytics: _analytics, ads: _ads))
                    : null,
                child: const Text('Allow selected'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: () => _close((analytics: true, ads: true)),
                child: const Text('Allow all'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PurposeTile extends StatelessWidget {
  const _PurposeTile({
    super.key,
    required this.value,
    required this.onChanged,
    required this.title,
    required this.body,
  });

  final bool value;
  final ValueChanged<bool> onChanged;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => onChanged(!value),
        child: Container(
          padding: const EdgeInsets.fromLTRB(4, 8, 12, 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: value
                  ? theme.colorScheme.primary
                  : theme.dividerColor.withValues(alpha: 0.5),
              width: value ? 1.4 : 1,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Checkbox(
                value: value,
                onChanged: (v) => onChanged(v ?? false),
                visualDensity: VisualDensity.compact,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 2),
                      Text(body, style: _quiet(theme)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PrivacyPolicyLink extends StatelessWidget {
  const _PrivacyPolicyLink();

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton(
        onPressed: () => launchUrl(
          Uri.parse(_privacyPolicyUrl),
          mode: LaunchMode.externalApplication,
        ),
        style: TextButton.styleFrom(
          padding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: const Text('Privacy policy'),
      ),
    );
  }
}

/// The one-time notice for people outside the consent regions, shown before
/// an advertising SDK is used for the first time on the device. Returns
/// false when the person turned ads measurement off there and then.
Future<bool> showMeasurementNotice(BuildContext context) async {
  final keepOn = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      return PopScope(
        canPop: false,
        child: AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Text('How we measure our ads is changing'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'VoyZa is starting to advertise on Facebook and Instagram. '
                  'From now on we tell Meta when one of our ads leads to an '
                  'install, a trial or a subscription, using your device\'s '
                  'advertising ID.',
                  style: _strong(theme),
                ),
                const SizedBox(height: 10),
                Text(
                  'We never send your name, email, trips, places or '
                  'location. You can change this anytime in Settings.',
                  style: _quiet(theme),
                ),
                const _PrivacyPolicyLink(),
              ],
            ),
          ),
          actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          actions: [
            OutlinedButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Turn off'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    },
  );
  return keepOn ?? true;
}

/// Apple's tracking question, with our own explanation in front of it.
///
/// Asked only where ads measurement is on and the system has never asked
/// before. The explanation has one button and it leads to Apple's prompt:
/// no way around it and no nudging, which Apple rejects. The answer goes to
/// the advertising SDKs. Does nothing on builds or platforms without the
/// permission.
Future<void> maybeAskTrackingPermission(
  BuildContext context, {
  MeasurementConsentService? service,
  TrackingPermissionGateway? gateway,
}) async {
  final measurement = service ?? MeasurementConsentService.instance;
  final permission = gateway ?? trackingPermission;
  if (!measurement.adsAllowed) return;
  if (await permission.status() != TrackingStatus.notDetermined) return;
  if (!context.mounted) return;

  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      return PopScope(
        canPop: false,
        child: AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Text('One more choice, from Apple'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Next, iOS will ask whether VoyZa may track. Allowing lets '
                'us see which of our ads brought you here, so we spend on '
                'ads that work and you see fewer that don\'t.',
                style: _strong(theme),
              ),
              const SizedBox(height: 10),
              Text(
                'It does not change how VoyZa works, and we never send your '
                'trips, places or location.',
                style: _quiet(theme),
              ),
            ],
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Continue'),
            ),
          ],
        ),
      );
    },
  );

  final answer = await permission.request();
  await measurement.reportTrackingAllowed(answer == TrackingStatus.authorized);
}
