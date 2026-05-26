import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/auth_service.dart';

/// Asks the user whether to save the just-used credential to the
/// device's password manager, and routes the answer through
/// `TextInput.finishAutofillContext` so iOS Keychain / Android's
/// autofill provider show their native save sheet only when the user
/// opted in. The per-email "have we asked?" flag is tracked via
/// [AuthService.hasPromptedSavePassword] / [markPromptedSavePassword]
/// so the same address never gets re-prompted on later flows.
///
/// Call this immediately after a successful `signIn()` or `signUp()`
/// — the autofill context still has the credential attached, so
/// `finishAutofillContext` can hand it to the OS. The current screen
/// must still be mounted; pop AFTER this returns.
Future<void> promptSavePasswordIfNeeded(
  BuildContext context,
  String email,
) async {
  final trimmed = email.trim();
  if (trimmed.isEmpty) return;

  final alreadyAsked = await AuthService.hasPromptedSavePassword(trimmed);
  if (!context.mounted) return;

  if (alreadyAsked) {
    // Already responded for this address — don't re-ask, and
    // suppress the OS prompt for consistency with the previous answer.
    TextInput.finishAutofillContext(shouldSave: false);
    return;
  }

  final shouldSave = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('Save your password?'),
      content: const Text(
        'Save this password to your device so you can sign in faster '
        'next time. You can manage saved passwords in your device '
        'settings at any time.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Not now'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  if (!context.mounted) return;

  // shouldSave == true → finishAutofillContext signals the OS to show
  // its native save sheet. false / null → suppress the OS prompt too.
  TextInput.finishAutofillContext(shouldSave: shouldSave == true);

  // Remember the choice (Save OR Not now) so we never nag for the same
  // address again on later sign-ins / sign-ups.
  unawaited(AuthService.markPromptedSavePassword(trimmed));
}
