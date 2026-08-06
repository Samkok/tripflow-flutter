import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:voyza/widgets/rotating_globe_background.dart';

class TermsScreen extends StatelessWidget {
  const TermsScreen({super.key});

  static const _privacyPolicyUrl = 'https://voyza.xtremon.com/privacy';

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Ambient rotating globe behind the page (app-wide treatment).
        Positioned.fill(
          child: ColoredBox(
            color: Theme.of(context).scaffoldBackgroundColor,
            child: const RotatingGlobeBackground(),
          ),
        ),
        Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            title: const Text('Terms & Conditions'),
            backgroundColor: Colors.transparent,
            elevation: 0,
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildSection(
                  context,
                  '1. Introduction',
                  'Welcome to VoyZa ("VoyZa" or "the App"), a trip planner and multi-stop route optimizer. These Terms and Conditions govern your use of the App and its services. By downloading, accessing, or using the App, you agree to be bound by these Terms. If you do not agree, please do not use the App.',
                ),
                _buildSection(
                  context,
                  '2. Description of Service',
                  'VoyZa lets you search for places, save them to trips, build itineraries, and generate optimized multi-stop routes. Creating an account lets your trips sync across your devices through our cloud service and lets you collaborate on trips with people you invite. VoyZa also offers an optional paid subscription, VoyZa Pro.',
                ),
                _buildSection(
                  context,
                  '3. Third-Party Services',
                  "The App relies on third-party services to work, including Google Maps Platform (Maps, Places, and Directions) for maps, place information, and routing; Supabase for account authentication and cloud data storage; RevenueCat together with the App Store and Google Play for subscriptions and billing; and Firebase (Google) for analytics, performance monitoring, and push notifications. Your use of these features is also subject to those providers' terms, including Google's Terms of Service and the Google Maps/Google Earth Additional Terms of Service.",
                ),
                _buildSection(
                  context,
                  '4. Location Data',
                  'VoyZa uses your device location to show where you are on the map, find nearby places, and optimize routes from your current position. Location and place coordinates are sent to Google Maps Platform to provide search, geocoding, and routing. You can control location access in your device settings; some features will not work without it. See our Privacy Policy for details on how location data is handled.',
                ),
                _buildSection(
                  context,
                  '5. Your Content, Cloud Storage & Collaboration',
                  "Trips, places, routes, notes, and other content you create (\"Your Content\") are stored in your VoyZa account in our cloud database and synced to your devices — they are not kept only on your device. When you invite collaborators to a trip, they can view that trip's content and, if you grant edit access, change it; every member of a shared trip can also see the other members' email addresses. You are responsible for the content you add and for the people you choose to invite. You keep your rights in Your Content and grant us the limited rights needed to store, process, sync, and display it in order to operate the service. See our Privacy Policy for details.",
                ),
                _buildSection(
                  context,
                  '6. Subscriptions (VoyZa Pro)',
                  'VoyZa Pro is an optional auto-renewing subscription sold through the App Store and Google Play. Pricing, billing period, and any free-trial terms are shown at the point of purchase and are billed by the applicable store. Subscriptions renew automatically unless cancelled at least 24 hours before the end of the current period; you can manage or cancel them in your App Store or Google Play account settings. To keep our free tier fair, we use a device identifier to enforce one free trial per device.',
                ),
                _buildSection(
                  context,
                  '7. Referral & Invitation Program',
                  'You can invite other people to VoyZa and to collaborate on your trips. When you invite someone who is not yet a VoyZa user by email, we store that email address to deliver the invitation and to connect you both if they join (see our Privacy Policy). Under our referral program (for example, "give a month, get a month"), when a person you refer signs up using your referral link or code, they may receive a promotional period of VoyZa Pro; you may receive a small instant benefit at their sign-up (currently 2 additional free place slots per referred sign-up, up to a maximum of 10), and when they go on to start a paid subscription (after any free trial), you may receive a promotional period as well (currently 30 days each). If you have an active paid subscription when a reward is earned, your promotional period may be applied when your current subscription period ends. Rewards are granted as promotional access, have no cash value, and are non-transferable. To keep the program fair, rewards are capped (currently 12 rewarded referrals per 12-month period), and referrals must be genuine invitations to real people you know. Self-referrals; creating fake, duplicate, or additional accounts; referring your own devices or accounts; and any automated, deceptive, or abusive activity are prohibited, and we use limited signals (including a device identifier) to detect them. Please invite only people who are happy to hear from you, and do not send spam. We may change, suspend, or end the referral program, and may withhold, revoke, or reverse rewards obtained through prohibited or fraudulent activity, at any time.',
                ),
                _buildSection(
                  context,
                  '8. Analytics & Advertising',
                  "We use Firebase Analytics and Google Analytics to understand how VoyZa is used so we can improve it, and we measure the effectiveness of our own marketing — for example, attributing app installs and subscriptions to advertising campaigns run through Google Ads. VoyZa does not display third-party advertising inside the App, and we do not track you across other companies' apps and websites for advertising. For users in the EEA, the UK, and Switzerland, non-essential analytics and advertising signals stay off until you opt in; you can review or change your choice at any time in Settings → Privacy → Analytics & Ads consent. Full details are in our Privacy Policy.",
                ),
                _buildPrivacySection(context),
                _buildSection(
                  context,
                  '10. Disclaimer of Warranties',
                  'The App and its services are provided "as is" and "as available" without warranties of any kind. We do not warrant that the App will be error-free or uninterrupted. All travel information, including maps, routes, travel times, and distances, is provided by third-party services and may contain inaccuracies. Always exercise your own judgment, be aware of your surroundings, and verify information before relying on it for navigation or travel. We are not responsible for any damages or losses resulting from your reliance on this information.',
                ),
                _buildSection(
                  context,
                  '11. Limitation of Liability',
                  'To the fullest extent permitted by applicable law, in no event shall VoyZa or its creators be liable for any indirect, incidental, special, consequential, or punitive damages, or any loss of profits, revenues, data, use, goodwill, or other intangible losses, resulting from (a) your access to or use of, or inability to access or use, the App; (b) any conduct or content of any third party on the App; or (c) unauthorized access, use, or alteration of your transmissions or content.',
                ),
                _buildSection(
                  context,
                  '12. Intellectual Property',
                  'All rights, title, and interest in and to the App (excluding content provided by third parties and Your Content) are and will remain the exclusive property of VoyZa and its creators. The App is protected by copyright and other laws. Nothing in these Terms gives you the right to use the VoyZa name or any VoyZa trademarks, logos, domain names, or other distinctive brand features.',
                ),
                _buildSection(
                  context,
                  '13. Changes to Terms',
                  'We may revise these Terms from time to time. We will notify you of material changes by posting the updated Terms on this page. Your continued use of the App after changes take effect means you accept the revised Terms. Please review this page periodically.',
                ),
                _buildContactSection(context),
                const SizedBox(height: 24),
                const Text(
                  'Last updated: July 3, 2026',
                  style: TextStyle(
                      fontStyle: FontStyle.italic, color: Colors.grey),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPrivacySection(BuildContext context) {
    final bodyStyle =
        Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.5);
    return Padding(
      padding: const EdgeInsets.only(bottom: 24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '9. Privacy',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 8),
          RichText(
            text: TextSpan(
              style: bodyStyle,
              children: [
                const TextSpan(
                  text:
                      'Our Privacy Policy explains what we collect, how we use and share it, the choices you have, and how to exercise your rights. It forms part of these Terms. You can read it at ',
                ),
                WidgetSpan(
                  alignment: PlaceholderAlignment.baseline,
                  baseline: TextBaseline.alphabetic,
                  child: GestureDetector(
                    onTap: () => launchUrl(
                      Uri.parse(_privacyPolicyUrl),
                      mode: LaunchMode.externalApplication,
                    ),
                    child: Text(
                      'voyza.xtremon.com/privacy',
                      style: bodyStyle?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                        decoration: TextDecoration.underline,
                        decorationColor: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                ),
                const TextSpan(
                    text: ', or open it any time from Settings in the App.'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContactSection(BuildContext context) {
    const email = 'hengsamkok76@gmail.com';
    final bodyStyle =
        Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.5);
    return Padding(
      padding: const EdgeInsets.only(bottom: 24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '14. Contact Us',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 8),
          RichText(
            text: TextSpan(
              style: bodyStyle,
              children: [
                const TextSpan(
                  text:
                      'If you have any questions about these Terms and Conditions, you can contact us at ',
                ),
                WidgetSpan(
                  alignment: PlaceholderAlignment.baseline,
                  baseline: TextBaseline.alphabetic,
                  child: GestureDetector(
                    onTap: () => launchUrl(Uri(scheme: 'mailto', path: email)),
                    child: Text(
                      email,
                      style: bodyStyle?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                        decoration: TextDecoration.underline,
                        decorationColor: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ),
                ),
                const TextSpan(text: '.'),
              ],
            ),
          ),
        ],
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
