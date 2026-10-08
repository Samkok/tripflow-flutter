# Running ads for VoyZa and optimising for subscriptions and lifetime: research

Written 2026-10-08. Sources: VoyZa's own code (`lib/utils/ads_event_map.dart`,
`lib/services/analytics_service.dart`, the paywall), the live RevenueCat
project and Supabase database (read-only), Meta's developer documentation,
RevenueCat's Meta integration docs and State of Subscription Apps 2026, and
the industry write-ups listed at the end. Companion documents:
`docs/meta-ads-playbook.md` (how the Meta build works and what is still open)
and `marketing/analytics-events.md` (the event contract).

## 1. The short version

1. **Optimise for the deepest event you can feed at volume, not the one you
   want.** Meta's delivery system stalls on an event it sees a few times a
   week. Today VoyZa produces about one trial a month and has recorded one
   paid transaction ever, so neither `StartTrial` nor any purchase event can
   be the optimisation event yet. The campaign has to start on installs and
   climb a ladder: installs → CompleteRegistration → TripCreated →
   StartTrial → Purchase (value).
2. **Do not split "subscription" and "lifetime" into separate campaigns or
   separate optimisation goals.** Pool every money event into Meta's standard
   purchase event with a value and a currency. Once there are 30 purchases
   with 5 distinct values in 14 days, switch the campaign to value
   optimisation: Meta then bids more for the people who pay more, which is
   how lifetime ($ once) and annual ($79.99) buyers get favoured over weekly
   buyers without any manual split. The paywall decides the mix, the ad does
   not.
3. **The current build cannot report the money event that matters most.**
   The preselected plan is yearly with a one-week trial on iOS (three days
   on monthly). The conversion from trial to paid happens on Apple's and
   Google's servers days later, usually with the app closed, and the app
   sends Meta nothing for it. Only direct purchases without a trial
   (lifetime, and plans with no trial) reach Meta today. The RevenueCat →
   Meta Conversions API integration, which the playbook deferred to "later",
   is required before any purchase-based optimisation or ROAS reading is
   possible. It is a dashboard setup plus one small app change and a policy
   paragraph that is already drafted.
4. **At VoyZa's present funnel, paid installs lose money, and no bidding
   choice fixes that.** The numbers in section 3 put the cost of one paying
   customer at several hundred dollars against $80 of first-year revenue.
   The ad campaign is still worth starting at a small budget, because the
   events it generates are what teach Meta and what test the creatives, but
   the first two months should be read as a paywall and activation
   experiment with paid traffic, not as a revenue channel.
5. **Channel order:** Meta Android first (already decided), Meta iOS second
   with SKAdNetwork and Aggregated Event Measurement, Apple Ads (the App
   Store search placement) third as the cheapest high-intent iOS source for
   a planner app. Google App Campaigns and TikTok wait: the first needs 30
   or more conversions a month to bid on revenue and its Firebase conversion
   source is now consent-gated in the app; the second buys cheaper installs
   that convert to paid at a lower rate, which is the wrong trade for a
   $79.99 product with no creative library yet.

## 2. What VoyZa has today

### Products and prices (RevenueCat, read 2026-10-08)

| Package | iOS product | Android product | Trial | US price seen in RevenueCat |
|---|---|---|---|---|
| Lifetime (one-time) | `premium.lifetime` | `lifetime` | none | not exposed by the API |
| Weekly | `premium.weekly` | `premium:weekly` | none | not exposed |
| Monthly | `premium.monthly` | `premium:monthly` | 3 days (iOS) | $9.99 |
| Yearly, preselected | `premium.yearly` | `premium:yearly` | 7 days (iOS) | $79.99 |

The paywall preselects yearly, carries the trial on it, and offers lifetime
as a separate option. Android trials come from Play's subscription offers,
which the paywall reads from the default offer. The yearly price is at the
high end for the category: RevenueCat's 2026 report puts the travel median
annual price at $20 and says travel prices lowest of all categories on every
duration. That is a choice to keep, but it means every paid user has to be
worth more, and ads must find people who pay rather than people who tap.

### Funnel volume (RevenueCat and Supabase, read 2026-10-08)

| Measure | Value |
|---|---|
| RevenueCat "new customers" since 2026-04 (installs that reached the SDK, guests included) | about 3,200 |
| Accounts created since 2026-04 (Supabase `auth.users`) | 210 |
| Trials ever started (RevenueCat, all time) | 12 |
| Paid transactions ever (RevenueCat, all time) | 1, $3.63 |
| Active trials / active subscriptions / MRR today | 0 / 0 / $0 |
| Sign-ups that created at least one trip, by month | 29 of 36 (Apr), 1 of 30 (May), 5 of 108 (Jun), 15 of 18 (Sep) |

Two things follow. The ladder's lower rungs have real volume (sign-ups and
trips arrive in dozens, not units). The upper rungs do not: 12 trials over
six months is one every two weeks, and Meta needs tens per week on the
event it optimises for. Travel's median download-to-trial rate is 4.1%;
VoyZa's is about 0.4% of SDK-seen installs and about 6% of sign-ups. The
sign-up gate, not the ad, is where most of the drop happens. Travel's
trial-to-paid rate is the best of any category at a 43.5% median, which
makes trials the right thing to pay for once the app produces them.

### Events the app can send to an ad platform

From `lib/utils/ads_event_map.dart`, with the privacy policy as the fence:

| App event | Meta event sent | Notes |
|---|---|---|
| `signup` | `fb_mobile_complete_registration` | standard event |
| `trip_created` | `TripCreated` | custom event; also fires for copied trips and the sample trip |
| `route_optimized` | `RouteOptimized` | custom event, once per install |
| `trial_started` | `StartTrial` | standard event, with the product id |
| `purchase` (lifetime) | `fb_mobile_purchase` | value + currency |
| `purchase` (subscription, no trial) | `Subscribe` | value + currency |
| trial converted to paid | nothing | happens on the store's servers, app does not see it in time |
| renewal | nothing | same |

Plus the SDK's own install, launch and session-end events. `paywall_viewed`
is logged to Firebase but deliberately not sent to Meta.

## 3. The economics before any targeting decision

Benchmarks (2026 industry figures, see sources): Meta Android cost per
install in the US runs $1.50 to $3.00 and iOS $3.00 to $6.00; Apple Ads
travel-category median cost per install is $3.70; travel download-to-trial
median 4.1%; travel trial-to-paid median 43.5%; annual plans are 66% of
travel subscription sales by volume.

Cost of one payer = cost per install ÷ trial rate ÷ trial-to-paid rate.

| Scenario | CPI | Trial rate | Trial→paid | Cost per trial | Cost per payer |
|---|---|---|---|---|---|
| VoyZa today | $2.00 | 0.4% | 43% | $500 | about $1,160 |
| Travel median | $2.00 | 4.1% | 43% | $49 | about $113 |
| Good paywall | $2.00 | 8% | 43% | $25 | about $58 |

Against $79.99 gross for a year (about $68 after the small-business store
commission, less in regional price tiers), the median case pays back in
year two and only if the person renews; the "today" case never pays back.
RevenueCat's report says travel has the longest tail of any category, with
28% of conversions arriving after week six, so a 7-day attribution window
undercounts and the campaign has to be judged on 30- and 60-day cohorts.

Consequence for the question asked: the choice of optimisation event
changes which users Meta finds, but it cannot move a 0.4% trial rate to 4%.
The paywall and the sign-up gate have to be worked on in parallel with the
campaign (`marketing/voyza-marketing-plan.md` section 8 already lists the
levers). The campaign's first job is to generate enough events to learn
from and to prove creatives, at a budget small enough that the loss is
tuition.

## 4. The optimisation event: how Meta's thresholds work

**Learning phase.** Meta's interface still says 50 optimisation events per
ad set in 7 days. Meta told advertisers in June 2024 that purchase- and
app-install-optimised ad sets exit learning at 10 events, and 25 for most
other conversion goals; several 2026 write-ups repeat these numbers. Plan on
50 for anything that is not an install or a purchase; treat 10 and 25 as
the floor, not the target. An ad set that does not reach the threshold
sits in "learning limited" with worse cost per result, it does not stop
delivering.

**Value optimisation (bid for revenue, not count).** Eligibility is at the
ad account level: at least 30 attributed purchase events with at least 5
distinct values in the past 14 days. For any non-purchase event, standard or
custom, it is 100 events with 5 distinct values in 14 days. Only the
standard purchase event qualifies at the 30 level. This is the single most
important fact for the "subscription or lifetime" question, see section 5.

**Custom events.** Meta's developer documentation allows own-name events as
the optimisation event, but states that custom-event optimisation is only
available in the App Installs objective, which is the manual app-promotion
campaign. Advantage+ app campaigns (the automated type, which the playbook
recommends) list standard app events; whether `TripCreated` and
`RouteOptimized` appear there has not been confirmed in the interface.
Plan: use an Advantage+ app campaign for installs, CompleteRegistration,
StartTrial and Purchase; if a TripCreated rung is wanted, run it as a manual
App promotion campaign, or map trip creation to a standard event (see 5.4).

**Platform asymmetry.** Android attribution is deterministic through the
Google advertising id and the Meta install referrer; reporting is near
real-time. iOS 14.5+ runs through SKAdNetwork (aggregate, delayed 24 to 72
hours, coarse after the first window) and Meta's Aggregated Event
Measurement; campaigns per app are capped (24, 18 of them manual). That is
why Android goes first: it is the only place where a small budget produces
a readable signal within a week.

## 5. Recommendation: one money event, a ladder, and value optimisation

### 5.1 Pool subscriptions and lifetime into Meta's purchase event

Send every real payment (trial conversion, initial purchase of any
duration, lifetime, and renewals) as `fb_mobile_purchase` with `value`,
`currency` and `fb_content_id` = the product id. Keep `StartTrial` as its
own event. `Subscribe` can continue as a reporting event but should not be
the optimisation event: Meta counts it as a non-purchase standard event,
so value optimisation on it needs 100 events in 14 days instead of 30, and
splitting money between `Subscribe` and `fb_mobile_purchase` halves the
count on each.

Why pooling beats separate campaigns:

- Thirty purchases in two weeks is reachable months earlier as one pool
  than as two.
- Value optimisation does the ranking for you. A lifetime buyer carries a
  higher value than an annual buyer, who carries a higher value than a
  weekly buyer. Meta bids accordingly without being told which product is
  which.
- The person has not chosen a product when they see the ad. "Pay once"
  versus "yearly" is a paywall decision made minutes after install; a
  campaign per product would just split the same audience and double the
  learning cost.
- Lifetime is a one-off: its only continuing value to the campaign is as a
  high-value purchase in the pool. Its risk is cannibalising annual
  renewals; that is measured with RevenueCat cohort LTV per product and a
  paywall experiment, not with ad targeting.

Where "lifetime versus subscription" does belong: in the creative. One ad
variant can lead with "plan every trip, pay once", another with the trial.
Name the variants by that hypothesis and compare cost per purchase and
average purchase value, not click-through rate.

### 5.2 Let RevenueCat send the money events

> **Resolved the same day.** The RevenueCat dashboard lets each event be
> renamed to any standard Meta event, so Trial Converted, Initial Purchase
> and Renewal are now mapped to `fb_mobile_purchase` (option (b) below is
> unnecessary). The app no longer sends trial or purchase events itself,
> and no longer stores the email address in RevenueCat, so nothing hashed
> is forwarded and the policy keeps its "never your email" promise. The
> Conversions API section lives on a dataset, not on the app source: the
> app was linked to the `voyza` dataset (ID 1857447458754944), which is
> the ID RevenueCat uses.

RevenueCat's Meta integration (Conversions API, the recommended path)
sends trial start as `StartTrial`, trial conversion, initial purchase and
renewal as `Subscribe`, and non-renewing purchases as `fb_mobile_purchase`.
Three consequences:

- It is the only practical source for trial conversions and renewals,
  which are the money events the yearly plan produces. Without it, the ad
  account sees lifetime purchases and nothing else.
- Its mapping is fixed. Trial conversions arrive as `Subscribe`, not as
  the purchase event. The pooling in 5.1 therefore cannot be done purely on
  RevenueCat's side. Two options: (a) accept `Subscribe` as the money event
  and plan for the 100-event value threshold, reading ROAS from the values
  it carries; or (b) keep the app sending `fb_mobile_purchase` for what it
  can see (lifetime and direct purchases) and add a small server step that
  forwards RevenueCat's trial-conversion and renewal webhooks, which the
  project already receives in `supabase/functions/revenuecat-webhook`, to
  Meta's Conversions API as `fb_mobile_purchase` with the same `event_id`
  scheme. Option (b) gives one pooled purchase event with the lower
  threshold. It is more work and needs the same identifiers as the
  RevenueCat integration. Recommendation: start with (a) because it is a
  dashboard change, and move to (b) when trials are arriving weekly, since
  only then does the 30-versus-100 difference change a date.
- Double counting. RevenueCat's docs say to remove client-side purchase
  tracking for the events it sends. The app currently sends `StartTrial`
  and purchase events itself. When the integration is switched on, the app
  must stop sending `StartTrial` and `Subscribe`; it may keep
  `fb_mobile_purchase` for lifetime only if RevenueCat's non-renewing
  purchase forwarding is off for that product, otherwise lifetime counts
  twice. Simplest rule: once RevenueCat forwards, the app sends only
  CompleteRegistration, TripCreated and RouteOptimized.

What the integration needs from the app: `$fbAnonId` (the Meta SDK's
anonymous id) on both platforms, `$gpsAdId` on Android, `$idfa` and the
ATT status on iOS when the person allowed tracking, and only for people
whose ads-measurement choice is on. The playbook already lists the calls
(`Purchases.collectDeviceIdentifiers()`, `Purchases.setFBAnonymousID`).
The integration also forwards `$email` and `$phoneNumber` hashed when they
are set; the app sets email for every signed-in user, so either the policy
gains the reserved paragraph (drafted in
`legal/DRAFT-privacy-policy-meta-ads.md`) and the stores' forms are
updated, or the app stops setting `$email` for people who did not consent.
Sandbox purchases need the sandbox dataset id in RevenueCat or they land in
production reporting.

### 5.3 The ladder, with the number that moves you up a rung

| Rung | Optimisation event | Move up when the previous rung delivers | Expected at $25/day Android, $2 CPI |
|---|---|---|---|
| 1 | App installs | start here | about 12 installs/day, 85/week |
| 2 | CompleteRegistration | 50+/week for two weeks | needs a 60% sign-up rate; today most installs never sign up, so this rung may be skipped |
| 3 | StartTrial | 50+/week (plan), 25 as floor | at 4% of installs: 3 to 4/week, so not within the first month at this budget; at 8%: 7/week |
| 4 | Purchase, count | 10+/week | months away at this budget |
| 5 | Purchase, value | 30 purchases, 5 distinct values, 14 days | the destination; realistic only after the trial rate is fixed or the budget is 5 to 10 times larger |

Two honest readings of that table. First, at $25 a day the campaign will
sit on installs for a long time, and the quality of those installs is
decided by the creative and the store page, not by the bid. Second, rung 3
arrives sooner by raising the trial rate than by raising the budget: at
today's 0.4% no budget under $1,000 a day reaches it.

Interim rungs if sign-up rate stays low: map `trip_created` to a standard
event with volume. Meta's `fb_mobile_achievement_unlocked` or
`fb_mobile_level_achieved` are the usual stand-ins for "activated" and are
selectable in Advantage+ app campaigns, whereas a custom `TripCreated` may
not be. This is a one-line change in `ads_event_map.dart` and one line in
the policy's event list; the meaning sent to Meta does not change.

### 5.4 Campaign structure for the first eight weeks

- One Advantage+ app campaign, Android, installs objective, campaign
  budget $20 to $30 a day, 7-day click and 1-day view attribution. No edits
  for seven days after any change.
- One ad set, broad, 18 to 54, one language. Countries: start with the
  English-speaking tier where $79.99 a year is a normal price (United
  States, United Kingdom, Canada, Australia, Singapore). Cheaper countries
  give more installs per dollar and almost no trials at this price; they
  teach Meta the wrong person. Add a second ad set for a cheaper tier only
  when the first has exited learning.
- Three to five vertical videos from the UGC reel pipeline, one hypothesis
  each: "messy day into order" (the map doing the work in the first two
  seconds), "pay once", "7-day free trial", "share the plan with the
  group". Replace the bottom performer every two weeks.
- Kill rules from the playbook stand: creative below 0.8% click-through
  after 3,000 impressions; ad set at twice the target cost per install
  after $50.
- Exclude existing users with an app-activity audience once events flow.
- Read results in three places and trust none alone: Ads Manager, Play
  Console installs by source, RevenueCat charts segmented by the
  attribution fields the integration writes.

### 5.5 iOS, when it starts

- A second Advantage+ app campaign for iOS 14.5+. Meta reports it through
  SKAdNetwork and Aggregated Event Measurement; expect a one- to three-day
  lag and coarse data after the first 24 to 48 hours.
- Configure the SKAdNetwork conversion schema in Events Manager before
  the first impression. Without a measurement partner, Meta's own schema
  tool is the only place to do it. Keep it to a few segments: window 1 fine
  values ordered CompleteRegistration < TripCreated < StartTrial < Purchase
  with revenue buckets; coarse values low = registered or trip, medium =
  trial started, high = paid. Windows 2 and 3 only return coarse values, and
  that is where a 7-day trial converts, so "high" in window 2 is the
  trial-to-paid signal.
- The App Tracking Transparency prompt is in the build. Expect roughly a
  quarter of people to allow; the rest are measured in aggregate only. The
  consent pre-screen already explains the purpose, which is what moves the
  rate.
- Apple Ads in parallel, not instead: search placement on "trip planner",
  "itinerary planner", "route planner", "road trip planner" and brand
  terms, cost-per-tap bidding, small daily cap. RevenueCat's Apple Ads
  attribution is already wired and gated on the ads-measurement choice, so
  trial and revenue by keyword show up in RevenueCat without extra code.
  The travel-category median cost per install there is about $3.70 and
  day-7 retention is typically higher than social installs because the
  person was searching for the thing.

## 6. What has to be true before the first dollar

1. The v1.11.0 build (Meta SDK, consent, ATT) is tagged and live in both
   stores. The still-open items from the playbook: the Android trial and
   lifetime sandbox purchase check, and the Meta-side console steps (link
   the app to the dataset, SKAdNetwork config, ad account access, payment
   method).
2. `StartTrial`, `Subscribe` and `fb_mobile_purchase` have each been seen
   once in Events Manager from a sandbox purchase, on each platform.
3. RevenueCat → Meta Conversions API switched on with the production and
   sandbox dataset ids and the client token, the identifier calls added for
   consenting users, and the client-side `StartTrial`/`Subscribe` sends
   removed (section 5.2). Policy paragraph published first.
4. A target written down: cost per trial under $50 and cost per payer
   under $120 within 60 days, or the campaign pauses while the paywall is
   worked on. Those numbers are the travel-median case from section 3 and
   are the point at which the yearly plan pays back inside two renewals.

## 7. Things not to do

- Do not optimise for `Subscribe` or `fb_mobile_purchase` on day one. The
  ad set will never leave learning and the cost per install will be worse
  than the installs campaign.
- Do not run a "lifetime" campaign and a "subscription" campaign. Same
  audience, half the events each.
- Do not change the yearly price to chase the $20 category median because
  of the ads. Lower price raises the trial rate but lowers the value Meta
  learns on; test it as a paywall experiment with its own cohort first.
- Do not turn on the Meta SDK's automatic purchase logging to "get purchase
  events faster". It would double count against the app's and RevenueCat's
  events, and the playbook keeps it off for consent reasons.
- Do not judge the campaign on 7-day ROAS. Travel converts late; read 30-
  and 60-day cohorts from RevenueCat.

## 8. Later options worth knowing about

- **Web-to-app funnel.** Ads land on a short quiz page, payment happens on
  the web, the app opens already subscribed. Attribution is deterministic
  (no SKAdNetwork), and store commission is avoided on those sales.
  RevenueCat Funnels is in public beta with a Meta integration. This is
  the route many subscription apps took in 2025 and 2026 to make iOS ads
  measurable; it needs a landing site, which `voyza_landing` already is.
- **Google App Campaigns** once there are 30 or more conversions a month.
  Conversions were imported from Firebase in July; Firebase Analytics is
  now off until the person allows usage analytics, so the Google source is
  thinner than it was. Play's codeless conversions (installs and in-app
  purchases through Play billing) do not need Firebase and are the fallback
  for Android.
- **TikTok** when there are proven creatives and a budget above about
  $1,000 a month: cheaper installs, lower trial-to-paid.

## Sources

- Meta, Advantage+ app campaigns (objectives, custom events, no audience or
  placement control, SKAdNetwork campaigns):
  https://developers.facebook.com/documentation/app-ads/advantage-app-campaigns
- Meta, optimising your app ad (installs, app events, value; custom events
  only in the App Installs objective):
  https://developers.facebook.com/documentation/app-ads/optimizing-your-app-ad
- Meta, Conversions API for app events and event deduplication by
  `event_id`: https://developers.facebook.com/docs/marketing-api/conversions-api/app-events
- RevenueCat, Meta Ads integration (event mapping, identifiers, remove
  client-side purchase tracking, sandbox):
  https://www.revenuecat.com/docs/integrations/attribution/meta-ads
- RevenueCat, State of Subscription Apps 2026, travel:
  https://www.revenuecat.com/state-of-subscription-apps-2026-travel
- Value-optimisation eligibility (30 purchase events with 5 distinct
  values in 14 days; 100 for other events):
  https://www.jonloomer.com/qvt/new-requirements-for-value-optimization/
- Learning-phase thresholds lowered to 10 for purchase and app-install
  ad sets (June 2024) and 25 for most others:
  https://madgicx.com/blog/meta-lowers-learning-phase-requirement-for-select-campaigns
- Advantage+ app campaign setup and "deepest event you can feed" guidance:
  https://thesocialoutline.com/blog/advantage-plus-app-campaigns ,
  https://adlibrary.com/posts/meta-ads-for-app-install-campaigns ,
  https://semnexus.com/meta-ads-for-app-installs-the-2026-founder-playbook
- SKAdNetwork 4 conversion schemas for subscription apps:
  https://apphud.com/blog/skadnetwork-4-for-subscription-apps ,
  https://dataseat.com/blog/skan4-subscription-apps ,
  https://docs.linkrunner.io/features/meta-skan-setup
- Cost-per-install benchmarks 2026 by channel and category:
  https://www.apptweak.com/en/aso-blog/apple-ads-benchmarks ,
  https://semnexus.com/cpi-benchmarks-app-category-platform-2026 ,
  https://findclout.com/blog/cost-per-install-by-channel-2026
- Apple Ads in 2026 (placements, Advanced campaigns for subscription
  revenue): https://adapty.io/blog/apple-search-ads/
- Google App Campaigns bidding and target ROAS prerequisites:
  https://support.google.com/google-ads/answer/7100895 ,
  https://support.google.com/google-ads/answer/15995101
- Meta AEM versus SKAdNetwork on iOS:
  https://segwise.ai/blog/meta-aem-vs-skan-2025-ios-attribution.md
- TikTok versus Instagram Reels for app installs and trial conversion:
  https://admetrics.io/en/post/tiktok-ads-costs-complete-2026-pricing-guide
- Web-to-app funnels: https://www.revenuecat.com/blog/growth/web-to-app-funnels ,
  https://www.revenuecat.com/blog/company/funnels-public-beta
- Lifetime versus subscription paywall testing:
  https://superwall.com/solutions/lifetime-or-no-lifetime ,
  https://appsops.store/blog/ios-annual-vs-lifetime-purchase-pricing
