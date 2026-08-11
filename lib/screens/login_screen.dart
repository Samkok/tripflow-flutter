import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyza/screens/signup_screen.dart';
import 'package:voyza/screens/forgot_password_screen.dart';
import 'package:voyza/widgets/rotating_globe_background.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../providers/trip_collaborator_provider.dart';
import '../providers/user_trip_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/subscription_provider.dart';
import '../services/auth_service.dart';
import '../services/email_history_service.dart';
import '../widgets/app_toast.dart';
import '../widgets/email_suggestions.dart';
import '../widgets/save_password_prompt.dart';
import '../widgets/sync_confirmation_dialog.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  final _emailFocusNode = FocusNode();
  bool _isLoading = false;
  String _authStage = '';
  double _authProgress = 0;
  bool _isPasswordVisible = false;
  bool _rememberMe = true;

  @override
  void initState() {
    super.initState();
    _loadRememberMe();
    // Suggestions react to BOTH focus and typing, so rebuild on either.
    _emailFocusNode.addListener(_onEmailUiChanged);
    _emailController.addListener(_onEmailUiChanged);
    EmailHistoryService.instance.load().then((_) {
      if (mounted) setState(() {});
    });
  }

  void _onEmailUiChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadRememberMe() async {
    final remember = await AuthService.getRememberMe();
    final savedEmail = await AuthService.getSavedEmail();
    if (mounted) {
      setState(() {
        _rememberMe = remember;
        if (remember && savedEmail != null) {
          _emailController.text = savedEmail;
        }
      });
    }
  }

  /// Cooldown so the resend button can't be hammered (Supabase also
  /// rate-limits server-side; this keeps the UI honest about it).
  DateTime? _resendAvailableAt;

  void _showVerifyEmailDialog(String email) {
    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final now = DateTime.now();
          final coolingDown =
              _resendAvailableAt != null && now.isBefore(_resendAvailableAt!);
          return AlertDialog(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: const Text('Email not verified yet'),
            content: Text(
              'Your account exists, but $email hasn\'t been verified. '
              'Open the verification link we emailed you, then sign in '
              'again.\n\nNo email? Check your spam folder — or resend it '
              'below.',
            ),
            actions: [
              TextButton(
                onPressed: coolingDown
                    ? null
                    : () async {
                        try {
                          await ref
                              .read(authServiceProvider)
                              .resendVerificationEmail(email);
                          _resendAvailableAt =
                              DateTime.now().add(const Duration(seconds: 60));
                          setDialogState(() {});
                          if (ctx.mounted) {
                            AppToast.success(
                                ctx, 'Verification email sent to $email');
                          }
                        } on AuthException catch (e) {
                          if (ctx.mounted) AppToast.error(ctx, e.message);
                        } catch (_) {
                          if (ctx.mounted) {
                            AppToast.error(ctx,
                                'Could not resend right now — try again shortly.');
                          }
                        }
                      },
                child: Text(coolingDown
                    ? 'Sent — wait a minute'
                    : 'Resend verification email'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('OK'),
              ),
            ],
          );
        },
      ),
    );
  }

  static String _syncSummary(int trips, int places) {
    final parts = <String>[
      if (trips > 0) '$trips trip${trips != 1 ? 's' : ''}',
      if (places > 0) '$places place${places != 1 ? 's' : ''}',
    ];
    return parts.join(' and ');
  }

  Future<void> _signIn() async {
    if (!_formKey.currentState!.validate()) return;

    // Ask the sync question BEFORE authenticating (owner decision): the
    // answer is taken up front, its consequences run only after a session
    // exists — so a failed password never costs the guest their data.
    bool? syncDecision;
    final localCounts =
        await ref.read(authServiceProvider).getLocalDataCounts();
    if (localCounts.trips > 0 || localCounts.places > 0) {
      // Already answered "yes" at sign-up (email-verify flow) → don't
      // re-ask, just carry the sync out after auth.
      if (await AuthService.getSyncChoice() == true) {
        syncDecision = true;
      } else {
        if (!mounted) return;
        syncDecision = await showDialog<bool>(
              context: context,
              barrierDismissible: false,
              builder: (context) => SyncConfirmationDialog(
                localLocationCount: localCounts.places,
                localTripCount: localCounts.trips,
              ),
            ) ??
            false;
      }
    }
    if (!mounted) return;

    setState(() {
      _isLoading = true;
      _authStage = 'Starting…';
      _authProgress = 0.05;
    });
    try {
      await ref.read(authServiceProvider).signIn(
        _emailController.text,
        _passwordController.text,
        onStage: (label, progress) {
          if (mounted) {
            setState(() {
              _authStage = label;
              _authProgress = progress;
            });
          }
        },
      );

      if (!mounted) return;

      // Ask the user (once per email) whether to save the credential
      // to the device's password manager, then commit the autofill
      // context with their answer. Logic lives in the shared helper
      // so signup and signin behave identically.
      await promptSavePasswordIfNeeded(context, _emailController.text.trim());
      if (!mounted) return;

      // Carry out the decision taken before authentication.
      if (syncDecision == true) {
        setState(() {
          _authStage = 'Syncing your trips and places…';
          _authProgress = 0.97;
        });
        await ref.read(authServiceProvider).syncLocalLocations();
        // Surface the freshly synced trips immediately — without this the
        // home list stays on its pre-sync fetch until a manual refresh.
        ref.invalidate(userTripsProvider);
        ref.invalidate(sharedTripsProvider);
        if (mounted) {
          AppToast.success(
            context,
            'Synced ${_syncSummary(localCounts.trips, localCounts.places)} to your account!',
          );
        }
      } else if (syncDecision == false) {
        await ref.read(authServiceProvider).declineSync();
        ref.invalidate(userTripsProvider);
        ref.invalidate(sharedTripsProvider);
      }

      // Reinitialize subscription for the newly signed-in user (fire-and-forget)
      ref.read(subscriptionProvider.notifier).reinitialize();

      // Save preference before async gap (fire-and-forget is safe for prefs)
      AuthService.saveRememberMe(_rememberMe, _emailController.text.trim());
      // Offer this address back next time an auth screen opens.
      await EmailHistoryService.instance.remember(_emailController.text);
      if (mounted) {
        // If we were pushed on top of an existing screen (e.g. settings),
        // just pop back. If we ARE the root route — typically after a
        // sign-out cleared the stack — replace ourselves with /home so the
        // user lands inside the app instead of an empty navigator.
        final navigator = Navigator.of(context);
        if (navigator.canPop()) {
          navigator.pop();
        } else {
          navigator.pushReplacementNamed('/home');
        }
      }
    } on AuthException catch (e) {
      if (mounted) {
        final msg = e.message.toLowerCase();
        if (e.code == 'email_not_confirmed' || msg.contains('not confirmed')) {
          _showVerifyEmailDialog(_emailController.text.trim());
        } else {
          AppToast.error(context, e.message);
        }
      }
    } catch (e) {
      if (mounted) {
        AppToast.error(context, 'Unexpected error occurred');
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // True when LoginScreen is the only route on the stack — i.e. it was
    // shown via pushAndRemoveUntil after a sign-out. In that case the
    // dismiss action takes the user into anonymous mode instead of popping
    // into a blank navigator.
    final isRootRoute = !(ModalRoute.of(context)?.canPop ?? false);
    void dismiss() {
      final navigator = Navigator.of(context);
      if (navigator.canPop()) {
        navigator.pop();
      } else {
        navigator.pushReplacementNamed('/home_anonymous');
      }
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        dismiss();
      },
      child: Stack(
        children: [
          // Ambient rotating globe behind the sign-in surface.
          Positioned.fill(
            child: ColoredBox(
              color: Theme.of(context).scaffoldBackgroundColor,
              child: const RotatingGlobeBackground(),
            ),
          ),
          Scaffold(
            backgroundColor: Colors.transparent,
            // Tap anywhere outside a field to dismiss the keyboard.
            // Translucent so fields and buttons still get their taps first.
            body: GestureDetector(
              onTap: () => FocusScope.of(context).unfocus(),
              behavior: HitTestBehavior.translucent,
              child: SafeArea(
                child: Stack(
                  children: [
                    Center(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(24.0),
                        child: Form(
                          key: _formKey,
                          // AutofillGroup pairs the email + password fields as
                          // one credential, so the platform autofill picker
                          // (iOS Passwords AutoFill / Android Google Password
                          // Manager / etc.) fills both at once when the user
                          // picks a saved login.
                          child: AutofillGroup(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Image.asset(
                                  'assets/images/logo.png',
                                  width: 100,
                                  height: 100,
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  'Welcome Back',
                                  textAlign: TextAlign.center,
                                  style:
                                      theme.textTheme.headlineMedium?.copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'Sign in to continue your journey',
                                  textAlign: TextAlign.center,
                                  style: theme.textTheme.titleMedium?.copyWith(
                                      color:
                                          theme.colorScheme.onSurfaceVariant),
                                ),
                                const SizedBox(height: 40),
                                TextFormField(
                                  controller: _emailController,
                                  focusNode: _emailFocusNode,
                                  keyboardType: TextInputType.emailAddress,
                                  // username + email pair maximises coverage: iOS
                                  // matches saved logins by `username`, Android
                                  // by `email`. The Passwords / yellow-key bar
                                  // above the keyboard appears once the field
                                  // focuses.
                                  autofillHints: const [
                                    AutofillHints.username,
                                    AutofillHints.email,
                                  ],
                                  textInputAction: TextInputAction.next,
                                  decoration: const InputDecoration(
                                    labelText: 'Email',
                                    prefixIcon: Icon(Icons.email_outlined),
                                  ),
                                  validator: (val) {
                                    if (val == null ||
                                        val.isEmpty ||
                                        !val.contains('@')) {
                                      return 'Please enter a valid email';
                                    }
                                    return null;
                                  },
                                ),
                                // Emails this device has used before.
                                EmailSuggestions(
                                  visible: _emailFocusNode.hasFocus,
                                  query: _emailController.text,
                                  onSelected: (email) {
                                    _emailController.text = email;
                                    _emailFocusNode.unfocus();
                                  },
                                  onForget: (email) async {
                                    await EmailHistoryService.instance
                                        .forget(email);
                                    if (mounted) setState(() {});
                                  },
                                ),
                                const SizedBox(height: 20),
                                TextFormField(
                                  controller: _passwordController,
                                  obscureText: !_isPasswordVisible,
                                  autofillHints: const [AutofillHints.password],
                                  textInputAction: TextInputAction.done,
                                  onFieldSubmitted: (_) {
                                    if (!_isLoading) _signIn();
                                  },
                                  decoration: InputDecoration(
                                    labelText: 'Password',
                                    prefixIcon: const Icon(Icons.lock_outline),
                                    suffixIcon: IconButton(
                                      icon: Icon(
                                        _isPasswordVisible
                                            ? Icons.visibility_off_outlined
                                            : Icons.visibility_outlined,
                                      ),
                                      onPressed: () {
                                        setState(() {
                                          _isPasswordVisible =
                                              !_isPasswordVisible;
                                        });
                                      },
                                    ),
                                  ),
                                  validator: (val) => val == null || val.isEmpty
                                      ? 'Please enter your password'
                                      : null,
                                ),
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    Checkbox(
                                      value: _rememberMe,
                                      onChanged: (val) => setState(
                                          () => _rememberMe = val ?? true),
                                      activeColor: theme.colorScheme.primary,
                                    ),
                                    const Text('Remember Me'),
                                  ],
                                ),
                                const SizedBox(height: 16),
                                ElevatedButton(
                                  onPressed: _isLoading ? null : _signIn,
                                  child: _isLoading
                                      ? const SizedBox(
                                          height: 24,
                                          width: 24,
                                          child: CircularProgressIndicator(
                                              strokeWidth: 3),
                                        )
                                      : const Text('Sign In'),
                                ),
                                // Staged progress: signing in does real work
                                // (subscription link, notifications, sync) —
                                // show which step is running so a slow network
                                // never reads as a frozen app.
                                if (_isLoading) ...[
                                  const SizedBox(height: 14),
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(3),
                                    child: TweenAnimationBuilder<double>(
                                      tween: Tween(end: _authProgress),
                                      duration:
                                          const Duration(milliseconds: 350),
                                      builder: (_, v, __) =>
                                          LinearProgressIndicator(
                                        value: v,
                                        minHeight: 5,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .primary,
                                        backgroundColor: Theme.of(context)
                                            .colorScheme
                                            .primary
                                            .withValues(alpha: 0.15),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    _authStage,
                                    textAlign: TextAlign.center,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall
                                        ?.copyWith(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .onSurfaceVariant),
                                  ),
                                ],
                                const SizedBox(height: 24),
                                TextButton(
                                  onPressed: () {
                                    Navigator.of(context).push(
                                        MaterialPageRoute(
                                            builder: (_) =>
                                                const SignupScreen()));
                                  },
                                  child: const Text(
                                      "Don't have an account? Sign Up"),
                                ),
                                const SizedBox(height: 8),
                                TextButton(
                                  onPressed: () {
                                    Navigator.of(context).push(
                                        MaterialPageRoute(
                                            builder: (_) =>
                                                const ForgotPasswordScreen()));
                                  },
                                  child: const Text('Forgot Password?'),
                                ),
                                if (isRootRoute) ...[
                                  const SizedBox(height: 8),
                                  TextButton(
                                    onPressed: dismiss,
                                    child: const Text('Continue as guest'),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      top: 8,
                      right: 8,
                      child: IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: dismiss,
                        tooltip: isRootRoute ? 'Continue as guest' : 'Dismiss',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _emailFocusNode.removeListener(_onEmailUiChanged);
    _emailController.removeListener(_onEmailUiChanged);
    _emailFocusNode.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }
}
