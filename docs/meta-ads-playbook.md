# Meta ads for VoyZa: readiness audit and playbook

Written 2026-10-01 from the code, the privacy policy, the store and platform
requirements current at that date, and the Meta Ads account connected to the
workspace. The app side was built on 2026-10-02 (section 1a); nothing has
been released and no campaign exists.

## 1. Verdict

VoyZa cannot run Meta app ads as it is. Three things stand in the way, and
all three are in your control:

1. **The app sends nothing to Meta.** There is no Meta SDK, no SKAdNetwork
   registration, no App Tracking Transparency prompt. Meta could show ads, but
   it could not tell which installs, trials or subscriptions they produced,
   so it could not optimise, and you could not tell whether the money worked.
2. **The privacy policy promises the opposite.** Section 6 says the app sends
   no data to Meta, does not register SKAdNetwork, shows no ATT prompt, and
   declares `NSPrivacyTracking = false`. It also says what you will do before
   changing that: update the policy and the iOS tracking declaration, present
   an ATT prompt, set `NSPrivacyTracking = true`, declare tracking domains.
   Those are the exact steps below. Section 13 additionally claims no
   "sharing" under California law, which changes once Meta is in.
3. **The Meta side has no VoyZa identity.** Seven ad accounts and eight Pages
   are reachable, all for other businesses; there is no VoyZa Page, no
   Instagram account linked to the personal ad account, no dataset, and no
   developer app for VoyZa. (By 2026-10-02 the portfolio, Page, ad account
   and a dataset existed; section 3.3 has the current state.)

Recommended shape: **Meta SDK in the app for installs, behaviour events and
the trial and purchase events the app already logs; Firebase kept as is.**
No mobile measurement partner (AppsFlyer, Adjust) at this stage: you run one
network.

RevenueCat's server-side Meta integration is the natural second step, not
the first. The app stores each user's email and phone number in RevenueCat
(`lib/services/revenuecat_service.dart:447-453`), and that integration
forwards both to Meta in hashed form. That is a heavier disclosure, with
contact details joining the tracking labels in both stores, and it needs
consent enforced on RevenueCat's servers as well as in the app. Start
without it; add it when volume justifies the extra matching quality. The
policy draft in `legal/DRAFT-privacy-policy-meta-ads.md` is written for the
lighter step and holds the extra paragraph in reserve.

Order of work: app code and consent (one release) → policy and store forms →
Meta accounts and events → first campaign on Android → iOS.

## 1a. Status on 2026-10-02

**App side built and switched on in the working tree. Not released.** Meta's
SDK, Apple's tracking prompt and the two-choice consent are in the code,
with Meta App ID `2785293015222172`. Both apps compile (Android debug and
release, iOS without signing) and the test suite passes. Nothing has been
run on a device, and no event has yet been seen in Events Manager.

**Do not tag a release from this code until all four are done:**

1. ~~The `request_country` function is in the database.~~ Done 2026-10-03:
   applied through the SQL editor, definition matches
   `supabase/migrations/20261002090000_request_country.sql`, and a call
   with the app's public key returns the caller's country.
2. The revised privacy policy is published, on the website and in
   `legal/privacy-policy.md` (text in `legal/DRAFT-privacy-policy-meta-ads.md`).
3. App Store Connect → App Privacy and Google Play → Data safety are updated
   (section 3.2).
4. Test events from a real device arrive in Events Manager, once each
   (section 3.3 C). Done on an iPhone on 2026-10-03 for everything except
   purchases: installs, launches and session ends, one sign-up, and trips
   (a copied trip counted, a trip made with the switch off not sent),
   checked against the database's own record of what was created and when.
   Still to do: a sandbox trial and purchase (`StartTrial`, `Subscribe`,
   `fb_mobile_purchase`), and the same run on an Android phone, where the
   native code is separate and has not yet run on a device.

| Piece | Where |
|---|---|
| Two separate choices, their rules, and the carry-over from the old single switch | `lib/utils/measurement_decision.dart`, `lib/services/measurement_consent_service.dart` |
| Region from device setting plus connection country, opt-in when unsure | `lib/utils/measurement_region.dart`, migration `20261002090000_request_country.sql` |
| Opt-in prompt, one-time notice, the screen before Apple's prompt | `lib/widgets/measurement_consent_dialog.dart` |
| Two Settings switches | `lib/widgets/measurement_settings_tiles.dart` |
| The fixed list of events an ad platform may receive | `lib/utils/ads_event_map.dart` |
| Meta's SDK and Apple's prompt, Dart side | `lib/services/meta_ads_bridge.dart` |
| The same, native side | `MetaAdsBridge` in `ios/Runner/AppDelegate.swift` and in `android/app/src/main/kotlin/com/superiordev/voyza/MetaAdsBridge.kt` |
| The build switch, on by default | `lib/core/measurement_config.dart` (`--dart-define=VOYZA_ADS_MEASUREMENT=false` is the way back) |

**Decisions taken while building, and why**

- **Our own small bridge, not the `facebook_app_events` plugin.** The plugin
  starts Meta's SDK at launch for everyone. Reading the SDK's source showed
  that start-up alone contacts Meta's servers and writes an identifier to
  the device, and the policy promises that nothing of the kind happens
  before consent. The bridge starts the SDK only when ads measurement is
  allowed. For someone who refuses, it never runs.
- **SDK versions pinned exactly:** iOS `FBSDKCoreKit 18.1.1`, Android
  `facebook-core 18.3.0`. Meta's unreleased code already adds collection of
  screen titles and opened links, on by default. Both are switched off in
  advance (`FBSDKAutoLogMetaDataEnabled`,
  `com.facebook.sdk.AutoLogMetaDataEnabled`), and an upgrade is a decision,
  not something a build picks up.
- **Graph API version named in code:** `MetaAdsSink.graphApiVersion`,
  `v24.0`, which Meta serves until 18 February 2028. SDK 18 still defaults
  to versions Meta has retired. Raise it when the SDK is upgraded.
- **Android:** `facebook-core` only. The provider that would start the SDK
  at launch is removed from the manifest, and so are two Privacy Sandbox
  permissions the SDK declares (ad audiences kept on the device, interest
  topics), which go beyond what the policy describes.
- **iOS:** the SDK is handed only links that carry Meta's ad parameter
  (`al_applink_data`), never trip links or password resets. Its own link
  watching is off (`FBSDKAemAutoSetupEnabled`).
- **App ID and Client Token live in the repository** (`Info.plist`,
  `res/values/strings.xml`), not in Codemagic variables. Both are public
  values that ship in every build, and a missing variable would have
  produced an app that fails at launch. Codemagic needs no change.
- **No `fb<APP_ID>` URL scheme.** It serves Facebook Login and sharing,
  which the app does not use.
- **Apple's prompt is asked through the same bridge,** so the
  `app_tracking_transparency` package was not needed.
- **On an iPhone the Region setting is read natively.** Flutter reports
  the country of the *language* ("English (Cambodia)" stays `en-KH`), and
  since iOS 16 changing Settings → Language & Region → Region no longer
  changes that: the locale becomes `en_KH@rg=frzzzz`. Found by running the
  app in the simulator with the region set to France, where it showed the
  ordinary notice. The bridge now returns `Locale.current.region`, and
  either the language's country or the region setting is enough to require
  consent. Android has no separate region setting.
- **Seen in the iOS simulator on 2026-10-04** (iPhone 17 Pro, iOS 26.3,
  region France, connection Cambodia): the European prompt appears, cannot
  be dismissed by tapping outside, "Allow selected" enables only once a box
  is ticked, and after "Don't allow" both switches are off and nothing of
  Meta's exists in the app's storage. Switching Ads measurement on starts
  the SDK (uploads accepted, Limited Data Use attached,
  `advertiser_tracking_enabled = 0`). On the next launch the app's own
  screen and then Apple's tracking prompt appear, with our wording.
- **Ads measurement that is only "on by default" waits for the country
  check at each launch.** The last known country can be stale: someone who
  saw the notice at home and then opens the app in France must be asked
  first, and an SDK that has already contacted Meta cannot take that back.
  A yes the person gave themselves applies at once, everywhere.

## 2. What the code had on 2026-10-01, before this work

| Area | State | Where |
|---|---|---|
| Analytics SDK | Firebase Analytics 11.x, on by default outside EEA/UK/CH, opt-in inside, decided from the device locale | `lib/services/analytics_consent_service.dart` |
| Google consent signals | Consent Mode v2 flags set from the same choice | same file |
| RevenueCat | 9.x; Apple Search Ads attribution token collection on; no `collectDeviceIdentifiers`, no `setFBAnonymousID` | `lib/services/revenuecat_service.dart:134` |
| Meta SDK | Absent | `pubspec.yaml`, `Info.plist`, `AndroidManifest.xml` |
| iOS tracking | No `SKAdNetworkItems`, no `NSUserTrackingUsageDescription`; app privacy manifest declares purchase history, product interaction, crash and performance data, none as tracking | `ios/Runner/Info.plist`, `ios/Runner/PrivacyInfo.xcprivacy` |
| Android | `com.google.android.gms.permission.AD_ID` already declared; no Meta metadata | `AndroidManifest.xml:16-18` |
| Deep links | Universal links and App Links live for `voyza.xtremon.com/c/*`, custom scheme `voyza://`, incoming links handled by `TripLinkService` | `lib/services/trip_link_service.dart` |
| Events already logged | `signup`, `trip_created`, `place_added`, `route_optimized`, `trial_started`, `purchase`, `paywall_viewed`, `onboarding_completed`, share events | `lib/services/analytics_service.dart` |
| Website | No Meta Pixel, no domain verification tag | `voyza_landing/app/layout.tsx` |
| Consent UI | One-time prompt for EEA/UK/CH users, toggle at Settings → Privacy → Analytics & Ads consent | `lib/widgets/analytics_consent_dialog.dart`, `lib/screens/settings_screen.dart:1225` |

Two weaknesses mattered more once Meta was in. Both are dealt with in
the build described in 1a:

- **Region by device locale.** A user in Germany with an `en_US` phone is
  treated as outside the EEA and gets ads measurement on without consent.
  That is backlog item 3 in `legal/COMPLIANCE-BACKLOG.md`. With Firebase the
  exposure was analytics; with Meta it is sharing device data with an ad
  network. Fix it in the same release, or default *everyone* to opt-in until
  it is fixed.
- **Key injection.** Google Maps keys reach the build through
  `ios/Flutter/AppConfig.xcconfig`, `android/key.properties` and Codemagic's
  env groups. Meta's App ID and Client Token should travel the same way.

## 3. Build order

### 3.1 App code, as built

1. **Meta's SDK.** iOS: `pod 'FBSDKCoreKit', '18.1.1'` in the Podfile.
   Android: `com.facebook.android:facebook-core:18.3.0` in
   `android/app/build.gradle`. No Flutter package.
2. **iOS `Info.plist`.** `FacebookAppID`, `FacebookClientToken`,
   `FacebookDisplayName`; `FacebookAutoLogAppEventsEnabled` and
   `FacebookAdvertiserIDCollectionEnabled` false (the bridge turns them on
   when ads measurement is allowed); `FBSDKAutoLogMetaDataEnabled` and
   `FBSDKAemAutoSetupEnabled` false for good; `SKAdNetworkItems` with
   `v9wttpbfk9.skadnetwork` and `n38lu8286q.skadnetwork`; and
   `NSUserTrackingUsageDescription`: "This lets VoyZa see which of its ads
   brought you here. Your trips, places and location are never shared."
3. **iOS privacy manifest.** `NSPrivacyTracking` true, tracking domain
   `ep1.facebook.com` (the one Meta's SDK declares in its own manifest),
   and Device ID, Product Interaction and Purchase History marked as used
   for tracking.
4. **Android manifest.** `com.facebook.sdk.ApplicationId` and
   `ClientToken` from `res/values/strings.xml`; `AutoLogAppEventsEnabled`,
   `AdvertiserIDCollectionEnabled` and `AutoLogMetaDataEnabled` false;
   `FacebookInitProvider` removed; the two Privacy Sandbox permissions
   removed. `AD_ID` was already declared.
5. **Consent.** `MeasurementConsentService` holds the two choices and
   drives Firebase and Meta. Nothing of Meta's runs before ads measurement
   is allowed; switching it off stops the SDK at once and it is not
   started on later launches.
6. **Apple's prompt.** The app's own one-screen explanation, then the system
   prompt, shown once the person has a trip, never at launch. The answer is
   passed to the SDK (it needs that on iOS 15 and 16; from iOS 17 it asks
   the system itself). Expect roughly a quarter to a third to allow; the
   rest are measured through SKAdNetwork and Aggregated Event Measurement.
7. **Events.** The SDK's automatic events carry installs and launches. The
   app logs `fb_mobile_complete_registration`, `TripCreated`,
   `RouteOptimized`, `StartTrial`, and `Subscribe` or `fb_mobile_purchase`
   with product, price and currency. Nothing else can reach Meta:
   `lib/utils/ads_event_map.dart` is the whole list. `RouteOptimized`
   (added 2026-10-05) is the activation signal: sent **once per install**,
   the first time a route is optimized while ads measurement is on, with
   no stop count and no time saved. Re-optimizing sends nothing. The
   install remembers under `meta_ads_sent_once_RouteOptimized`
   (`MetaAdsSink`), written only when the SDK took the event, so on a
   test phone it shows once: delete and reinstall the app to see it
   again. Firebase still gets `route_optimized` every time, with both
   numbers. `TripCreated` covers a trip made on the create-trip
   screen, the Lisbon sample trip, and (since 2026-10-03) a trip copied
   from a shared code or link, which is how people arriving from an ad for
   a shared trip get their first trip. Duplicating one of your own trips
   reports nothing. In the Meta App Dashboard, "Log in-app events
   automatically" is No for both platforms so a purchase is not counted
   twice. No user data is sent with events: no advanced matching.
8. **RevenueCat, later.** When the server-side integration is added, the app
   calls `Purchases.collectDeviceIdentifiers()` and
   `Purchases.setFBAnonymousID(...)` only for people who allowed ads
   measurement, clears those attributes on withdrawal so RevenueCat stops
   forwarding, and the policy gains the reserved paragraph about hashed
   email and phone. Keep the Apple Search Ads collection as it is.
9. **Limited Data Use.** `['LDU'], 0, 0` is set each time the SDK starts,
   before anything is sent, so Meta applies its state-law mode to people it
   locates in the covered US states.
10. **Deep links from ads.** Point ads at `https://voyza.xtremon.com/...`
    addresses the app already opens directly; a public sample trip via
    `/c/<code>` is an obvious first destination. On iOS the bridge passes
    such a link to the SDK when it comes from a Meta ad. Deferred deep
    linking (first open after install lands on ad content) is a later step.
11. **Build config.** Nothing to add in Codemagic.
12. **Tests.** `test/services/meta_ads_bridge_test.dart`,
    `test/services/measurement_consent_service_test.dart`,
    `test/utils/measurement_rules_test.dart`,
    `test/widgets/measurement_consent_dialog_test.dart`.
13. **Upgrading Meta's SDK.** Read the release notes for new automatic
    collection first, change the two pinned versions together, check
    `MetaAdsSink.graphApiVersion` is still served, rebuild both apps, and
    repeat the test-event check in Events Manager.

### 3.2 Policy and stores (before the release ships)

- **Privacy policy** (`legal/privacy-policy.md`, and the website copy, which
  is deployed by hand):
  - Section 6: replace the "no Meta" paragraph with what actually happens:
    Meta Platforms as an advertising and measurement partner; SKAdNetwork
    registered; ATT prompt shown; IDFA and Android Advertising ID shared with
    Meta only after consent and, on iOS, only when ATT is allowed; tracking
    domains declared; how to withdraw (in-app toggle, iOS Settings →
    Privacy → Tracking, Android ads settings, Meta's "Your activity off
    Meta technologies").
  - Section 2 identifiers row and Section 4 legal basis: add the IDFA and the
    sharing with Meta under consent.
  - Section 8 partner table: add Meta Platforms Ireland as an independent
    controller, linking Meta's privacy policy and Business Tools Terms.
  - Section 10: Meta's retention is theirs; say so.
  - Section 13 (California and other US states): either keep the "no sale, no
    sharing" position on the strength of Limited Data Use and say so, or add
    a "Do Not Share" control. The current flat claim cannot stand as written.
  - Section 14 already refers to a date-of-birth check the app does not
    perform; fix it in the same edit.
- **App Store Connect → App Privacy.** Add "Data Used to Track You": Device
  ID and Product Interaction (and Purchases if RevenueCat sends them with the
  IDFA). Apple compares this with the ATT prompt and the manifest.
- **Google Play → Data safety.** Device or other IDs, App interactions and
  Purchase history become "shared with third parties" for Advertising or
  marketing and Analytics; collection stays as declared.
- **Meta's own rules.** Business Tools Terms (you must have the right to send
  the data, hence the consent gate), Advertising Standards (claims must be
  true of the app as shipped; screenshots must be real), the developer app
  needs a privacy policy URL and a data-deletion instructions URL, and the
  annual Data Use Checkup.

### 3.3 Meta side

**In place on 2026-10-02**, read from the connected Ads account:

| Asset | ID | State |
|---|---|---|
| Business portfolio "VoyZa" | `1789296259078885` | exists |
| Page "VoyZa" | `1430169460171259` | owned by the portfolio |
| Ad account "VoyZa" | `1791728618617674` | active, USD, no payment method |
| Dataset "voyza" | `1857447458754944` | created 2026-10-02, no events yet |
| Instagram account | none | optional |
| Developer app "VoyZa" | App ID `2785293015222172` | created 2026-10-02; App ID and Client token are in the app |

Where Meta asks for a legal business name (business info, billing, the
"beneficiary and payer" fields for ads shown in the EU), give Heng Kok as an
individual, the same controller the privacy policy names. Not Xtremon.

**A. The developer app** (about twenty minutes; this is what produces the
App ID and Client Token the app build needs)

1. Open https://developers.facebook.com/apps/creation/. A first-time
   developer is asked to register before the form appears.
2. **App details:** name `VoyZa`, your contact email.
3. **Use cases:** "Create & manage app ads with Meta Ads Manager", and only
   that one.
4. **Business:** the VoyZa portfolio.
5. **Requirements**, **Overview**, then **Go to dashboard**.
6. Left menu **Use cases → Customize**:
   - **+ Business Portfolio:** VoyZa, with ad account `1791728618617674`.
     Only this ad account.
   - **+ Platform → iOS:** Bundle ID `com.superiordev.voyza`, iPhone Store
     ID `6758559163`, iPad Store ID `6758559163`.
   - **+ Platform → Android (Google Play):** package
     `com.superiordev.voyza`, class `com.superiordev.voyza.MainActivity`,
     and two key hashes. A key hash is the base64 of a certificate's SHA-1:
     take the SHA-1 of the app signing key and of the upload key from Play
     Console's App signing page and run each through
     `echo "<SHA-1>" | xxd -r -p | openssl base64`.
   - **Set up App Events:** "Log in-app events automatically" to **No** for
     both platforms (the app logs trials and purchases itself, so Meta's own
     purchase logging would count each one twice). Leave "Collect the Apple
     Advertising Identifier (IDFA)" on: the app keeps it off on each device
     until the person agrees. Leave the In-App Purchase Shared Secret empty.
     Skip the Quickstart that follows; it is the SDK work in section 3.1.
7. **App settings → Basic:** icon
   `ios/Runner/Assets.xcassets/AppIcon.appiconset/1024.png`, Privacy Policy
   URL `https://voyza.xtremon.com/privacy`, Terms of Service URL
   `https://voyza.xtremon.com/terms`, User data deletion → instructions URL
   `https://voyza.xtremon.com/privacy` (section 12 explains deletion),
   category Travel, App domain `voyza.xtremon.com`.
8. **App settings → Advanced:** check `1791728618617674` is under
   "Authorized Ad Account IDs"; copy the **Client token** from the Security
   block. The App ID is at the top of every dashboard page. The App Secret
   is never needed in the app and should not be shared.
9. **Publish** in the left menu, resolve anything it lists, then the
   **Publish** button.

**B. The ad account**

- Add a payment method (Ads Manager → Billing & payments).
- Check the time zone before anything else: Ads Manager → Billing &
  payments → Payment settings → Business info → Edit → "Currency and time
  zone". It should be your own (Asia/Phnom_Penh, UTC+7): the daily budget
  resets at midnight in this zone and "today" in the reports follows it.
  New ad accounts default to Pacific Time. Changing it makes Meta close the
  account and open a new one with a **new ID**, so do it while the account
  is empty, then use the new ID in step A6 and A8 and in the table above.
- Turn on two-factor authentication and give one more trusted person full
  control of the portfolio, so a problem with one Facebook login cannot
  lock VoyZa out.

**C. After the first build with Meta's SDK**

1. **Events Manager.** Open the app under Data sources → Settings → Linking
   → Link → "Create from a Pixel ID" and choose the existing `voyza`
   dataset, so app and website events live in one place. Do it before the
   first campaign; relinking later disturbs reporting.
2. Send test events from a device and check App Install, App Launch,
   CompleteRegistration, TripCreated, RouteOptimized, StartTrial and
   Subscribe each arrive exactly once (RouteOptimized stays at one however
   often the route is optimized again). Three places to look: Events Manager → Data sources → the
   app `VoyZa` (ID `2785293015222172`, not the web dataset `voyza`) → Test
   events, which is live but has to recognise the phone through the
   Facebook app; the same data source's Overview, which lags by half an
   hour or more; and, in a debug build, the device log, where the SDK
   prints each event and Meta's answer (Xcode console: `FBSDKAppEvents:
   Flushed ... - Success`; Android logcat: tags starting `FacebookSDK.`).
3. Configure SKAdNetwork in Events Manager around StartTrial and Subscribe.
4. Give the ad account access to the dataset (Business settings → Data
   sources → Datasets → Add assets).

**D. Optional, any time**

- An Instagram account for VoyZa, added under Business settings → Accounts.
  Ads can run on Instagram under the Page alone, but a real profile gives
  people somewhere to land.
- Domain verification for `voyza.xtremon.com` in the portfolio (a meta tag
  in the site's head). Needed for web measurement; a Pixel on the landing
  pages would let you retarget people who opened a shared trip page.
- **RevenueCat dashboard, later.** Meta Ads integration in Conversions API
  mode, with the dataset ID and a Conversions API token from Events
  Manager. Not in the first release, for the reason given in section 1.

## 4. Running the campaigns

**Objective and structure.** App promotion with Advantage+ app campaigns.
One Android campaign first: measurement is cleaner, learning is cheaper, and
it teaches you which creatives work before iOS, where reporting is modelled,
delayed by a day or more, and capped at 24 campaigns per app (18 of them
manual). Add the iOS campaign once the Android one has a working creative
set.

**Optimisation ladder.** Start on installs. Move to an app event when that
event reaches roughly fifty a week per ad set (Meta quotes lower thresholds
for installs and purchases in Advantage+ app campaigns, but fifty is the
safe planning number): CompleteRegistration, then TripCreated, then
RouteOptimized, then StartTrial. Optimising for Subscribe directly stalls
until volume exists. RouteOptimized is the deeper of the two middle rungs:
the person pressed Optimize and got a route back, which is what the app is
for. It is not proof of a trip of their own, because the sample trip's
places can be optimized without adding any. Even before it has the volume
to optimise on, read it as cost per activated person when comparing ads. TripCreated and RouteOptimized are
our own event names, not Meta's standard ones: Meta's documentation says
such events can be the optimisation event in app-install campaigns (see
Sources). Whether an Advantage+ app campaign lists them has not been
checked; if it does not, use a manual App promotion campaign for that
rung.
Every edit to budget, audience or creative restarts learning, so leave a set
alone for seven days.

**Budget.** Twenty to forty dollars a day per campaign to start, campaign
budget optimisation on, no changes in week one. Expect cost per result 20 to
50 percent above its eventual level during learning.

**Targeting.** Broad, with Advantage+ audience; age 18 to 54; one language
per campaign. Choose countries where the store listing is localised and
people pay: run two or three tiers as separate ad sets only when volume
justifies it. Once events flow, exclude existing users with an app-activity
custom audience.

**Placements.** Advantage+ placements is Meta's default and usually fine;
if install quality looks poor in the first two weeks, drop Audience Network
and keep Facebook and Instagram feeds, Stories and Reels.

**Creative.** Vertical 9:16 video of 15 to 30 seconds; the map putting a
messy day into order inside the first two seconds; captions on; a plain
ending with the store badges. Your UGC reel pipeline (`voyza_reel.py`) is
the right tool. Three to five distinct creatives per ad set, 4:5 and 1:1
cuts of each, five to ten new variations every two to three weeks. Name each
by the hypothesis it tests. Every claim in an ad must be true of the shipped
app; "saves you hours of backtracking" needs the in-app time-saved figure
behind it.

**Store pages.** The first three lines of the store description and the
first two screenshots should say what the ad said. Custom product pages
(iOS) and custom store listings (Android) per campaign are a later
refinement.

**Measurement and guardrails.** Three views, none of them exact: Ads Manager
(modelled, delayed on iOS), App Store Connect and Play Console installs by
source, and RevenueCat charts fed by the Conversions API events. Track
weekly: spend, installs, cost per install, trial starts, cost per trial,
subscribes, and cost per subscriber against RevenueCat's lifetime value.
Kill a creative below about 0.8 percent click-through after 3,000
impressions, and a set whose cost per install is twice the target after
fifty dollars. Compare day-1 and day-7 retention of paid installs with
organic; a gap means the creative promises something the app does not do.

**Timeline.** Week 1: app code and consent. Week 2: policy, store forms,
Meta accounts, test events. Week 3: release (the version after 1.10.0).
Week 4: first Android campaign. Week 6: iOS.

## 5. Decisions only you can take

- ~~Which ad account and business portfolio VoyZa lives in.~~ Settled
  2026-10-02: the new VoyZa portfolio and its own ad account.
- The markets and the monthly budget for the first two months.
- ~~Whether the locale-based consent gate is fixed in the same release.~~
  Done: the region now comes from the device setting and the connection's
  country together.
- Whether California is handled by Limited Data Use alone or by adding a
  "Do Not Share" control to the policy and the app.
- Whether to add deferred deep linking now or after the first campaigns.
- When to add RevenueCat's server-side integration, which sends hashed email
  and phone to Meta.

The policy text and in-app wording for all of this are drafted in
`legal/DRAFT-privacy-policy-meta-ads.md`.

## Sources

- Meta, App Events for iOS: Info.plist keys, automatic events, advertiser
  tracking — https://developers.facebook.com/docs/app-events/getting-started-app-events-ios/
- Meta, App Events for Android: manifest keys, automatic events —
  https://developers.facebook.com/docs/app-events/getting-started-app-events-android/
- Meta, Advertiser Tracking Enabled and iOS 17 —
  https://developers.facebook.com/docs/app-events/guides/advertising-tracking-enabled/
- Meta, SKAdNetwork IDs `v9wttpbfk9` and `n38lu8286q` —
  https://developers.facebook.com/docs/SKAdNetwork/
- Meta, Data Processing Options / Limited Data Use —
  https://developers.facebook.com/docs/marketing-apis/data-processing-options/
- Meta, key concepts for iOS 14 and Meta Business Tools —
  https://www.facebook.com/business/help/387440828988900
- RevenueCat, Meta Ads integration —
  https://www.revenuecat.com/docs/integrations/attribution/meta-ads
- Meta's SDK source, read at the pinned versions to see what start-up does
  and which switches exist — https://github.com/facebook/facebook-ios-sdk
  (v18.1.1) and https://github.com/facebook/facebook-android-sdk
  (sdk-version-18.3.0)
- `facebook_app_events` package, considered and not used (it starts the SDK
  at launch) — https://pub.dev/packages/facebook_app_events
- Graph API versions and their end dates —
  https://developers.facebook.com/docs/graph-api/changelog/versions/
- Meta, the app ads use case in the App Dashboard (portfolio, platforms,
  App Events settings, publish) —
  https://developers.facebook.com/docs/development/create-an-app/app-ads-use-case/
- Meta, how to set up your account for app promotion campaigns —
  https://www.facebook.com/business/help/754990972934516
- Meta, iOS 14+ campaign limits (24 campaigns per app, up to 18 ad
  accounts; an earlier version of this document said nine and one) —
  https://www.facebook.com/business/help/651033805513936 and
  https://www.facebook.com/business/help/616924392655485
- Meta, linking an app to a dataset in Events Manager —
  https://www.facebook.com/business/help/5818684664831465
- Aggregated Event Measurement explained (event cap removed) —
  https://www.conversios.io/blog/meta-aggregated-event-measurement/
- Meta ads for app installs, 2025 playbook —
  https://thread-transfer.com/blog/2025-08-05-meta-ads-app-install/
- Learning phase and the fifty-event rule —
  https://adlibrary.com/posts/meta-ads-learning-phase-50-events-guide
- Meta, optimising app ads for an app event, including events with your
  own names (`custom_event_type` OTHER with `custom_event_str`; "only
  available in the App Installs objective") —
  https://developers.facebook.com/documentation/app-ads/optimizing-your-app-ad
