import 'package:dio/dio.dart';
import 'api_service.dart';

class PhotoService {
  // Convert photo reference to fetchable URL
  static String getPhotoUrl({
    required String photoReference,
    int maxWidth = 400,
  }) {
    return 'https://maps.googleapis.com/maps/api/place/photo'
        '?photoreference=$photoReference'
        '&maxwidth=$maxWidth'
        '&key=${ApiService.googlePlacesApiKey}';
  }

  // Batch preload multiple photo URLs
  static Future<Map<String, String>> preloadPhotoUrls(
    List<String> photoReferences,
  ) async {
    final results = <String, String>{};

    await Future.wait(photoReferences.map((ref) async {
      try {
        final url = getPhotoUrl(photoReference: ref);
        // Make HEAD request to get redirected URL
        final response = await ApiService.dio.head(
          url,
          options: Options(
            followRedirects: true,
            maxRedirects: 5,
            validateStatus: (status) => status != null && status < 400,
          ),
        );
        results[ref] = response.realUri.toString();
      } catch (e) {
        print('Error preloading photo $ref: $e');
      }
    }));

    return results;
  }
}
