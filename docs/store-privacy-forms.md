# Store privacy forms — answers for the first build with Meta's SDK

Written 2026-10-06 from the code and the live backend as audited that week
(see `legal/privacy-policy.md`, which says the same things in prose). Fill
the forms from these tables; where a judgement call was made, the row says
so, and the conservative answer is the one given. Update both forms whenever
`lib/utils/ads_event_map.dart`, the SDK list in `pubspec.yaml`, or what the
backend stores changes.

What the app does, in one paragraph: accounts are email + password, with an
optional first and last name; trips and places are stored in Supabase; the
device's location is used while the app is open and sent to Google Maps
Platform for search, geocoding and routing, never stored by us; purchases go
through RevenueCat and the stores; Firebase Analytics and Performance run
only where "Usage analytics" is on; Meta's SDK and Apple Search Ads
attribution run only where "Ads measurement" is on; Firebase Cloud Messaging
delivers pushes; a device identifier (iOS vendor id / Android ID) is recorded
when a trial starts, for abuse checks. Both choices are off until opt-in in
the EEA, UK and Switzerland.

---

## A. App Store Connect → App Privacy

**Do you or your third-party partners collect data from this app?** Yes.

**Tracking.** Yes — the app uses data for tracking as Apple defines it: when
Ads measurement is on, events and the device's advertising identifier (only
after the person taps Allow on the tracking prompt) go to Meta, which links
them with its own data to measure and deliver our ads. The App Tracking
Transparency prompt is in the app, so this answer is allowed.

**Privacy Policy URL:** https://voyza.xtremon.com/privacy
**Privacy Choices URL (optional):** leave empty, or the same URL.

For every data type below, the three sub-questions are: *purposes*,
*linked to the user's identity*, *used for tracking*.

| Data type | Collected? | Purposes | Linked | Tracking | Why |
|---|---|---|---|---|---|
| **Contact Info → Email Address** | Yes | App Functionality; Developer's Advertising or Marketing | Yes | No | Account sign-in; invitations; verification codes; lifecycle emails (welcome, activation, win-back) are marketing. Also shared with RevenueCat as a subscriber attribute. |
| **Contact Info → Name** | Yes | App Functionality | Yes | No | Optional first/last name from the Profile screen, shown to trip members; sent to RevenueCat if set. |
| Contact Info → Phone Number / Physical Address / Other | No | — | — | — | Never asked for. |
| **Identifiers → User ID** | Yes | App Functionality; Analytics | Yes | No | VoyZa account ID, RevenueCat app user ID. |
| **Identifiers → Device ID** | Yes | App Functionality; Analytics; Developer's Advertising or Marketing | Yes | **Yes** | Firebase app-instance ID and identifier-for-vendor; FCM push token (`device_tokens`); vendor id in `trial_devices`; Meta's install identifier; the IDFA only after the tracking prompt is allowed. The Meta ones are tracking. |
| **Purchases → Purchase History** | Yes | App Functionality; Analytics; Developer's Advertising or Marketing | Yes | **Yes** | RevenueCat and our subscription mirror; trial-start and purchase events (plan, price, currency) go to Firebase and to Meta. |
| **Location → Precise Location** | Yes | App Functionality | No | No | Device GPS while the app is open, sent to Google Maps Platform to bias search, reverse-geocode and route. Not stored by us, not tied to the account. (Transient use is arguably not "collection" under Apple's definition; declaring it is the safe choice.) |
| **Location → Coarse Location** | Yes | Analytics; Developer's Advertising or Marketing | No | **Yes** | Country/region derived from the IP address by Firebase and Meta (and by our own server for the consent check, where it is not stored). Meta's use makes it tracking. |
| **User Content → Other User Content** | Yes | App Functionality | Yes | No | Trips, places (names, coordinates, days, durations, tags), descriptions. |
| User Content → Photos or Videos / Audio / Emails or Text Messages / Gameplay / Customer Support | No | — | — | — | Share cards are saved *to* Photos; nothing is read. |
| **Search History** | Yes (conservative) | App Functionality | No | No | Place search text goes to Google Maps Platform to answer the search; we keep none of it. Many apps omit this; declaring it costs nothing. |
| Browsing History | No | — | — | — | — |
| **Usage Data → Product Interaction** | Yes | Analytics; Developer's Advertising or Marketing; App Functionality | Yes | **Yes** | Events: sign-up, trip created, place added, route optimized, Auto-plan, paywall views, onboarding, sharing (Firebase); sign-up, trip created, first route optimized, trial, purchase (Meta). Place and copy counts are also kept with the account for the free-tier rules. |
| **Usage Data → Advertising Data** | Yes | Developer's Advertising or Marketing; Analytics | Yes | **Yes** | The Meta ad link that opened the app (iOS) is handed to Meta's SDK; the Apple Search Ads attribution token is read through RevenueCat; Google Consent Mode ad signals. |
| **Usage Data → Other Usage Data** | Yes | Analytics; Developer's Advertising or Marketing | Yes | **Yes** | Firebase's automatic events (first open, sessions, app updates) and Meta's automatic install, launch and session-length events. |
| **Diagnostics → Crash Data** | Yes | Analytics; App Functionality | No | No | No crash-reporting SDK; Firebase Analytics still counts crashes/exceptions (`app_exception`). Declared because Apple's definition includes crash counts. |
| **Diagnostics → Performance Data** | Yes | Analytics; App Functionality | No | No | Firebase Performance: launch time, network latency, slow/frozen frames. |
| **Diagnostics → Other Diagnostic Data** | Yes | Analytics; App Functionality | No | No | Device model, OS and app version, carrier, language, time zone sent with analytics and performance data, and with Meta events. |
| Financial Info (Payment Info, Credit Info, Other) | No | — | — | — | The stores handle payment; we never see card data. |
| Health & Fitness, Sensitive Info, Contacts, Body, Environment Scanning, Hands/Head, Surroundings | No | — | — | — | — |

Notes for the form:
- "Linked to the user" is answered Yes wherever the data sits next to an
  account ID or a device identifier on our side (Supabase, RevenueCat,
  Firebase instance ID). That is the conservative reading; it can only be
  softened by a lawyer, not hardened.
- The iOS privacy manifest (`ios/Runner/PrivacyInfo.xcprivacy`) lists the
  same fifteen types with the same linked/tracking answers and purposes
  (aligned 2026-10-06). Change both together.

---

## B. Google Play Console → App content → Data safety

**Overview**
- Does your app collect or share any of the required user data types? **Yes**
- Is all of the user data collected by your app encrypted in transit? **Yes** (HTTPS everywhere; cleartext traffic is disabled in the manifest)
- Do you provide a way for users to request that their data is deleted? **Yes**
- Account deletion: **Yes, in the app** (Settings → Delete Account) and by web request: `https://voyza.xtremon.com/#how-can-i-delete-my-voyza-account`
- Can users request deletion of some data without deleting the account? **Yes** (trips and places can be deleted in the app)
- Independent security review: **No**
- **Advertising ID** (separate declaration under App content): **Yes**, used for Analytics and for Advertising or marketing (ads measurement), only where the person has not switched it off.

For every type: *collected*, *shared* (Play counts a transfer to a company that is not our service provider — Meta — as "shared"; Supabase, RevenueCat, Resend and Google acting for us are not), *ephemeral*, *required or optional*, *purposes*.

| Play data type | Collected | Shared | Ephemeral | Required / optional | Purposes (collected) | Purposes (shared) | Why |
|---|---|---|---|---|---|---|---|
| **Location → Approximate location** | Yes | Yes | No | Optional | Analytics; Advertising or marketing | Advertising or marketing; Analytics | IP-derived country by Firebase and Meta; our own consent check stores nothing. Off in the EEA until opt-in; switchable everywhere. |
| **Location → Precise location** | Yes | No | Yes | Optional | App functionality | — | GPS while the app is open, sent to Google Maps Platform (our processor) for search, geocoding, routing; we keep nothing. The location permission can be refused. |
| **Personal info → Name** | Yes | No | No | Optional | App functionality; Account management | — | Optional profile name, shown to trip members; sent to RevenueCat if set. |
| **Personal info → Email address** | Yes | No | No | Optional (guest mode exists) | Account management; App functionality; Developer communications; Fraud prevention, security, and compliance | — | Sign-in; verification codes; invitations; lifecycle emails; shared with RevenueCat as our processor. |
| **Personal info → User IDs** | Yes | No | No | Optional | App functionality; Account management; Analytics; Fraud prevention, security, and compliance | — | Account ID, RevenueCat ID, Firebase app-instance ID. Meta never receives a user ID. |
| Personal info → Phone, Address, Race, Political, Sexual orientation, Other | No | — | — | — | — | — | Never asked for. |
| **Financial info → Purchase history** | Yes | Yes | No | Optional | App functionality; Analytics; Fraud prevention, security, and compliance | Advertising or marketing; Analytics | RevenueCat and our mirror; trial and purchase events (plan, price, currency) go to Meta when Ads measurement is on and to Google Analytics when Usage analytics is on. |
| Financial info → Payment info, Credit score, Other | No | — | — | — | — | — | Google Play handles payment. |
| Health and fitness, Messages, Photos and videos, Audio, Files and docs, Calendar, Contacts | No | — | — | — | — | — | Share cards are written to the gallery, nothing is read. |
| **App activity → App interactions** | Yes | Yes | No | Optional | Analytics; App functionality; Fraud prevention, security, and compliance | Advertising or marketing; Analytics | Events to Firebase (with the Usage analytics switch) and the five Meta events (with the Ads measurement switch); place and copy counts kept with the account. |
| **App activity → In-app search history** | Yes (conservative) | No | Yes | Optional | App functionality | — | Place search text goes to Google Maps Platform to answer the search; nothing kept. Play lets ephemeral data go undeclared, so this row may be omitted. |
| **App activity → Other user-generated content** | Yes | No | No | Optional | App functionality | — | Trips and places. Showing them to collaborators or on a public link happens at the user's request, which Play does not count as sharing. |
| App activity → Installed apps, Other actions | No | — | — | — | — | — | — |
| Web browsing | No | — | — | — | — | — | — |
| **App info and performance → Crash logs** | Yes | No | No | Optional | Analytics; App functionality | — | No crash SDK; Firebase Analytics counts crashes (Play's definition includes "number of times crashed"). |
| **App info and performance → Diagnostics** | Yes | No | No | Optional | Analytics; App functionality | — | Firebase Performance: start time, network latency, frames, device metadata. |
| App info and performance → Other app performance data | No | — | — | — | — | — | — |
| **Device or other IDs** | Yes | Yes | No | Optional | App functionality; Analytics; Fraud prevention, security, and compliance | Advertising or marketing; Analytics | Firebase app-instance ID; FCM push token; Android ID for the trial/referral check; Advertising ID (Firebase, and Meta when Ads measurement is on); Meta's install identifier. Only the advertising-side identifiers are shared. |

Notes for the form:
- "Optional" means the person can prevent the collection: the two switches
  in Settings → Preferences, the location permission, guest mode, and the
  push permission. Nothing in the app requires analytics or ads data.
- If Play asks why "Approximate location" is shared, the honest wording is
  "the IP address accompanies measurement events sent to Meta".

---

## Sources
- Google Analytics for Firebase — Apple App Privacy guidance: https://support.google.com/analytics/answer/10285841
- Google Analytics for Firebase — Play Data safety guidance: https://support.google.com/analytics/answer/11582702
- Firebase SDKs — Apple data collection: https://firebase.google.com/docs/ios/app-store-data-collection
- Firebase SDKs — Play data disclosure: https://firebase.google.com/docs/android/play-data-disclosure
- Meta — preparing for Apple's data disclosure (Facebook SDK app events): https://developers.facebook.com/blog/post/2020/10/22/preparing-for-apple-app-store-data-disclosure-requirements/
- RevenueCat — Apple App Privacy: https://www.revenuecat.com/docs/apple-app-privacy
- RevenueCat — Google Play Data safety: https://www.revenuecat.com/docs/platform-resources/google-platform-resources/google-plays-data-safety
- Google Maps Platform — Apple privacy details for the Maps SDK (points to the SDK's privacy manifest): https://developers.google.com/maps/documentation/ios-sdk/apple-privacy-policy
