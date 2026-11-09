import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyza/providers/auth_provider.dart';
import 'package:voyza/providers/local_active_trip_provider.dart';
import 'package:voyza/providers/onboarding_checklist_provider.dart';

import '../helpers/fakes.dart';
import '../helpers/pump.dart';

Future<ChecklistNotifier> _loaded(ProviderContainer c) async {
  final notifier = c.read(checklistProvider.notifier);
  for (var i = 0; i < 100 && !c.read(checklistProvider).loaded; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(c.read(checklistProvider).loaded, isTrue);
  return notifier;
}

void main() {
  test('a trip on the map counts as step 3 done', () async {
    await useMockPrefs();
    final c = ProviderContainer(overrides: [
      currentUserIdProvider.overrideWithValue('derive-u1'),
      localActiveTripIdProvider
          .overrideWith((ref) => FakeLocalActiveTripNotifier('t1')),
    ]);
    addTearDown(c.dispose);
    final notifier = await _loaded(c);
    await notifier.deriveFromTrips([sampleTrip()]);
    final done = c.read(checklistProvider).done;
    expect(done, contains(ChecklistStep.createTrip));
    expect(done, contains(ChecklistStep.activateTrip));
  });

  test('without a trip on the map only step 1 is derived', () async {
    await useMockPrefs();
    final c = ProviderContainer(overrides: [
      currentUserIdProvider.overrideWithValue('derive-u2'),
      localActiveTripIdProvider
          .overrideWith((ref) => FakeLocalActiveTripNotifier(null)),
    ]);
    addTearDown(c.dispose);
    final notifier = await _loaded(c);
    await notifier.deriveFromTrips([sampleTrip()]);
    final done = c.read(checklistProvider).done;
    expect(done, contains(ChecklistStep.createTrip));
    expect(done, isNot(contains(ChecklistStep.activateTrip)));
  });
}
