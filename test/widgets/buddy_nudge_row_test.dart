import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voyza/providers/auth_provider.dart';
import 'package:voyza/providers/trip_collaborator_provider.dart';
import 'package:voyza/widgets/buddy_nudge_row.dart';

import '../helpers/pump.dart';

const _label = 'Planning with someone? Invite a travel buddy';

Future<({bool Function() tapped})> _pump(
  WidgetTester tester, {
  String? me = 'u1',
  List<Map<String, dynamic>> invites = const [],
  Map<String, Object> prefs = const {},
}) async {
  await useMockPrefs(prefs);
  var tapped = false;
  await pumpVoyza(
    tester,
    BuddyNudgeRow(tripId: 't1', ownerId: 'u1', onInvite: () => tapped = true),
    overrides: [
      currentUserIdProvider.overrideWithValue(me),
      tripCollaboratorsProvider.overrideWith((ref, id) async => []),
      pendingInvitesProvider.overrideWith((ref, id) async => invites),
    ],
  );
  await tester.pumpAndSettle();
  return (tapped: () => tapped);
}

void main() {
  testWidgets('the signed-in owner with nobody invited sees it; tap invites',
      (tester) async {
    final h = await _pump(tester);
    expect(find.text(_label), findsOneWidget);
    await tester.tap(find.text(_label));
    expect(h.tapped(), isTrue);
  });

  testWidgets('dismissing hides it and writes the per-trip flag',
      (tester) async {
    await _pump(tester);
    final prefs = await SharedPreferences.getInstance();
    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pumpAndSettle();
    expect(find.text(_label), findsNothing);
    expect(prefs.getBool(BuddyNudgeRow.prefsKey('t1')), isTrue);
  });

  testWidgets('a remembered dismissal keeps it away', (tester) async {
    await _pump(tester, prefs: {BuddyNudgeRow.prefsKey('t1'): true});
    expect(find.text(_label), findsNothing);
  });

  testWidgets('guests get nothing', (tester) async {
    await _pump(tester, me: null);
    expect(find.text(_label), findsNothing);
  });

  testWidgets('members get nothing', (tester) async {
    await _pump(tester, me: 'someone-else');
    expect(find.text(_label), findsNothing);
  });

  testWidgets('a trip with an invite out gets nothing', (tester) async {
    await _pump(tester, invites: [
      {'email': 'ana@example.com'}
    ]);
    expect(find.text(_label), findsNothing);
  });
}
