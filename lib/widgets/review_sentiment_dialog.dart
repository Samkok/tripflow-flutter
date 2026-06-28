import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/review_prompt_service.dart';
import 'app_toast.dart';

/// Private feedback destination used when a user says they're NOT yet enjoying
/// the app — keeps that signal out of the public App Store rating. Mirrors the
/// address used by the Settings "Send Feedback" tile.
const String _feedbackEmail = 'hengsamkok76@gmail.com';

enum _Sentiment { positive, negative }

/// Sentiment pre-gate: ask how the user feels BEFORE touching the OS review
/// prompt. Happy users are routed to the real store prompt; everyone else is
/// routed to private feedback. Caller must have already confirmed eligibility
/// via [ReviewPromptService.isEligibleForPrompt].
///
/// Safe to call fire-and-forget; it owns all of its own error handling and the
/// [ReviewPromptService] bookkeeping for every outcome (including dismissal).
Future<void> showReviewSentimentFlow(BuildContext context) async {
  final sentiment = await showDialog<_Sentiment>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => const _ReviewSentimentDialog(),
  );

  if (!context.mounted) {
    // Still record the showing so we respect the cooldown next time.
    await ReviewPromptService.instance.markPromptShown();
    return;
  }

  switch (sentiment) {
    case _Sentiment.positive:
      final shown = await ReviewPromptService.instance.submitPositiveReview();
      if (!shown && context.mounted) {
        AppToast.info(
          context,
          'Thanks! The rating prompt is unavailable right now — '
          'you can rate VoyZa anytime from Settings.',
        );
      }
      break;
    case _Sentiment.negative:
      await ReviewPromptService.instance.markPromptShown();
      await _openFeedbackEmail(context);
      break;
    case null:
      // Dismissed without choosing — apply the cooldown but preserve an
      // OS-prompt slot for a future, more deliberate ask.
      await ReviewPromptService.instance.markPromptShown();
      break;
  }
}

Future<void> _openFeedbackEmail(BuildContext context) async {
  final uri = Uri(
    scheme: 'mailto',
    path: _feedbackEmail,
    queryParameters: {'subject': 'VoyZa Feedback'},
  );
  try {
    final ok = await launchUrl(uri);
    if (!ok && context.mounted) {
      AppToast.warning(
        context,
        'No mail app available. Email us at $_feedbackEmail',
      );
    }
  } catch (_) {
    if (context.mounted) {
      AppToast.error(
        context,
        'Could not open mail. Email us at $_feedbackEmail',
      );
    }
  }
}

class _ReviewSentimentDialog extends StatelessWidget {
  const _ReviewSentimentDialog();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20.0)),
      elevation: 5,
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.route_rounded,
              color: theme.colorScheme.primary,
              size: 64.0,
            ),
            const SizedBox(height: 20.0),
            Text(
              'Enjoying VoyZa?',
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineSmall
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12.0),
            Text(
              'Your trip is all mapped out. Are you happy with how VoyZa '
              'plans your routes?',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 24.0),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () =>
                    Navigator.of(context).pop(_Sentiment.positive),
                child: const Text('Yes, loving it'),
              ),
            ),
            const SizedBox(height: 8.0),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: () =>
                    Navigator.of(context).pop(_Sentiment.negative),
                child: const Text('Not really'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
