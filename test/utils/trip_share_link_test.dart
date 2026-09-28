import 'package:flutter_test/flutter_test.dart';
import 'package:voyza/utils/trip_share_link.dart';

void main() {
  group('normalizeTripShareCode', () {
    test('accepts the code as people and links write it', () {
      expect(normalizeTripShareCode('AB12CD'), 'AB12CD');
      expect(normalizeTripShareCode('TRIP-AB12CD'), 'AB12CD');
      expect(normalizeTripShareCode('trip-ab12cd'), 'AB12CD');
      expect(normalizeTripShareCode('  ab12cd \n'), 'AB12CD');
    });

    test('rejects anything that is not a six-character code', () {
      expect(normalizeTripShareCode(null), isNull);
      expect(normalizeTripShareCode(''), isNull);
      expect(normalizeTripShareCode('AB12C'), isNull);
      expect(normalizeTripShareCode('AB12CDE'), isNull);
      expect(normalizeTripShareCode('AB 2CD'), isNull);
      expect(normalizeTripShareCode('AB-2CD'), isNull);
      expect(normalizeTripShareCode('TRIP-'), isNull);
      expect(normalizeTripShareCode('../../x'), isNull);
    });
  });

  group('tripShareLink', () {
    test('builds the web address from either form of the code', () {
      expect(tripShareLink('AB12CD'), 'https://voyza.xtremon.com/c/AB12CD');
      expect(
          tripShareLink('trip-ab12cd'), 'https://voyza.xtremon.com/c/AB12CD');
      expect(tripShareLink(null), isNull);
      expect(tripShareLink('nope'), isNull);
    });

    test('round-trips through the parser', () {
      final link = tripShareLink('K7QM2X')!;
      expect(tripShareCodeFromUri(Uri.parse(link)), 'K7QM2X');
    });
  });

  group('tripShareCodeFromUri', () {
    String? code(String link) => tripShareCodeFromUri(Uri.parse(link));

    test('reads the web link', () {
      expect(code('https://voyza.xtremon.com/c/AB12CD'), 'AB12CD');
      expect(code('https://voyza.xtremon.com/c/AB12CD/'), 'AB12CD');
      expect(code('https://voyza.xtremon.com/c/ab12cd'), 'AB12CD');
      expect(code('https://VOYZA.xtremon.com/C/AB12CD'), 'AB12CD');
      expect(code('https://www.voyza.xtremon.com/c/AB12CD'), 'AB12CD');
      expect(code('https://voyza.xtremon.com/c/TRIP-AB12CD'), 'AB12CD');
      // Tracking parameters a messenger appends change nothing.
      expect(code('https://voyza.xtremon.com/c/AB12CD?utm_source=x'), 'AB12CD');
    });

    test('reads the app link the web page hands over', () {
      expect(code('voyza://copy/AB12CD'), 'AB12CD');
      expect(code('voyza://copy/trip-ab12cd'), 'AB12CD');
      expect(code('VOYZA://COPY/AB12CD'), 'AB12CD');
    });

    test('leaves every other link alone', () {
      // Sign-in callbacks belong to supabase_flutter.
      expect(code('voyza://reset-password#access_token=abc'), isNull);
      expect(code('voyza://reset-password?code=AB12CD'), isNull);
      // A code in the query is never ours — it would read as a sign-in.
      expect(code('voyza://copy?code=AB12CD'), isNull);
      expect(code('https://voyza.xtremon.com/c?code=AB12CD'), isNull);
      // Other pages of the site.
      expect(code('https://voyza.xtremon.com/r/VOYZA-ABC123'), isNull);
      expect(code('https://voyza.xtremon.com/t/AB12CD'), isNull);
      expect(code('https://voyza.xtremon.com/'), isNull);
      expect(code('https://voyza.xtremon.com/c/'), isNull);
      expect(code('https://voyza.xtremon.com/c/AB12CD/extra'), isNull);
      // Look-alike hosts.
      expect(code('https://voyza.xtremon.com.evil.example/c/AB12CD'), isNull);
      expect(code('https://evil.example/c/AB12CD'), isNull);
      expect(code('voyza://other/AB12CD'), isNull);
      // Bad codes.
      expect(code('voyza://copy/AB12C'), isNull);
      expect(code('https://voyza.xtremon.com/c/AB12CDE'), isNull);
    });
  });

  group('tripShareMessage', () {
    test('carries the trip name, the link and the typed code', () {
      final text =
          tripShareMessage(tripName: 'Tokyo 2026', shareCode: 'ab12cd');
      expect(text, contains('"Tokyo 2026"'));
      expect(text, contains('https://voyza.xtremon.com/c/AB12CD'));
      expect(text, contains('TRIP-AB12CD'));
      // The link stands on its own line so messengers make it tappable.
      expect(text.split('\n'), contains('https://voyza.xtremon.com/c/AB12CD'));
    });

    test('reads naturally without a trip name', () {
      final text = tripShareMessage(tripName: '  ', shareCode: 'AB12CD');
      expect(text, startsWith('Take my trip on VoyZa'));
      expect(text, isNot(contains('""')));
    });
  });
}
