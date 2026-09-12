import 'package:flutter_test/flutter_test.dart';
import 'package:voyza/utils/search_text.dart';

void main() {
  group('normalizeSearchText', () {
    test('strips Vietnamese diacritics and đ', () {
      expect(normalizeSearchText('Chợ Bến Thành'), 'cho ben thanh');
      expect(normalizeSearchText('Phở Hòa Pasteur'), 'pho hoa pasteur');
      expect(normalizeSearchText('Đà Nẵng'), 'da nang');
      expect(normalizeSearchText('Hội An'), 'hoi an');
      expect(normalizeSearchText('Huế'), 'hue');
      expect(normalizeSearchText('Vũng Tàu'), 'vung tau');
      expect(normalizeSearchText('Cần Thơ'), 'can tho');
      expect(normalizeSearchText('Mường Thanh'), 'muong thanh');
    });

    test('strips Western European diacritics and ligatures', () {
      expect(normalizeSearchText('Café de Flore'), 'cafe de flore');
      expect(normalizeSearchText('São Paulo'), 'sao paulo');
      expect(normalizeSearchText('Straße'), 'strasse');
      expect(normalizeSearchText('Œuvre'), 'oeuvre');
      expect(normalizeSearchText('Łódź'), 'lodz');
      expect(normalizeSearchText('İstanbul'), 'istanbul');
    });

    test('folds punctuation into word breaks and collapses whitespace', () {
      expect(normalizeSearchText('Pho-Hoa  (Pasteur)'), 'pho hoa pasteur');
      expect(normalizeSearchText("St. Paul's"), 'st paul s');
    });

    test('leaves non-Latin scripts untouched', () {
      expect(normalizeSearchText('東京タワー'), '東京タワー');
      expect(normalizeSearchText('ភ្នំពេញ'), 'ភ្នំពេញ');
    });
  });

  group('matchesSearchQuery', () {
    test('empty query matches everything', () {
      expect(matchesSearchQuery('Chợ Bến Thành', ''), isTrue);
      expect(matchesSearchQuery('Chợ Bến Thành', '   '), isTrue);
    });

    test('accent-free typing finds accented names', () {
      expect(matchesSearchQuery('Chợ Bến Thành', 'ben thanh'), isTrue);
      expect(matchesSearchQuery('Chợ Bến Thành', 'Ben'), isTrue);
      expect(matchesSearchQuery('Chợ Bến Thành', 'cho ben'), isTrue);
      expect(matchesSearchQuery('Phở Hòa Pasteur', 'pho hoa'), isTrue);
    });

    test('accented typing still matches', () {
      expect(matchesSearchQuery('Chợ Bến Thành', 'Bến Thành'), isTrue);
      expect(matchesSearchQuery('Chợ Bến Thành', 'chợ'), isTrue);
    });

    test('word order does not matter, but every word must appear', () {
      expect(matchesSearchQuery('Chợ Bến Thành', 'thanh ben'), isTrue);
      expect(matchesSearchQuery('Chợ Bến Thành', 'thanh market'), isFalse);
      expect(matchesSearchQuery('Chợ Bến Thành', 'xyz'), isFalse);
    });

    test('plain ASCII behaves like a case-insensitive contains', () {
      expect(matchesSearchQuery('Tokyo Tower', 'tower'), isTrue);
      expect(matchesSearchQuery('Tokyo Tower', 'TOKYO'), isTrue);
      expect(matchesSearchQuery('Tokyo Tower', 'kyo to'), isTrue);
      expect(matchesSearchQuery('Tokyo Tower', 'osaka'), isFalse);
    });
  });
}
