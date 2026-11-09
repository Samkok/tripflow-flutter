import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voyza/models/trip.dart';
import 'package:voyza/providers/auth_provider.dart';
import 'package:voyza/providers/user_trip_provider.dart';
import 'package:voyza/widgets/save_trips_account_card.dart';

import '../helpers/fakes.dart';
import '../helpers/pump.dart';

const _title = 'Save your trips with an account';

Future<void> _pump(
  WidgetTester tester, {
  String? me,
  List<Trip>? trips,
  Map<String, Object> prefs = const {},
}) async {
  await useMockPrefs(prefs);
  await pumpVoyza(
    tester,
    const SaveTripsAccountCard(),
    overrides: [
      currentUserIdProvider.overrideWithValue(me),
      userTripsProvider
          .overrideWith((ref) async => trips ?? [sampleTrip(id: 'a')]),
    ],
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a guest with a trip sees it, with both ways in', (tester) async {
    await _pump(tester);
    expect(find.text(_title), findsOneWidget);
    expect(find.text('Create account'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
  });

  testWidgets('dismissing hides it for good', (tester) async {
    await _pump(tester);
    final prefs = await SharedPreferences.getInstance();
    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pumpAndSettle();
    expect(find.text(_title), findsNothing);
    expect(prefs.getBool(SaveTripsAccountCard.prefsKey), isTrue);
  });

  testWidgets('a remembered dismissal keeps it away', (tester) async {
    await _pump(tester, prefs: {SaveTripsAccountCard.prefsKey: true});
    expect(find.text(_title), findsNothing);
  });

  testWidgets('signed-in users never see it', (tester) async {
    await _pump(tester, me: 'u1');
    expect(find.text(_title), findsNothing);
  });

  testWidgets('a guest with no trip yet sees nothing', (tester) async {
    await _pump(tester, trips: const []);
    expect(find.text(_title), findsNothing);
  });
}
