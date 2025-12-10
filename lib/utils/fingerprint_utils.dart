import 'dart:convert';
import 'package:crypto/crypto.dart';

class FingerprintUtils {
  static String generateFingerprint({
    required String name,
    required double lat,
    required double lng,
  }) {
    final data = '$name$lat$lng';
    final bytes = utf8.encode(data);
    final digest = sha256.convert(bytes);
    return digest.toString();
  }
}
