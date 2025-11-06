import 'package:flutter/material.dart';

class TermsScreen extends StatelessWidget {
  const TermsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Terms & Conditions'),
        backgroundColor: Theme.of(context).colorScheme.surface,
        elevation: 1,
      ),
      body: SingleChildScrollView(
        padding: EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSection(
              context,
              '1. Introduction',
              'Welcome to TripFlow ("the App"). These Terms and Conditions govern your use of our application and services. By downloading, accessing, or using the App, you agree to be bound by these terms. If you do not agree to these terms, please do not use the App.',
            ),
            _buildSection(
              context,
              '2. Description of Service',
              'TripFlow is a trip planning and route optimization tool. The App allows you to search for locations, pin them to a trip plan, and generate an optimized travel route. Key features include map interaction, location management, and route visualization.',
            ),
            _buildSection(
              context,
              '3. Use of Third-Party Services',
              'The App utilizes services from Google, including Google Maps, Google Places API, and Google Directions API, to provide map data, place information, and routing. Your use of these features is also subject to Google\'s Terms of Service and Google Maps/Google Earth Additional Terms of Service.',
            ),
            _buildSection(
              context,
              '4. Location Data',
              'To provide core functionalities, such as route optimization from your current position, the App requires access to your device\'s location data. By using the App, you consent to us accessing this data. Your location data is used solely for the purpose of providing and improving the service and is not stored or shared with third parties, other than as required by the mapping services (e.g., Google) to generate routes.',
            ),
            _buildSection(
              context,
              '5. User-Generated Content',
              'Any locations you pin, trips you create, or routes you generate ("User Content") are stored locally on your device using its internal storage. We do not have access to, nor do we collect, your User Content. You are solely responsible for backing up and managing your data.',
            ),
            _buildSection(
              context,
              '6. Disclaimer of Warranties',
              'The App and its services are provided "as is" and "as available" without any warranties of any kind. We do not warrant that the App will be error-free or uninterrupted. All travel information, including but not limited to maps, routes, travel times, and distances, is provided by third-party services and may contain inaccuracies. You should always exercise your own judgment, be aware of your surroundings, and verify all information before relying on it for navigation or travel. We are not responsible for any damages or losses resulting from your reliance on this information.',
            ),
            _buildSection(
              context,
              '7. Limitation of Liability',
              'To the fullest extent permitted by applicable law, in no event shall the creators of TripFlow be liable for any indirect, incidental, special, consequential, or punitive damages, or any loss of profits or revenues, whether incurred directly or indirectly, or any loss of data, use, goodwill, or other intangible losses, resulting from (a) your access to or use of or inability to access or use the App; (b) any conduct or content of any third party on the App; or (c) unauthorized access, use, or alteration of your transmissions or content.',
            ),
            _buildSection(
              context,
              '8. Intellectual Property',
              'All rights, title, and interest in and to the App (excluding content provided by third parties) are and will remain the exclusive property of its creators. The App is protected by copyright and other laws. Nothing in these Terms gives you a right to use the TripFlow name or any of the TripFlow trademarks, logos, domain names, and other distinctive brand features.',
            ),
            _buildSection(
              context,
              '9. Changes to Terms',
              'We may revise these Terms and Conditions from time to time. We will notify you of any changes by posting the new Terms and Conditions on this page. You are advised to review this page periodically for any changes. Changes to these Terms are effective when they are posted on this page.',
            ),
            _buildSection(
              context,
              '10. Contact Us',
              'If you have any questions about these Terms and Conditions, you can contact us at [Your Contact Email].',
            ),
            const SizedBox(height: 24),
            const Text(
              'Last updated: [Date]',
              style: TextStyle(fontStyle: FontStyle.italic, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSection(BuildContext context, String title, String content) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            content,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  height: 1.5, // Improved line spacing for readability
                ),
          ),
        ],
      ),
    );
  }
}