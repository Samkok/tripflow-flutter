/// Links that hand a trip to someone else: the same copy-by-code flow, with
/// a tap instead of typing.
///
/// * `https://voyza.xtremon.com/c/<CODE>` is what gets shared — an ordinary
///   web address, so every messenger makes it tappable. The page behind it
///   offers "Open in VoyZa" and the store buttons, and shows the code for
///   anyone who would rather type it.
/// * `voyza://copy/<CODE>` is what that page hands to the installed app.
///
/// The code travels in the PATH, never in a `?code=` query: supabase_flutter
/// reads any incoming link carrying a `code` parameter as a sign-in callback
/// and would try to exchange it for a session.
library;

/// Shared links start with this; the bare share code follows.
const String tripShareLinkBase = 'https://voyza.xtremon.com/c/';

const String _appScheme = 'voyza';
const String _appHost = 'copy';
const Set<String> _webHosts = {'voyza.xtremon.com', 'www.voyza.xtremon.com'};
const String _webPath = 'c';

final RegExp _bareCode = RegExp(r'^[A-Z0-9]{6}$');
final RegExp _codePrefix = RegExp(r'^TRIP-', caseSensitive: false);

/// The bare six-character code from what a person or a link supplied:
/// `TRIP-ab12cd`, ` AB12CD ` → `AB12CD`. Null when it is not a share code.
/// Shape only — whether the code is live is the server's answer.
String? normalizeTripShareCode(String? raw) {
  if (raw == null) return null;
  final code = raw.trim().replaceFirst(_codePrefix, '').toUpperCase();
  return _bareCode.hasMatch(code) ? code : null;
}

/// The address to send for a trip with [shareCode], or null when the code
/// is not one.
String? tripShareLink(String? shareCode) {
  final code = normalizeTripShareCode(shareCode);
  return code == null ? null : '$tripShareLinkBase$code';
}

/// The share code inside an incoming link, or null when the link is not a
/// trip link (sign-in callbacks, referral links, anything else).
String? tripShareCodeFromUri(Uri uri) {
  final scheme = uri.scheme.toLowerCase();
  final host = uri.host.toLowerCase();
  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();

  if (scheme == _appScheme && host == _appHost) {
    return segments.length == 1
        ? normalizeTripShareCode(segments.single)
        : null;
  }
  if ((scheme == 'https' || scheme == 'http') && _webHosts.contains(host)) {
    if (segments.length == 2 && segments.first.toLowerCase() == _webPath) {
      return normalizeTripShareCode(segments.last);
    }
  }
  return null;
}

/// What the share sheet sends: one sentence, the link, and the code for
/// anyone who prefers to type it.
String tripShareMessage({required String tripName, required String shareCode}) {
  final code = normalizeTripShareCode(shareCode) ?? shareCode;
  final name = tripName.trim();
  final subject = name.isEmpty ? 'my trip' : 'my trip "$name"';
  return 'Take $subject on VoyZa and make it yours — every day and place '
      'comes with it:\n'
      '$tripShareLinkBase$code\n\n'
      'Or enter the code TRIP-$code in the app.';
}
