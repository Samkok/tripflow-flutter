import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../providers/email_verified_provider.dart';
import '../providers/onboarding_checklist_provider.dart';
import '../services/email_otp_service.dart';
import '../services/referral_service.dart';
import '../services/supabase_service.dart';

/// What the entered code proves.
enum OtpSheetMode {
  /// Prove the account's current email (stamps email_verified_at).
  verifyEmail,

  /// Prove a NEW address; the server swaps the account onto it.
  changeEmail,

  /// Password reset: the code comes from Supabase's recovery email and is
  /// checked with auth.verifyOTP — success signs this device in and fires
  /// the passwordRecovery event (main.dart pushes ResetPasswordScreen).
  recovery,
}

/// Opens the 6-digit code sheet. Resolves to `true` on success.
///
/// [email]: recovery target / new address for changeEmail; defaults to the
/// signed-in user's email for verifyEmail. [sendOnOpen]: the sheet fires
/// its own send first (used by "Verify now" buttons — a recent-send
/// cooldown is handled gracefully); pass false when the caller already
/// sent the code.
Future<bool?> showOtpEntrySheet(
  BuildContext context, {
  required OtpSheetMode mode,
  String? email,
  bool sendOnOpen = false,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (_) => OtpEntrySheet(
      mode: mode,
      email: email,
      sendOnOpen: sendOnOpen,
    ),
  );
}

class OtpEntrySheet extends ConsumerStatefulWidget {
  final OtpSheetMode mode;
  final String? email;
  final bool sendOnOpen;

  const OtpEntrySheet({
    super.key,
    required this.mode,
    this.email,
    this.sendOnOpen = false,
  });

  @override
  ConsumerState<OtpEntrySheet> createState() => _OtpEntrySheetState();
}

class _OtpEntrySheetState extends ConsumerState<OtpEntrySheet> {
  final _codeCtrl = TextEditingController();
  final _focus = FocusNode();

  bool _verifying = false;
  bool _resending = false;
  String? _error;
  String? _info;
  int _cooldown = 0;
  Timer? _timer;

  String get _targetEmail =>
      widget.email ??
      SupabaseService.instance.client.auth.currentUser?.email ??
      'your email';

  @override
  void initState() {
    super.initState();
    _codeCtrl.addListener(_onCodeChanged);
    if (widget.sendOnOpen) {
      // Sheet owns the initial send (Verify-now entry points).
      WidgetsBinding.instance.addPostFrameCallback((_) => _send());
    } else {
      // Caller just sent the code — mirror the server's 60s cooldown.
      _startCooldown(60);
    }
  }

  void _onCodeChanged() {
    // Wipe messages only when the user is actually typing. A failed
    // attempt sets _error and then clears the field programmatically —
    // that clear() fires this listener synchronously, and wiping on empty
    // text would erase the red label the same frame it appeared.
    if (_codeCtrl.text.isNotEmpty && (_error != null || _info != null)) {
      setState(() {
        _error = null;
        _info = null;
      });
    } else {
      setState(() {});
    }
    if (_codeCtrl.text.length == 6 && !_verifying) _submit();
  }

  /// Fills the boxes from the clipboard — the email says "copy the code",
  /// so the sheet must accept it in one tap. Tolerates surrounding text
  /// ("123456 is your VoyZa verification code") by grabbing the first
  /// 6-digit run; spaces/dashes inside the code are stripped first.
  Future<void> _pasteCode() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = (data?.text ?? '').replaceAll(RegExp(r'[\s -]'), '');
    final match = RegExp(r'\d{6}').firstMatch(text);
    if (!mounted) return;
    if (match == null) {
      setState(() {
        _info = null;
        _error = 'No 6-digit code found in your clipboard.';
      });
      return;
    }
    // Setting the text fires the listener: boxes fill and, at 6 digits,
    // verification submits itself.
    _codeCtrl.text = match.group(0)!;
  }

  void _startCooldown(int seconds) {
    _timer?.cancel();
    setState(() => _cooldown = seconds);
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _cooldown = _cooldown - 1);
      if (_cooldown <= 0) t.cancel();
    });
  }

  // ── Send / resend ─────────────────────────────────────────────────────

  Future<void> _send() async {
    if (_resending) return;
    setState(() {
      _resending = true;
      _error = null;
      _info = null;
    });

    if (widget.mode == OtpSheetMode.recovery) {
      // Supabase mails the recovery code (template carries {{ .Token }}).
      try {
        await SupabaseService.instance.client.auth.resetPasswordForEmail(
          _targetEmail,
        );
        if (mounted) {
          setState(() => _info = 'Code sent to $_targetEmail.');
          _startCooldown(60);
        }
      } catch (_) {
        if (mounted) {
          setState(
              () => _error = "Couldn't send the code. Try again shortly.");
        }
      }
      if (mounted) setState(() => _resending = false);
      return;
    }

    final status = await EmailOtpService.sendCode(
      purpose:
          widget.mode == OtpSheetMode.changeEmail ? 'email_change' : 'verify',
      newEmail:
          widget.mode == OtpSheetMode.changeEmail ? widget.email : null,
    );
    if (!mounted) return;
    setState(() {
      _resending = false;
      switch (status) {
        case OtpSendStatus.sent:
          _info = 'Code sent to $_targetEmail.';
          _startCooldown(60);
        case OtpSendStatus.cooldown:
          // A live code already went out moments ago — not an error.
          _info = 'We already sent a code — check your inbox '
              '(and spam folder).';
          _startCooldown(60);
        case OtpSendStatus.rateLimited:
          _error = 'Too many codes requested. Try again in about an hour.';
          _startCooldown(60);
        case OtpSendStatus.emailTaken:
          _error = 'That email already belongs to a VoyZa account.';
        case OtpSendStatus.sameEmail:
          _error = "That's already this account's email.";
        case OtpSendStatus.invalidEmail:
          _error = "That doesn't look like an email address.";
        case OtpSendStatus.failed:
          _error = "Couldn't send the code. Try again shortly.";
      }
    });
  }

  // ── Verify ────────────────────────────────────────────────────────────

  Future<void> _submit() async {
    final code = _codeCtrl.text;
    if (code.length != 6 || _verifying) return;
    setState(() {
      _verifying = true;
      _error = null;
      _info = null;
    });

    if (widget.mode == OtpSheetMode.recovery) {
      try {
        await SupabaseService.instance.client.auth.verifyOTP(
          type: OtpType.recovery,
          email: _targetEmail,
          token: code,
        );
        // Session established; the passwordRecovery event navigates.
        HapticFeedback.mediumImpact();
        if (mounted) Navigator.of(context).pop(true);
      } on AuthException {
        if (mounted) {
          setState(() {
            _verifying = false;
            _error = 'That code is incorrect or expired.';
            _codeCtrl.clear();
          });
        }
      } catch (_) {
        if (mounted) {
          setState(() {
            _verifying = false;
            _error = 'Something went wrong. Try again.';
          });
        }
      }
      return;
    }

    final isChange = widget.mode == OtpSheetMode.changeEmail;
    final result = await EmailOtpService.verifyCode(
      purpose: isChange ? 'email_change' : 'verify',
      code: code,
    );
    if (!mounted) return;

    if (result.status == OtpVerifyStatus.verified) {
      if (isChange) {
        // The JWT still carries the old address until refreshed. Best
        // effort — a failure here self-heals on the next token refresh.
        try {
          await SupabaseService.instance.client.auth.refreshSession();
        } catch (_) {}
      } else {
        // Freshly verified: the server gates just opened — run the
        // claims that were parked at signup (pending referral code,
        // pending trip invites). Both idempotent.
        unawaited(ReferralService.instance.redeemPendingCodeIfAny());
        unawaited(ReferralService.instance.claimInvites().then((joined) {
          if (joined > 0 && mounted) {
            ref.read(checklistProvider.notifier).skip();
          }
        }));
      }
      ref.invalidate(emailVerifiedProvider);
      HapticFeedback.mediumImpact();
      if (mounted) Navigator.of(context).pop(true);
      return;
    }

    setState(() {
      _verifying = false;
      switch (result.status) {
        case OtpVerifyStatus.invalidCode:
          final left = result.attemptsLeft;
          _error = left != null && left > 0
              ? 'Incorrect code — $left ${left == 1 ? 'try' : 'tries'} left.'
              : 'Incorrect code.';
          _codeCtrl.clear();
        case OtpVerifyStatus.expired:
          _error = 'That code expired. Tap Resend for a fresh one.';
          _codeCtrl.clear();
        case OtpVerifyStatus.noCode:
          _error = 'No active code. Tap Resend to get one.';
          _codeCtrl.clear();
        case OtpVerifyStatus.tooManyAttempts:
          _error = 'Too many wrong tries — that code is dead. '
              'Tap Resend for a fresh one.';
          _codeCtrl.clear();
        case OtpVerifyStatus.emailTaken:
          _error =
              'That email was just registered by another account.';
        case OtpVerifyStatus.verified:
          break; // handled above
        case OtpVerifyStatus.failed:
          _error = 'Something went wrong. Try again.';
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _codeCtrl.removeListener(_onCodeChanged);
    _codeCtrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  // ── UI ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, title, subtitleLead) = switch (widget.mode) {
      OtpSheetMode.verifyEmail => (
          Icons.mark_email_read_outlined,
          'Verify your email',
          'Enter the 6-digit code we sent to',
        ),
      OtpSheetMode.changeEmail => (
          Icons.alternate_email_rounded,
          'Confirm your new email',
          'Enter the 6-digit code we sent to',
        ),
      OtpSheetMode.recovery => (
          Icons.lock_reset_rounded,
          'Enter reset code',
          'We sent a 6-digit code to',
        ),
    };

    // The numeric keyboard is always up here, so the content must live in a
    // scroll view keyed to the keyboard inset — otherwise a tall sheet on a
    // short phone clips the code boxes against the number pad. Spacing is
    // kept tight so all six boxes still fit above the keyboard without any
    // scrolling on common devices; the scroll view is the safety net for the
    // smallest ones.
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 10, 24, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color:
                          theme.colorScheme.onSurface.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Center(
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withValues(alpha: 0.1),
                      shape: BoxShape.circle,
                    ),
                    child:
                        Icon(icon, size: 28, color: theme.colorScheme.primary),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
              Text.rich(
                TextSpan(
                  text: '$subtitleLead\n',
                  children: [
                    TextSpan(
                      text: _targetEmail,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 18),
              _buildCodeBoxes(theme),
              const SizedBox(height: 4),
              Center(
                child: TextButton.icon(
                  onPressed: _verifying ? null : _pasteCode,
                  icon: const Icon(Icons.content_paste_rounded, size: 16),
                  label: const Text(
                    'Paste code',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              if (_error != null)
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                    fontWeight: FontWeight.w600,
                  ),
                )
              else if (_info != null)
                Text(
                  _info!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                )
              else
                const SizedBox(height: 16),
              const SizedBox(height: 14),
              FilledButton(
                onPressed: (_codeCtrl.text.length == 6 && !_verifying)
                    ? _submit
                    : null,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: _verifying
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      )
                    : const Text('Verify',
                        style: TextStyle(fontWeight: FontWeight.w700)),
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    "Didn't get it?",
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                  TextButton(
                    onPressed:
                        (_cooldown > 0 || _resending) ? null : _send,
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                    child: Text(
                      _cooldown > 0
                          ? 'Resend in ${_cooldown}s'
                          : _resending
                              ? 'Sending…'
                              : 'Resend code',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCodeBoxes(ThemeData theme) {
    final text = _codeCtrl.text;
    // Tapping anywhere on the row focuses the hidden field. The field sits
    // BEHIND the boxes (not a Positioned.fill overlay — that overlay was
    // hard-clipping the boxes to half-height on shorter screens) and is
    // made zero-opacity rather than zero-size so iOS still offers the
    // one-time-code from Mail/Messages.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => FocusScope.of(context).requestFocus(_focus),
      child: Stack(
        alignment: Alignment.center,
        clipBehavior: Clip.none,
        children: [
          // Hidden input — 1pt tall, centered behind the boxes.
          SizedBox(
            width: 1,
            height: 1,
            child: Opacity(
              opacity: 0,
              child: TextField(
                controller: _codeCtrl,
                focusNode: _focus,
                autofocus: true,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(6),
                ],
                autofillHints: const [AutofillHints.oneTimeCode],
                showCursor: false,
                enableInteractiveSelection: false,
                cursorColor: Colors.transparent,
                style: const TextStyle(color: Colors.transparent),
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  counterText: '',
                  isCollapsed: true,
                ),
              ),
            ),
          ),
          IgnorePointer(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(6, (i) {
                final filled = i < text.length;
                final active = i == text.length && _focus.hasFocus;
                // Whole row turns red while a wrong-code error is showing
                // (cleared the moment the user starts typing again).
                final borderColor = _error != null
                    ? theme.colorScheme.error
                    : active
                        ? theme.colorScheme.primary
                        : filled
                            ? theme.colorScheme.primary.withValues(alpha: 0.5)
                            : theme.dividerColor.withValues(alpha: 0.4);
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  width: 44,
                  height: 54,
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      width: (active || _error != null) ? 2 : 1.2,
                      color: borderColor,
                    ),
                  ),
                  child: Text(
                    filled ? text[i] : '',
                    style: theme.textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                );
              }),
            ),
          ),
        ],
      ),
    );
  }
}
