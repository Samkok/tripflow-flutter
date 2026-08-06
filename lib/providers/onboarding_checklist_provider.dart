import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/trip.dart';
import '../services/anonymous_user_service.dart';
import '../services/onboarding_service.dart';
import 'auth_provider.dart';

/// The four getting-started steps, in order.
enum ChecklistStep { createTrip, addLocations, activateTrip, optimizeRoute }

/// Spotlight requests that screens fulfil (a superset of the steps:
/// goToMap is the follow-on hint after the first activation, not a step).
enum ChecklistGuide {
  createTrip,
  addLocations,
  activateTrip,
  goToMap,
  optimizeRoute
}

/// Cross-screen guide bus. Set by the checklist (or a flow hook), consumed
/// by the screen that owns the target widget. Offstage IndexedStack tabs
/// must use watch-and-compare, not ref.listen (see riverpod-offstage-listen).
final checklistGuideRequestProvider =
    StateProvider<ChecklistGuide?>((_) => null);

/// Bumped once when the 4th step completes → MainScreen shows the
/// celebration dialog.
final checklistCelebrationTrigger = StateProvider<int>((_) => 0);

class ChecklistState {
  final Set<ChecklistStep> done;
  final bool loaded;
  final bool celebrated;

  /// Highest location count reported for any single trip (badge shows n/3).
  final int locCount;

  const ChecklistState({
    this.done = const {},
    this.loaded = false,
    this.celebrated = false,
    this.locCount = 0,
  });

  bool isDone(ChecklistStep s) => done.contains(s);
  bool get isComplete => done.length == ChecklistStep.values.length;
  double get progress => done.length / ChecklistStep.values.length;

  /// Steps unlock in order: 2 and 3 open once a trip exists; 4 needs an
  /// active trip (its spotlight targets the map sheet, which only renders
  /// with one). A step that's already done never needs its guide.
  bool isEnabled(ChecklistStep s) {
    if (isDone(s)) return false;
    switch (s) {
      case ChecklistStep.createTrip:
        return true;
      case ChecklistStep.addLocations:
      case ChecklistStep.activateTrip:
        return isDone(ChecklistStep.createTrip);
      case ChecklistStep.optimizeRoute:
        return isDone(ChecklistStep.activateTrip);
    }
  }

  ChecklistState copyWith({
    Set<ChecklistStep>? done,
    bool? loaded,
    bool? celebrated,
    int? locCount,
  }) =>
      ChecklistState(
        done: done ?? this.done,
        loaded: loaded ?? this.loaded,
        celebrated: celebrated ?? this.celebrated,
        locCount: locCount ?? this.locCount,
      );
}

class ChecklistNotifier extends StateNotifier<ChecklistState> {
  ChecklistNotifier(this._ref) : super(const ChecklistState()) {
    _load();
  }

  final Ref _ref;
  String? _userId;

  Future<String> _resolveUserId() async =>
      _ref.read(currentUserIdProvider) ?? await AnonymousUserService.id;

  String _key(ChecklistStep s, String uid) => 'checklist_${s.name}_$uid';

  Future<void> _load() async {
    try {
      _userId = await _resolveUserId();
      final prefs = await SharedPreferences.getInstance();
      final done = <ChecklistStep>{
        for (final s in ChecklistStep.values)
          if (prefs.getBool(_key(s, _userId!)) ?? false) s,
      };
      // The checklist teaches the HUMAN, not the account: steps finished on
      // this device as a guest stay finished after signing in. Union the
      // anonymous id's flags so the list never pops back up post-auth.
      final anonId = await AnonymousUserService.id;
      if (anonId != _userId) {
        for (final s in ChecklistStep.values) {
          if (prefs.getBool(_key(s, anonId)) ?? false) {
            if (done.add(s)) {
              await prefs.setBool(_key(s, _userId!), true);
            }
          }
        }
      }
      // First optimize predates the checklist as a milestone — honor it.
      if (!done.contains(ChecklistStep.optimizeRoute) &&
          await OnboardingService.instance
              .hasCelebrated(_userId!, OnboardingMilestone.firstOptimize)) {
        done.add(ChecklistStep.optimizeRoute);
        await prefs.setBool(_key(ChecklistStep.optimizeRoute, _userId!), true);
      }
      // Celebrated-as-guest carries over too — the same person should
      // never be celebrated twice, and a carried-over complete list is
      // silenced rather than re-celebrated.
      var celebrated =
          (prefs.getBool('checklist_celebrated_${_userId!}') ?? false) ||
              (prefs.getBool('checklist_celebrated_$anonId') ?? false);
      if (done.length == ChecklistStep.values.length && !celebrated) {
        celebrated = true;
      }
      if (celebrated) {
        await prefs.setBool('checklist_celebrated_${_userId!}', true);
      }
      if (!mounted) return;
      state = state.copyWith(done: done, loaded: true, celebrated: celebrated);
    } catch (e) {
      debugPrint('ChecklistNotifier: load failed: $e');
      if (mounted) state = state.copyWith(loaded: true);
    }
  }

  /// Idempotent. Persists, and fires the celebration exactly once when the
  /// set becomes complete.
  Future<void> mark(ChecklistStep step) async {
    if (state.isDone(step)) return;
    final done = {...state.done, step};
    state = state.copyWith(done: done);
    try {
      final uid = _userId ?? await _resolveUserId();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_key(step, uid), true);

      if (state.isComplete && !state.celebrated) {
        state = state.copyWith(celebrated: true);
        await prefs.setBool('checklist_celebrated_$uid', true);
        // The checklist celebration REPLACES the generic first-optimize one
        // when they'd land on the same moment — two stacked dialogs is spam.
        await OnboardingService.instance
            .markCelebrated(uid, OnboardingMilestone.firstOptimize);
        _ref.read(checklistCelebrationTrigger.notifier).state++;
      }
    } catch (e) {
      debugPrint('ChecklistNotifier: mark($step) failed: $e');
    }
  }

  /// Derivation from data already on screen — makes the checklist truthful
  /// for users who did steps before the feature existed (or outside the
  /// guided path). Called by trip_screen whenever the trips list loads.
  Future<void> deriveFromTrips(List<Trip> trips) async {
    if (!state.loaded || trips.isEmpty) return;
    await mark(ChecklistStep.createTrip);
    if (trips.any((t) => t.isActive)) {
      await mark(ChecklistStep.activateTrip);
    }
  }

  /// Screens that know a trip's location count report it here (trip details
  /// list, map add-flow). Reaching 3 completes step 2.
  Future<void> reportTripLocationCount(int count) async {
    if (count > state.locCount) {
      state = state.copyWith(locCount: count);
    }
    if (count >= 3) await mark(ChecklistStep.addLocations);
  }
}

final checklistProvider =
    StateNotifierProvider<ChecklistNotifier, ChecklistState>((ref) {
  // Rebuild per identity: guests and each account track their own list.
  ref.watch(currentUserIdProvider);
  return ChecklistNotifier(ref);
});
