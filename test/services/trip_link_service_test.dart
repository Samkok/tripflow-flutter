import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:voyza/services/trip_link_service.dart';

/// The service over a hand-fed link stream; the handler records what it was
/// asked to open and answers [signedIn].
class _Harness {
  final links = StreamController<Uri>();
  final opened = <String>[];
  final asked = <String>[];
  bool signedIn = true;

  late final TripLinkService svc = TripLinkService(links: links.stream);

  void start() => svc.start(onCopyTrip: (code) {
        asked.add(code);
        if (!signedIn) return false;
        opened.add(code);
        return true;
      });

  Future<void> tap(String link) async {
    links.add(Uri.parse(link));
    await Future<void>.delayed(Duration.zero);
  }

  Future<void> close() async {
    await svc.dispose();
    await links.close();
  }
}

void main() {
  const web = 'https://voyza.xtremon.com/c/AB12CD';
  const app = 'voyza://copy/K7QM2X';

  test('a link that launched the app waits for the home screen', () async {
    final h = _Harness()..start();
    await h.tap(web);
    expect(h.asked, isEmpty, reason: 'only the splash is up');
    expect(h.svc.pendingCode, 'AB12CD');

    h.svc.homeScreenMounted();
    expect(h.opened, ['AB12CD']);
    expect(h.svc.pendingCode, isNull);

    // Opened once: a later rebuild of the home screen changes nothing.
    h.svc.retryPending();
    expect(h.opened, ['AB12CD']);
    await h.close();
  });

  test('a link tapped while the app is open is handled at once', () async {
    final h = _Harness()..start();
    h.svc.homeScreenMounted();
    await h.tap(app);
    expect(h.opened, ['K7QM2X']);
    await h.close();
  });

  test('a link that arrives before the app is listening is not lost', () async {
    final h = _Harness();
    h.svc.homeScreenMounted();
    h.svc.handleLink(Uri.parse(web));
    expect(h.svc.pendingCode, 'AB12CD', reason: 'no handler yet');
    h.start();
    expect(h.opened, ['AB12CD']);
    await h.close();
  });

  test('signed out: the code is kept and opens after sign-in', () async {
    final h = _Harness()
      ..signedIn = false
      ..start();
    h.svc.homeScreenMounted();
    await h.tap(web);
    expect(h.asked, ['AB12CD']);
    expect(h.opened, isEmpty);
    expect(h.svc.pendingCode, 'AB12CD');

    h.signedIn = true;
    h.svc.retryPending();
    expect(h.opened, ['AB12CD']);
    expect(h.svc.pendingCode, isNull);
    await h.close();
  });

  test('signing in swaps home screens without losing readiness', () async {
    final h = _Harness()
      ..signedIn = false
      ..start();
    h.svc.homeScreenMounted(); // the guest's home screen
    await h.tap(web);
    expect(h.opened, isEmpty);

    // The signed-in home screen mounts BEFORE the old one is disposed.
    h.signedIn = true;
    h.svc.homeScreenMounted();
    expect(h.opened, ['AB12CD']);
    h.svc.homeScreenDisposed();

    await h.tap(app);
    expect(h.opened, ['AB12CD', 'K7QM2X'],
        reason: 'one home screen is still mounted');
    await h.close();
  });

  test('with no home screen left, links wait again', () async {
    final h = _Harness()..start();
    h.svc.homeScreenMounted();
    h.svc.homeScreenDisposed();
    h.svc.homeScreenDisposed(); // an extra dispose never goes negative
    await h.tap(web);
    expect(h.opened, isEmpty);
    h.svc.homeScreenMounted();
    expect(h.opened, ['AB12CD']);
    await h.close();
  });

  test('the newest link wins while waiting', () async {
    final h = _Harness()..start();
    await h.tap(web);
    await h.tap(app);
    h.svc.homeScreenMounted();
    expect(h.opened, ['K7QM2X']);
    await h.close();
  });

  test('remembers that a trip link arrived, and only a trip link', () async {
    final h = _Harness()..start();
    await h.tap('voyza://reset-password#access_token=abc');
    expect(h.svc.linkSeen, isFalse);
    await h.tap(web);
    expect(h.svc.linkSeen, isTrue);
    h.svc.homeScreenMounted();
    expect(h.svc.linkSeen, isTrue, reason: 'still true once opened');
    await h.close();
  });

  test('links that are not trip links are ignored', () async {
    final h = _Harness()..start();
    h.svc.homeScreenMounted();
    await h.tap('voyza://reset-password#access_token=abc');
    await h.tap('voyza://copy?code=AB12CD');
    await h.tap('https://voyza.xtremon.com/r/VOYZA-ABC123');
    await h.tap('https://example.com/c/AB12CD');
    expect(h.asked, isEmpty);
    expect(h.svc.pendingCode, isNull);
    await h.close();
  });
}
