import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Pending ISO-3166-1 alpha-2 country code for the trip create form.
///
/// Set by onboarding's "Plan my first trip" CTA before it pops; TripScreen
/// (alive in MainScreen's IndexedStack) listens, opens the create form with
/// the country pre-selected, then resets this to null.
final tripFormPrefillProvider = StateProvider<String?>((_) => null);

/// Trigger counter for "create the sample trip" requests from onboarding.
/// Same increment-to-signal pattern as [zoomToFitRouteTrigger]; TripScreen
/// listens and runs its existing sample-trip flow on each bump.
final sampleTripRequestProvider = StateProvider<int>((_) => 0);

/// One-shot request to switch MainScreen's bottom tab (0 = Trips, 1 = Map,
/// 2 = Settings). Set by flows that should land the user on a specific tab
/// (e.g. activating a trip → Map); MainScreen listens, switches, and resets
/// to null.
final mainTabRequestProvider = StateProvider<int?>((_) => null);

/// The CURRENTLY selected MainScreen tab. IndexedStack builds all children
/// offstage, so MapScreen can't infer its own visibility — MainScreen feeds
/// this from every place _selectedIndex changes (tap, tab request, initial
/// anonymous map-first default).
final selectedTabIndexProvider = StateProvider<int>((_) => 0);

/// Bump-to-recheck signal for the one-time map spotlight tour. Needed
/// because the anonymous user is ALREADY on the map tab when the onboarding
/// route pops — no tab event fires, so MainScreen bumps this right after
/// maybeShowOnboarding returns.
final mapTutorialRecheckProvider = StateProvider<int>((_) => 0);
