import 'package:flutter_test/flutter_test.dart';
import 'package:voyza/models/location_model.dart';
import 'package:voyza/models/saved_location.dart';

SavedLocation _row({String? floor}) => SavedLocation(
      id: 'row-1',
      userId: 'user-1',
      name: 'Ying Kee Restaurant',
      lat: 22.28,
      lng: 114.17,
      createdAt: DateTime(2026, 10, 12),
      fingerprint: 'fp',
      floor: floor,
    );

void main() {
  group('SavedLocation.floor', () {
    test('round-trips through the server shape', () {
      final json = _row(floor: '23/F · Shop 2301').toJson();
      expect(json['floor'], '23/F · Shop 2301');
      final back = SavedLocation.fromJson({
        ...json,
        'created_at': DateTime(2026, 10, 12).toIso8601String(),
      });
      expect(back.floor, '23/F · Shop 2301');
    });

    test('absent on the server reads as unknown, empty as none', () {
      final base = _row().toJson()
        ..['created_at'] = DateTime(2026, 10, 12).toIso8601String();
      expect(SavedLocation.fromJson({...base}..remove('floor')).floor, isNull);
      expect(SavedLocation.fromJson({...base, 'floor': ''}).floor, '');
    });

    test('copyWith keeps or replaces it, and the model carries it', () {
      final row = _row(floor: 'G/F');
      expect(row.copyWith(name: 'x').floor, 'G/F');
      expect(row.copyWith(floor: 'Floor 2').floor, 'Floor 2');
      expect(row.toLocationModel().floor, 'G/F');
      expect(row.toLocationModel().copyWith(floor: '1/F').floor, '1/F');
    });

    test('a change of floor changes the content signature', () {
      expect(_row(floor: 'G/F').contentSignature(),
          isNot(_row(floor: '1/F').contentSignature()));
    });
  });
}
