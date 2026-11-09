import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyza/providers/auth_provider.dart';
import 'package:voyza/providers/connectivity_provider.dart';
import 'package:voyza/providers/trip_collaborator_provider.dart';
import 'package:voyza/providers/trip_listener_provider.dart';

import '../helpers/fakes.dart';

class _Net extends StateNotifier<ConnectivityStatus>
    implements ConnectivityNotifier {
  _Net() : super(ConnectivityStatus.isConnected);
  void set(ConnectivityStatus s) => state = s;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The server's answers for one trip, in order; a `null` entry throws.
class _Server {
  _Server(this.answers);
  final List<bool?> answers;
  int calls = 0;
  Future<bool> ask() async {
    final a = answers[calls < answers.length ? calls : answers.length - 1];
    calls++;
    if (a == null) throw StateError('offline');
    return a;
  }
}

ProviderContainer _container({
  required String tripId,
  required String ownerId,
  required _Server server,
  required _Net net,
}) {
  final trip = sampleTrip(id: tripId, userId: ownerId);
  final c = ProviderContainer(overrides: [
    realtimeActiveTripProvider.overrideWith((ref) => Stream.value(trip)),
    currentUserIdProvider.overrideWithValue('u1'),
    connectivityProvider.overrideWith((ref) => net),
    hasWriteAccessProvider.overrideWith((ref, id) => server.ask()),
  ]);
  addTearDown(c.dispose);
  return c;
}

Future<bool> _answer(ProviderContainer c) async {
  // Keep the provider alive while the test looks at it.
  final sub = c.listen(hasActiveTripWriteAccessProvider, (_, __) {});
  addTearDown(sub.close);
  // The first build runs before the trip stream has delivered (that build
  // answers "deny" defensively, as before); wait for the trip, then for
  // the rebuild it causes.
  await c.read(realtimeActiveTripProvider.future);
  await Future<void>.delayed(Duration.zero);
  return c.read(hasActiveTripWriteAccessProvider.future);
}

void main() {
  test('a failed check on an owned trip keeps the owner writing', () async {
    final server = _Server([null, false]);
    final net = _Net();
    final c =
        _container(tripId: 'owned-a', ownerId: 'u1', server: server, net: net);
    expect(await _answer(c), isTrue, reason: 'ownership is provable locally');

    // The network comes back: the real answer replaces the fallback.
    net.set(ConnectivityStatus.isDisconnected);
    net.set(ConnectivityStatus.isConnected);
    await Future<void>.delayed(Duration.zero);
    expect(await c.read(hasActiveTripWriteAccessProvider.future), isFalse);
    expect(server.calls, 2);
  });

  test('a failed check on a trip shared with me denies until it succeeds',
      () async {
    final server = _Server([null, true]);
    final net = _Net();
    final c = _container(
        tripId: 'shared-b', ownerId: 'someone-else', server: server, net: net);
    expect(await _answer(c), isFalse, reason: 'nothing proves write access');

    net.set(ConnectivityStatus.isDisconnected);
    net.set(ConnectivityStatus.isConnected);
    await Future<void>.delayed(Duration.zero);
    expect(await c.read(hasActiveTripWriteAccessProvider.future), isTrue);
  });

  test('a later failure keeps the last real answer for that trip', () async {
    final server = _Server([true, null]);
    final net = _Net();
    final c = _container(
        tripId: 'shared-c', ownerId: 'someone-else', server: server, net: net);
    expect(await _answer(c), isTrue);

    c.invalidate(hasWriteAccessProvider('shared-c'));
    await Future<void>.delayed(Duration.zero);
    expect(await c.read(hasActiveTripWriteAccessProvider.future), isTrue,
        reason: 'the failed re-check is unknown, not a denial');
    expect(server.calls, 2);
  });

  test('no trip on the map means my own places are mine to edit', () async {
    final net = _Net();
    final c = ProviderContainer(overrides: [
      realtimeActiveTripProvider.overrideWith((ref) => Stream.value(null)),
      currentUserIdProvider.overrideWithValue('u1'),
      connectivityProvider.overrideWith((ref) => net),
    ]);
    addTearDown(c.dispose);
    expect(await _answer(c), isTrue);
  });
}
