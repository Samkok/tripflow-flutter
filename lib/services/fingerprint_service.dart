import 'package:crypto/crypto.dart';
import 'dart:convert';

class FingerprintService {
  /// Generate SHA256 fingerprint from location data: sha256(name+lat+lng)
  static String generateFingerprint(String name, double lat, double lng) {
    final data = '$name${lat.toStringAsFixed(6)}${lng.toStringAsFixed(6)}';
    return sha256.convert(utf8.encode(data)).toString();
  }

  /// Verify if two locations have the same fingerprint
  static bool isSameLocation(
    String name1,
    double lat1,
    double lng1,
    String name2,
    double lat2,
    double lng2,
  ) {
    final fp1 = generateFingerprint(name1, lat1, lng1);
    final fp2 = generateFingerprint(name2, lat2, lng2);
    return fp1 == fp2;
  }
}
