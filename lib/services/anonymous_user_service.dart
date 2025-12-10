import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class AnonymousUserService {
  static const String _keyAnonymousUserId = 'anonymous_user_id';
  static String? _cachedId;

  static Future<String> get id async {
    if (_cachedId != null) return _cachedId!;

    final prefs = await SharedPreferences.getInstance();
    String? storedId = prefs.getString(_keyAnonymousUserId);

    if (storedId == null) {
      storedId = const Uuid().v4();
      await prefs.setString(_keyAnonymousUserId, storedId);
    }

    _cachedId = storedId;
    return storedId;
  }
}
