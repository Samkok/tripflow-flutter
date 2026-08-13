import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:purchases_ui_flutter/purchases_ui_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:intl/intl.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'dart:io';
import '../providers/subscription_provider.dart';
import '../providers/user_trip_provider.dart';
import '../services/analytics_service.dart';
import '../providers/location_provider.dart';
import '../services/revenuecat_service.dart';
import '../services/referral_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/subscription_limit_service.dart';
import '../services/supabase_service.dart';
import '../widgets/app_toast.dart';
import '../widgets/referral_prompt.dart';
import '../widgets/sign_up_required_sheet.dart';
import '../repositories/user_profile_repository.dart';
import 'package:voyza/widgets/rotating_globe_background.dart';

/// Reasons the paywall might be shown — drives the headline copy.
enum PaywallTrigger {
  trialExpired,
  upgradePrompt,

  /// The free saved-place allowance is used up (see
  /// [SubscriptionLimitService.freePlaceAllowance]).
  placeLimit,
}

/// True while a paywall route is on the Navigator stack. Lets app-level
/// chrome (e.g. the trial countdown banner mounted above the Navigator)
/// hide itself so it can't be tapped to push a duplicate paywall.
final paywallVisibleProvider = StateProvider<bool>((_) => false);

/// Paywall screen that displays subscription options using RevenueCat Paywall UI
class PaywallScreen extends ConsumerStatefulWidget {
  /// What triggered this paywall presentation. Drives the headline copy so
  /// users coming from an expired trial see "Your free trial has ended"
  /// instead of the generic upsell.
  final PaywallTrigger trigger;

  const PaywallScreen({
    super.key,
    this.trigger = PaywallTrigger.upgradePrompt,
  });

  @override
  ConsumerState<PaywallScreen> createState() => _PaywallScreenState();
}

class _PaywallScreenState extends ConsumerState<PaywallScreen> {
  bool _isLoading = false;
  Package? _selectedPackage;

  // ── Referral-at-paywall ──────────────────────────────────────────────
  // A code saved at sign-up that never got redeemed surfaces as a banner;
  // anyone else can open a small entry field. A successful redemption
  // replaces the subscribe CTA with the promo-applied card.
  String? _pendingReferralCode;
  bool _showCodeField = false;
  bool _redeemingCode = false;
  DateTime? _promoExpiresAt;
  final _codeController = TextEditingController();

  // Referral redemption needs a LINKED EMAIL, not just a session — instant
  // (anonymous) accounts are free identities, and the server rejects them.
  // The name is kept: every use of this getter is a referral gate.
  bool get _signedIn {
    final user = SupabaseService.instance.client.auth.currentUser;
    if (user == null || user.isAnonymous) return false;
    return (user.email ?? '').isNotEmpty;
  }

  @override
  void initState() {
    super.initState();
    _loadPendingReferralCode();
  }

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _loadPendingReferralCode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final code = prefs.getString('pending_referral_code');
      if (mounted && code != null && code.isNotEmpty) {
        setState(() => _pendingReferralCode = code);
      }
    } catch (_) {}
  }

  Future<void> _applyReferralCode(String rawCode) async {
    final code = rawCode.trim().toUpperCase();
    if (code.isEmpty || _redeemingCode) return;
    // Belt-and-braces: the redeem UI is hidden for guests, but if this is
    // ever reached without a session, route to auth instead of failing
    // with a misleading "check your connection" toast.
    if (!_signedIn) {
      showSignUpRequiredSheet(
        context,
        icon: Icons.redeem_rounded,
        title: 'Sign in to redeem your code',
        message: 'Referral codes attach to an account. Signing in redeems '
            'yours automatically — 30 days of Pro, no payment.',
      );
      return;
    }
    setState(() => _redeemingCode = true);
    try {
      final result = await ReferralService.instance.redeemCode(code);
      if (!mounted) return;
      switch (result) {
        case RedeemResult.redeemed:
          await ReferralService.instance.clearPendingCode();
          // Flip isPro so the rest of the app (and this screen) sees the
          // promotional entitlement immediately.
          await ref.read(subscriptionProvider.notifier).reinitialize();
          DateTime? expires;
          try {
            final info = await RevenueCatService().getCustomerInfo();
            final raw = info.entitlements.active['premium']?.expirationDate;
            if (raw != null) expires = DateTime.tryParse(raw)?.toLocal();
          } catch (_) {}
          if (!mounted) return;
          setState(() {
            _promoExpiresAt =
                expires ?? DateTime.now().add(const Duration(days: 30));
            _pendingReferralCode = null;
            _showCodeField = false;
          });
        case RedeemResult.alreadyRedeemed:
          await ReferralService.instance.clearPendingCode();
          if (mounted) {
            setState(() => _pendingReferralCode = null);
            AppToast.info(context,
                'A referral code was already redeemed on this account.');
          }
        case RedeemResult.invalidCode:
          AppToast.error(
              context, "That code doesn't look right — double-check it.");
        case RedeemResult.selfReferral:
          AppToast.error(context, "You can't redeem your own code.");
        case RedeemResult.windowExpired:
          await ReferralService.instance.clearPendingCode();
          if (mounted) {
            setState(() => _pendingReferralCode = null);
            AppToast.error(
                context, "This code's redemption window has passed.");
          }
        case RedeemResult.rateLimited:
          AppToast.error(
              context, 'Too many attempts — try again in a few minutes.');
        case RedeemResult.transientFailure:
          AppToast.error(context,
              'Could not apply the code. Check your connection and try again.');
      }
    } finally {
      if (mounted) setState(() => _redeemingCode = false);
    }
  }

  /// One-shot diagnostic so we can verify whether the App Store / Play Store
  /// intro offer is reaching the app. Look for `[Paywall diag]` in logs.
  bool _loggedDiag = false;
  void _logIntroOfferDiagnostic() {
    if (_loggedDiag) return;
    final monthly = ref.read(monthlyPackageProvider).asData?.value;
    final yearly = ref.read(yearlyPackageProvider).asData?.value;
    if (monthly == null && yearly == null) return; // not loaded yet
    _loggedDiag = true;
    void dump(String label, Package? p) {
      if (p == null) {
        debugPrint('[Paywall diag] $label: <not in offering>');
        return;
      }
      final sp = p.storeProduct;
      final intro = sp.introductoryPrice;
      // Android surfaces the trial via the default subscription option's free
      // phase, not introductoryPrice — log both so we can see which store path
      // is delivering the offer.
      final free = sp.defaultOption?.freePhase;
      final optCount = sp.subscriptionOptions?.length ?? 0;
      debugPrint(
        '[Paywall diag] $label: id=${sp.identifier} '
        'price=${sp.priceString} '
        'introductoryPrice=${intro == null ? "null (iOS-only)" : "${intro.priceString} for ${intro.periodNumberOfUnits} ${intro.periodUnit.name}"} '
        'androidFreePhase=${free == null ? "null" : free.billingPeriod?.iso8601 ?? "present"} '
        'subscriptionOptions=$optCount',
      );
    }

    dump('monthly', monthly);
    dump('yearly', yearly);
    final info = ref.read(subscriptionProvider).customerInfo;
    final ent = info?.entitlements.all[RevenueCatConfig.entitlementVoyZaPro];
    debugPrint(
      '[Paywall diag] entitlement: active=${ent?.isActive} '
      'periodType=${ent?.periodType} expires=${ent?.expirationDate}',
    );
  }

  @override
  Widget build(BuildContext context) {
    final subscriptionState = ref.watch(subscriptionProvider);
    final theme = Theme.of(context);
    _logIntroOfferDiagnostic();

    return Stack(
      children: [
        // Ambient rotating globe behind the paywall (same treatment as the
        // home / settings / trip-details surfaces).
        Positioned.fill(
          child: ColoredBox(
            color: Theme.of(context).scaffoldBackgroundColor,
            child: const RotatingGlobeBackground(),
          ),
        ),
        Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            title: const Text('VoyZa Pro'),
            leading: IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
          body: _isLoading || subscriptionState.isLoading
              ? const Center(child: CircularProgressIndicator())
              : SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Hero section
                        _buildHeroSection(context),

                        // Trial-expired value recap — reminds the user what they've
                        // already built so subscribing feels like "keep my work,"
                        // not an abstract upsell. Renders nothing for first-time /
                        // trial-eligible users or when there's nothing to recap.
                        _buildTrialValueRecap(context),

                        // A sign-up referral code that never got redeemed —
                        // the user may not need to pay at all; say so before
                        // showing them prices.
                        _buildPendingCodeBanner(context),
                        const SizedBox(height: 32),

                        // Features list
                        _buildFeaturesList(context),
                        const SizedBox(height: 32),

                        if (_promoExpiresAt == null) ...[
                          // Subscription options
                          _buildSubscriptionOptions(context),
                          const SizedBox(height: 24),

                          // Subscribe button
                          _buildSubscribeButton(context),
                          const SizedBox(height: 12),

                          // Reassurance microcopy — reduces trial-start friction.
                          _buildReassuranceLine(context),
                          const SizedBox(height: 8),
                        ] else
                          // Code redeemed on this visit: the CTA becomes
                          // "use your free month", not "start paying".
                          _buildPromoAppliedCard(context),

                        // Restore purchases button
                        _buildRestoreButton(context),
                        // Manual code entry for everyone else — small, out of
                        // the purchase path.
                        _buildHaveCodeEntry(context),
                        const SizedBox(height: 16),

                        // Terms and privacy
                        _buildLegalLinks(context),

                        // Error message if any
                        if (subscriptionState.errorMessage != null) ...[
                          const SizedBox(height: 16),
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.errorContainer,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              subscriptionState.errorMessage!,
                              style: TextStyle(
                                color: theme.colorScheme.onErrorContainer,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildHeroSection(BuildContext context) {
    final theme = Theme.of(context);
    final hasEligibleTrial = _anyPackageHasEligibleIntroOffer();
    final hasUsedTrialBefore = _anyPackageHasIntroOfferButIneligible();
    final isTrialExpired = widget.trigger == PaywallTrigger.trialExpired;
    final isPlaceLimit = widget.trigger == PaywallTrigger.placeLimit;

    final String headline;
    final String subheadline;
    final IconData heroIcon;
    if (isPlaceLimit) {
      // The user hit the gate mid-flow with a trip in progress — frame the
      // upgrade around continuing what they're building right now.
      headline =
          "You've used all ${SubscriptionLimitService.effectiveAllowanceOf(ref)} free places";
      subheadline = hasEligibleTrial
          ? 'Go unlimited with Pro — try it free for 3 days.'
          : 'Go unlimited with VoyZa Pro to keep building your trip.';
      heroIcon = Icons.add_location_alt_rounded;
    } else if (isTrialExpired || hasUsedTrialBefore) {
      headline = 'Your free trial has ended';
      subheadline = 'Subscribe to keep creating trips and locations.';
      heroIcon = Icons.lock_clock;
    } else if (hasEligibleTrial) {
      headline = 'Try VoyZa Pro free for 3 days';
      subheadline =
          'Then continue with a subscription. Cancel anytime in your store account.';
      heroIcon = Icons.card_giftcard;
    } else {
      headline = 'Upgrade to VoyZa Pro';
      subheadline =
          'Unlock all premium features and take your trip planning to the next level';
      heroIcon = Icons.star_rounded;
    }

    return Column(
      children: [
        Container(
          width: 100,
          height: 100,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                theme.colorScheme.primary,
                theme.colorScheme.secondary,
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(24),
          ),
          child: Icon(
            heroIcon,
            size: 56,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 24),
        Text(
          headline,
          style: theme.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          subheadline,
          style: theme.textTheme.bodyLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  /// On a trial-expired (or trial-already-used) paywall, recap the value the
  /// user has already created so the decision is framed as "keep what you
  /// built," not an abstract upsell. Returns an empty box for first-time /
  /// trial-eligible users, or when there's nothing meaningful to recap.
  Widget _buildTrialValueRecap(BuildContext context) {
    final theme = Theme.of(context);
    final isTrialExpired = widget.trigger == PaywallTrigger.trialExpired;
    final hasUsedTrialBefore = _anyPackageHasIntroOfferButIneligible();
    if (!isTrialExpired && !hasUsedTrialBefore) return const SizedBox.shrink();

    final tripCount = ref.watch(userTripsProvider).asData?.value.length ?? 0;
    final placeCount =
        ref.watch(savedLocationsProvider).asData?.value.length ?? 0;
    if (tripCount == 0 && placeCount == 0) return const SizedBox.shrink();

    final parts = <String>[];
    if (tripCount > 0) {
      parts.add('$tripCount ${tripCount == 1 ? 'trip' : 'trips'}');
    }
    if (placeCount > 0) {
      parts.add('$placeCount ${placeCount == 1 ? 'place' : 'places'}');
    }
    final summary = parts.join(' and ');

    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: theme.colorScheme.primary.withValues(alpha: 0.3),
          ),
        ),
        child: Row(
          children: [
            Icon(Icons.luggage_rounded, color: theme.colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: RichText(
                text: TextSpan(
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurface,
                  ),
                  children: [
                    const TextSpan(text: "You've already planned "),
                    TextSpan(
                      text: summary,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const TextSpan(
                      text: '. Subscribe to keep planning and editing them.',
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The Android (Play new-model) free-trial phase for a package, if present.
  /// Android exposes trials via the default subscription option's `freePhase`,
  /// NOT `introductoryPrice` (which is iOS-only and always null on Android).
  PricingPhase? _androidFreePhase(Package? package) {
    return package?.storeProduct.defaultOption?.freePhase;
  }

  /// True when this device can still claim the free trial for [package].
  /// - iOS: the product has an intro offer AND StoreKit says the user is
  ///   eligible.
  /// - Android: the default subscription option has a free phase. Google
  ///   enforces new-customer eligibility at purchase time, so presence of the
  ///   free phase is the right signal to surface the trial.
  bool _packageHasEligibleTrial(Package? package) {
    if (package == null) return false;
    if (Platform.isAndroid) {
      return _androidFreePhase(package) != null;
    }
    if (package.storeProduct.introductoryPrice == null) return false;
    final eligibility = ref.watch(introEligibilityProvider).asData?.value ??
        const <String, IntroEligibilityStatus>{};
    return isEligibleForIntroOffer(
        eligibility, package.storeProduct.identifier);
  }

  /// True when at least one loaded package has a trial AND the device is
  /// eligible for it.
  bool _anyPackageHasEligibleIntroOffer() {
    final monthly = ref.watch(monthlyPackageProvider).asData?.value;
    final yearly = ref.watch(yearlyPackageProvider).asData?.value;
    return _packageHasEligibleTrial(monthly) ||
        _packageHasEligibleTrial(yearly);
  }

  /// True when at least one loaded package has an intro offer configured but
  /// this device is *ineligible* for all of them — i.e. the user has already
  /// used the trial on this Apple ID / Google account. Used to swap to "trial
  /// has ended" copy so we don't dangle a benefit they can't actually claim.
  bool _anyPackageHasIntroOfferButIneligible() {
    final monthly = ref.watch(monthlyPackageProvider).asData?.value;
    final yearly = ref.watch(yearlyPackageProvider).asData?.value;
    final eligibility = ref.watch(introEligibilityProvider).asData?.value;
    if (eligibility == null) return false;
    bool ineligible(Package? p) {
      if (p == null) return false;
      if (p.storeProduct.introductoryPrice == null) return false;
      return eligibility[p.storeProduct.identifier] ==
          IntroEligibilityStatus.introEligibilityStatusIneligible;
    }

    final monthlyHasOffer = monthly?.storeProduct.introductoryPrice != null;
    final yearlyHasOffer = yearly?.storeProduct.introductoryPrice != null;
    if (!monthlyHasOffer && !yearlyHasOffer) return false;
    final monthlyBlocked = monthlyHasOffer ? ineligible(monthly) : true;
    final yearlyBlocked = yearlyHasOffer ? ineligible(yearly) : true;
    return monthlyBlocked && yearlyBlocked;
  }

  /// Human-readable label for an intro offer, e.g. "3 days free".
  /// Falls back to the store-provided priceString for paid intro offers.
  String _introOfferLabel(IntroductoryPrice intro) {
    final isFree = intro.price == 0;
    final unit = intro.periodUnit;
    final count = intro.periodNumberOfUnits;
    if (!isFree)
      return '${intro.priceString} for ${count > 1 ? '$count ' : ''}${unit.name}${count > 1 ? 's' : ''}';
    final unitLabel = switch (unit) {
      PeriodUnit.day => count == 1 ? 'day' : 'days',
      PeriodUnit.week => count == 1 ? 'week' : 'weeks',
      PeriodUnit.month => count == 1 ? 'month' : 'months',
      PeriodUnit.year => count == 1 ? 'year' : 'years',
      _ => 'days',
    };
    return '$count $unitLabel free';
  }

  /// Human-readable label for an Android free-trial phase, e.g. "3 days free".
  String _androidTrialLabel(PricingPhase free) {
    final period = free.billingPeriod;
    if (period == null) return 'Free trial';
    final count = period.value;
    final unitLabel = switch (period.unit) {
      PeriodUnit.day => count == 1 ? 'day' : 'days',
      PeriodUnit.week => count == 1 ? 'week' : 'weeks',
      PeriodUnit.month => count == 1 ? 'month' : 'months',
      PeriodUnit.year => count == 1 ? 'year' : 'years',
      _ => 'days',
    };
    return '$count $unitLabel free';
  }

  /// Cross-platform "X days free" trial label for a package, or null when the
  /// package has no eligible trial. iOS reads `introductoryPrice`; Android
  /// reads the subscription option's free phase.
  String? _trialLabelFor(Package package) {
    if (!_packageHasEligibleTrial(package)) return null;
    if (Platform.isAndroid) {
      final free = _androidFreePhase(package);
      return free != null ? _androidTrialLabel(free) : null;
    }
    final intro = package.storeProduct.introductoryPrice;
    return intro != null ? _introOfferLabel(intro) : null;
  }

  Widget _buildFeaturesList(BuildContext context) {
    final theme = Theme.of(context);

    // Verified 2026-08-06: the ONLY paid gate in the app is the saved-place
    // allowance (SubscriptionLimitService). Optimization, multi-day
    // itineraries, collaboration, sync — and trip creation itself — are
    // free for everyone, so listing them as Pro was misleading (and an App
    // Store 2.3.1 risk). One honest differentiator, stated plainly.
    final features = [
      (
        'Unlimited saved places',
        Icons.all_inclusive,
        'The free plan includes '
            '${SubscriptionLimitService.freePlaceAllowance} — Pro removes '
            'the cap entirely',
      ),
      (
        'Back an independent travel app',
        Icons.favorite_rounded,
        'Pro keeps VoyZa growing — new features land here first',
      ),
    ];

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Pro Features',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),
          ...features.map((feature) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                        feature.$2,
                        size: 20,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            feature.$1,
                            style: theme.textTheme.bodyLarge,
                          ),
                          Text(
                            feature.$3,
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      Icons.check_circle,
                      size: 20,
                      color: theme.colorScheme.primary,
                    ),
                  ],
                ),
              )),
          const SizedBox(height: 4),
          Text(
            'Route optimization, multi-day itineraries, collaboration and '
            'cross-device sync are free for everyone.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _buildSubscriptionOptions(BuildContext context) {
    final monthlyPackageAsync = ref.watch(monthlyPackageProvider);
    final yearlyPackageAsync = ref.watch(yearlyPackageProvider);

    // Auto-select yearly package if nothing is selected
    yearlyPackageAsync.whenData((package) {
      if (package != null && _selectedPackage == null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _selectedPackage == null) {
            setState(() {
              _selectedPackage = package;
            });
          }
        });
      }
    });

    return Column(
      children: [
        // Yearly option (recommended)
        yearlyPackageAsync.when(
          data: (package) => package != null
              ? _buildPackageCard(
                  context,
                  package: package,
                  isRecommended: true,
                  title: 'Yearly',
                  subtitle: _yearlySavingsLabel(
                      monthlyPackageAsync.asData?.value, package),
                )
              : const SizedBox.shrink(),
          loading: () => _buildLoadingCard(),
          error: (_, __) => const SizedBox.shrink(),
        ),
        const SizedBox(height: 12),

        // Monthly option
        monthlyPackageAsync.when(
          data: (package) => package != null
              ? _buildPackageCard(
                  context,
                  package: package,
                  isRecommended: false,
                  title: 'Monthly',
                  subtitle: 'Flexible billing',
                )
              : const SizedBox.shrink(),
          loading: () => _buildLoadingCard(),
          error: (_, __) => const SizedBox.shrink(),
        ),
      ],
    );
  }

  /// Computes the real annual saving vs paying monthly, from the live store
  /// prices — never hardcoded (which drifts when prices change and risks a
  /// misleading-pricing rejection). Falls back to "Best value" when either
  /// price is unavailable or the annual plan isn't actually cheaper.
  String _yearlySavingsLabel(Package? monthly, Package? yearly) {
    final m = monthly?.storeProduct.price;
    final y = yearly?.storeProduct.price;
    if (m == null || y == null || m <= 0) return 'Best value';
    final annualizedMonthly = m * 12;
    final pct = ((annualizedMonthly - y) / annualizedMonthly * 100).round();
    if (pct <= 0) return 'Best value';
    return 'Best value · Save $pct%';
  }

  /// Per-month equivalent for an annual package (e.g. "Just \$2.92/mo, billed
  /// annually"). Anchors the yearly plan below the monthly plan's headline
  /// price — the strongest lever for annual conversion. Null when it can't be
  /// computed safely.
  String? _perMonthLine(Package package) {
    if (package.packageType != PackageType.annual) return null;
    final price = package.storeProduct.price;
    final code = package.storeProduct.currencyCode;
    if (price <= 0 || code.isEmpty) return null;
    try {
      final perMonth =
          NumberFormat.simpleCurrency(name: code).format(price / 12);
      return 'Just $perMonth/mo, billed annually';
    } catch (_) {
      return null;
    }
  }

  Widget _buildPackageCard(
    BuildContext context, {
    required Package package,
    required bool isRecommended,
    required String title,
    required String subtitle,
  }) {
    final theme = Theme.of(context);
    final priceString = package.storeProduct.priceString;
    final period =
        package.packageType == PackageType.annual ? '/year' : '/month';
    final isSelected = _selectedPackage?.identifier == package.identifier;
    // Cross-platform trial label (iOS introductoryPrice / Android free phase),
    // null when there's no eligible trial — so we never dangle "3 days free"
    // at a user who can't actually claim it.
    final trialLabel = _trialLabelFor(package);
    final effectiveSubtitle =
        trialLabel != null ? '$trialLabel, then $priceString$period' : subtitle;
    final perMonthLine = _perMonthLine(package);

    return GestureDetector(
      onTap: () {
        setState(() {
          _selectedPackage = package;
        });
      },
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isSelected
              ? theme.colorScheme.primaryContainer
              : (isRecommended
                  ? theme.colorScheme.primaryContainer.withValues(alpha: 0.3)
                  // Translucent so the ambient globe shows through.
                  : theme.colorScheme.surfaceContainerHighest
                      .withValues(alpha: 0.55)),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected
                ? theme.colorScheme.primary
                : (isRecommended
                    ? theme.colorScheme.primary.withValues(alpha: 0.5)
                    : theme.colorScheme.outline.withValues(alpha: 0.3)),
            width: isSelected ? 2 : (isRecommended ? 2 : 1),
          ),
        ),
        child: Row(
          children: [
            // Selection indicator
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: isSelected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.outline,
                  width: 2,
                ),
                color:
                    isSelected ? theme.colorScheme.primary : Colors.transparent,
              ),
              child: isSelected
                  ? Icon(
                      Icons.check,
                      size: 16,
                      color: theme.colorScheme.onPrimary,
                    )
                  : null,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (isRecommended) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            'BEST VALUE',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onPrimary,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    effectiveSubtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (perMonthLine != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      perMonthLine,
                      style: theme.textTheme.labelSmall?.copyWith(
                        // Selected card's fill is primaryContainer — primary
                        // text vanished into it (cyan on cyan). Use the
                        // Material pair color on the filled state.
                        color: isSelected
                            ? theme.colorScheme.onPrimaryContainer
                            : theme.colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  priceString,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Text(
                  period,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoadingCard() {
    return Container(
      height: 80,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: const Center(
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    );
  }

  Widget _buildPendingCodeBanner(BuildContext context) {
    final code = _pendingReferralCode;
    if (code == null || _promoExpiresAt != null) {
      return const SizedBox.shrink();
    }
    // Guest with a code saved at sign-up: they CAN buy here (RevenueCat
    // anonymous ids), so before showing them prices, say the free month is
    // one sign-in away. Redemption itself still requires the session — the
    // CTA routes to auth, and main.dart auto-redeems right after sign-in.
    if (!_signedIn) {
      return _pendingBannerShell(
        context,
        title: 'Your free month is waiting',
        body: 'Code $code from your sign-up gives you 30 days of Pro, '
            'free. Sign in to claim it — no need to pay anything today.',
        button: FilledButton.icon(
          onPressed: () => showSignUpRequiredSheet(
            context,
            icon: Icons.redeem_rounded,
            title: 'Sign in to claim your free month',
            message: 'Your referral code $code is saved on this device. '
                'Signing in redeems it automatically — 30 days of Pro, '
                'no payment, no card.',
          ),
          icon: const Icon(Icons.login_rounded, size: 18),
          label: const Text('Sign in to claim it'),
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFFF5A623),
            foregroundColor: Colors.black,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        ),
      );
    }
    return _pendingBannerShell(
      context,
      title: 'Your referral code is ready',
      body: 'Code $code from your sign-up gives you 30 days of Pro, free — '
          'no payment needed.',
      button: FilledButton.icon(
        onPressed: _redeemingCode ? null : () => _applyReferralCode(code),
        icon: _redeemingCode
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.card_giftcard_rounded, size: 18),
        label: Text(_redeemingCode ? 'Applying…' : 'Redeem my 30 free days'),
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xFFF5A623),
          foregroundColor: Colors.black,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
    );
  }

  /// Shared amber shell for both pending-code banners (guest and signed-in)
  /// so the two states can't drift visually.
  Widget _pendingBannerShell(
    BuildContext context, {
    required String title,
    required String body,
    required Widget button,
  }) {
    final theme = Theme.of(context);
    const amber = Color(0xFFF5A623);
    return Container(
      margin: const EdgeInsets.only(top: 20),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: amber.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: amber.withValues(alpha: 0.55)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.redeem_rounded, color: amber, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            body,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          SizedBox(width: double.infinity, child: button),
        ],
      ),
    );
  }

  Widget _buildPromoAppliedCard(BuildContext context) {
    final theme = Theme.of(context);
    const green = Color(0xFF23A55A);
    final until = _promoExpiresAt!;
    final days = until.difference(DateTime.now()).inDays;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: green.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: green.withValues(alpha: 0.55)),
      ),
      child: Column(
        children: [
          const Icon(Icons.check_circle_rounded, color: green, size: 40),
          const SizedBox(height: 10),
          Text(
            'Code applied — Pro is yours, free',
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          Text(
            'Everything is unlocked until '
            '${DateFormat('MMM d, yyyy').format(until)} '
            '(${days <= 0 ? 'today' : '$days days'}). No payment, no card — '
            'nothing starts automatically when it ends.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: FilledButton.styleFrom(
                backgroundColor: green,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
                textStyle: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
              child: const Text('Start exploring'),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Subscribing is always available in Settings. Billing starts '
            'when you subscribe — it does not wait for your free days to '
            'end, so most people enjoy those first.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _buildHaveCodeEntry(BuildContext context) {
    // Signed-in only: redemption is an authenticated server call. Guests
    // already get the code field on the sign-up screen itself.
    if (!_signedIn || _promoExpiresAt != null || _pendingReferralCode != null) {
      return const SizedBox.shrink();
    }
    if (!_showCodeField) {
      return Center(
        child: TextButton.icon(
          onPressed: () => setState(() => _showCodeField = true),
          icon: const Icon(Icons.redeem_rounded, size: 18),
          label: const Text('Have a referral code?'),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _codeController,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Referral code',
                suffixIcon: IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: () => setState(() {
                    _showCodeField = false;
                    _codeController.clear();
                  }),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          FilledButton(
            onPressed: _redeemingCode
                ? null
                : () => _applyReferralCode(_codeController.text),
            child: _redeemingCode
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Apply'),
          ),
        ],
      ),
    );
  }

  Widget _buildSubscribeButton(BuildContext context) {
    final theme = Theme.of(context);
    final selected = _selectedPackage;
    // Only label the CTA "Start free trial" when the device is actually
    // eligible. If they've used the trial before, subscribing charges them
    // immediately — the label needs to reflect that.
    final selectedHasEligibleTrial = _packageHasEligibleTrial(selected);
    final String label;
    if (selected == null) {
      label = 'Select a Plan';
    } else if (selectedHasEligibleTrial) {
      label = 'Start free trial';
    } else {
      final planName =
          selected.packageType == PackageType.annual ? 'Yearly' : 'Monthly';
      label = 'Subscribe to $planName Plan';
    }

    return SizedBox(
      width: double.infinity,
      height: 56,
      child: ElevatedButton(
        onPressed: selected != null ? _purchaseSelectedPackage : null,
        style: ElevatedButton.styleFrom(
          backgroundColor: theme.colorScheme.primary,
          foregroundColor: theme.colorScheme.onPrimary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          elevation: 2,
        ),
        child: Text(
          label,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
            color: theme.colorScheme.onPrimary,
          ),
        ),
      ),
    );
  }

  /// Trust microcopy directly under the CTA. For an eligible trial it makes the
  /// "no charge today" promise explicit (the single biggest trial-start lever);
  /// otherwise it reassures on cancellation.
  Widget _buildReassuranceLine(BuildContext context) {
    final theme = Theme.of(context);
    final hasTrial = _packageHasEligibleTrial(_selectedPackage);
    final text = hasTrial
        ? 'No payment due now · Cancel anytime'
        : 'Cancel anytime · billed through your store account';
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          Icons.lock_outline_rounded,
          size: 14,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildRestoreButton(BuildContext context) {
    return TextButton(
      onPressed: _restorePurchases,
      child: const Text('Restore Purchases'),
    );
  }

  Widget _buildLegalLinks(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        TextButton(
          onPressed: () => _openUrl('https://voyza.xtremon.com/terms'),
          child: Text(
            'Terms of Service',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Text(
          ' | ',
          style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
        ),
        TextButton(
          onPressed: () => _openUrl('https://voyza.xtremon.com/privacy'),
          child: Text(
            'Privacy Policy',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _purchaseSelectedPackage() async {
    if (_selectedPackage == null) return;

    setState(() => _isLoading = true);

    final pkg = _selectedPackage!;
    debugPrint(
      '[Paywall diag] purchasing: id=${pkg.storeProduct.identifier} '
      'introductoryPrice=${pkg.storeProduct.introductoryPrice == null ? "null" : "present"}',
    );

    final success =
        await ref.read(subscriptionProvider.notifier).purchasePackage(pkg);

    final entAfter = ref
        .read(subscriptionProvider)
        .customerInfo
        ?.entitlements
        .all[RevenueCatConfig.entitlementVoyZaPro];
    debugPrint(
      '[Paywall diag] post-purchase: success=$success '
      'entitlement.isActive=${entAfter?.isActive} '
      'periodType=${entAfter?.periodType} '
      'expires=${entAfter?.expirationDate}',
    );

    setState(() => _isLoading = false);

    if (success && mounted) {
      // Funnel analytics: trial start vs paid purchase (feeds ad-platform
      // value events so campaigns can optimize for payers, not installs).
      if (_packageHasEligibleTrial(_selectedPackage)) {
        AnalyticsService.instance.trialStarted(pkg.storeProduct.identifier);
      } else {
        AnalyticsService.instance.purchase(
          pkg.storeProduct.identifier,
          pkg.storeProduct.price,
          pkg.storeProduct.currencyCode,
        );
      }

      // Store email to RevenueCat for authenticated users
      final user = SupabaseService.instance.client.auth.currentUser;
      if (user?.email != null) {
        try {
          await RevenueCatService().setUserAttributes(email: user!.email);
          debugPrint(
              'PaywallScreen: Stored email to RevenueCat after purchase');
        } catch (e) {
          debugPrint('PaywallScreen: Failed to store email to RevenueCat: $e');
        }
      }

      // Log trial start if this is a trial offer (app-side logging, not webhook)
      // Only authenticated users can start trials (webhook skips anonymous for this)
      if (_packageHasEligibleTrial(_selectedPackage) && user != null) {
        try {
          final repo = UserProfileRepository();
          final deviceInfo = DeviceInfoPlugin();
          String deviceId;
          if (Platform.isAndroid) {
            final android = await deviceInfo.androidInfo;
            deviceId = android.id;
          } else if (Platform.isIOS) {
            final ios = await deviceInfo.iosInfo;
            deviceId = ios.identifierForVendor ?? user.id;
          } else {
            deviceId = user.id;
          }
          final productId = _selectedPackage!.storeProduct.identifier;

          await repo.logTrialStart(
            userId: user.id,
            deviceId: deviceId,
            productIdentifier: productId,
          );
          debugPrint('PaywallScreen: ✅ Trial logged to trial_devices table');

          // Sync trial subscription record as fallback for webhook delays
          final trialExpiryStr = entAfter?.expirationDate;
          final trialExpiry =
              trialExpiryStr != null ? DateTime.tryParse(trialExpiryStr) : null;
          final rcOriginalId =
              ref.read(subscriptionProvider).customerInfo?.originalAppUserId;
          await repo.syncTrialSubscription(
            userId: user.id,
            productIdentifier: productId,
            revenueCatAppUserId: rcOriginalId,
            trialExpiresAt: trialExpiry,
          );
          debugPrint(
              'PaywallScreen: ✅ Trial subscription synced for user ${user.id}');
        } catch (e) {
          debugPrint('PaywallScreen: ⚠️ Failed to log trial start: $e');
        }
      }

      // Force a refresh to ensure all providers update
      debugPrint('PaywallScreen: Forcing subscription refresh after purchase');
      await ref.read(subscriptionProvider.notifier).refresh();

      // Invalidate customer info provider to force rebuild
      debugPrint('PaywallScreen: Invalidating customer info provider');
      ref.invalidate(customerInfoProvider);

      // Small delay to ensure state propagates
      await Future.delayed(const Duration(milliseconds: 300));

      debugPrint(
          'PaywallScreen: Current isPro state: ${ref.read(isProProvider)}');

      // Post-purchase referral prompt — the happiest moment, and the
      // reward cost is offset by their payment. Only on a fresh purchase
      // (not restore), and only for signed-in users (anonymous purchasers
      // have no referral code to share). Shown before we pop the paywall.
      if (mounted && SupabaseService.instance.client.auth.currentUser != null) {
        await showReferralAfterPurchase(context, ref);
      }

      if (mounted) Navigator.of(context).pop(true);

      if (mounted) {
        AppToast.success(context, 'Welcome to VoyZa Pro!');
      }
    }
  }

  Future<void> _restorePurchases() async {
    setState(() => _isLoading = true);

    final success =
        await ref.read(subscriptionProvider.notifier).restorePurchases();

    setState(() => _isLoading = false);

    if (mounted) {
      if (success) {
        AppToast.success(context, 'Purchases restored successfully!');
        Navigator.of(context).pop(true);
      } else {
        AppToast.warning(context, 'No purchases found to restore.');
      }
    }
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}

/// Shows the RevenueCat native paywall
/// This uses RevenueCat's built-in paywall UI that you can configure in the dashboard
Future<bool> showRevenueCatPaywall(BuildContext context) async {
  try {
    final paywallResult = await RevenueCatUI.presentPaywallIfNeeded(
      RevenueCatConfig.entitlementVoyZaPro,
    );

    debugPrint('Paywall result: $paywallResult');

    return paywallResult == PaywallResult.purchased ||
        paywallResult == PaywallResult.restored;
  } catch (e) {
    debugPrint('Error showing RevenueCat paywall: $e');
    return false;
  }
}

/// Shows the custom paywall screen.
///
/// Flips [paywallVisibleProvider] for the duration of the route so app-level
/// chrome (the trial banner) can hide while the paywall is up. The try/finally
/// ensures the flag clears on system-back/gesture dismissal too.
Future<bool?> showCustomPaywall(
  BuildContext context, {
  PaywallTrigger trigger = PaywallTrigger.upgradePrompt,
}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  if (container.read(paywallVisibleProvider)) {
    // Already showing — don't stack a second paywall.
    return null;
  }
  container.read(paywallVisibleProvider.notifier).state = true;
  try {
    return await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (context) => PaywallScreen(trigger: trigger),
      ),
    );
  } finally {
    container.read(paywallVisibleProvider.notifier).state = false;
  }
}

/// Helper function to show the appropriate paywall
/// Defaults to custom paywall (preferNative = false to avoid v2 paywall warning)
Future<bool> showPaywall(
  BuildContext context, {
  bool preferNative = false,
  PaywallTrigger trigger = PaywallTrigger.upgradePrompt,
}) async {
  if (preferNative) {
    // Try RevenueCat native paywall first
    final result = await showRevenueCatPaywall(context);
    if (result) return true;

    // If native paywall couldn't be shown (no offering configured), show custom
    return await showCustomPaywall(context, trigger: trigger) ?? false;
  } else {
    return await showCustomPaywall(context, trigger: trigger) ?? false;
  }
}
