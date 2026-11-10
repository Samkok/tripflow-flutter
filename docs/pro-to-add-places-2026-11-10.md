# Adding places is part of VoyZa Pro (2026-11-10)

Decided by Sam on 2026-11-10. Committed on 2026-11-10 (a19d853), not released.

## The rule

- Creating trips stays free. Adding a place opens the paywall straight away
  for anyone who is not Pro. There is no free allowance any more (it was 10).
- The rule follows the person who adds. A Pro member can add to any trip they
  can edit, whatever the owner's plan. A free editor cannot add, even on a Pro
  owner's trip.
- Existing users are cut over at once. Places they already saved stay.
- Referral bonus slots are retired. The free month for both sides stays.
- The sample trip stays free: its places are seeded without the gate.
- Still free: editing, moving, reordering, marking done, deleting, optimizing,
  sharing, one copy of a shared trip, attaching loose places to a trip.
- Needs Pro: adding by search, nearby or pasted link; copying a place to
  another day; duplicating a trip that has places; applying Auto-plan; a
  second shared-trip copy.
- Free trial: 7 days, yearly plan only. Both stores were already set up this
  way (App Store since 2026-08-25; Play offer `yearly-free-trial`). The app
  reads the offer from the store and names the plan on the paywall.

## Where it lives

- `lib/services/subscription_limit_service.dart`: `ensureCanAdd` is the one
  gate. `paywallOverride` is the test seam.
- `lib/widgets/add_place_sheet.dart`: the sheet asks at the door. A view-only
  member is let in so the sheet can explain the role.
- Tests: `test/services/subscription_limit_service_test.dart`.

## Texts changed

In-app Terms (sections 7 and 9), website Terms (5.1 and 5.4), website FAQ,
how-it-works, the three guide pages, site metadata, paywall, onboarding card,
Pro row, trial-ends sentence, referral screen, lifecycle emails, referral
notifications, outreach pitches. The privacy policy does not state the
allowance and needed no change.

## Release day, in this order

1. Deploy the edge functions `redeem-referral`, `claim-invites` and
   `lifecycle-emails` (needs Sam's go). Until then a referrer is still told
   they earned "+2 free place slots".
2. Push the website repo (`voyza_landing`). A push to `main` deploys it to
   production, so the free-plan wording waits there as a local commit.
3. Ship the build.
4. Change the store listings the day the build is live. The exact lines are
   at the end of `marketing/app-store-listing.md`. The App Store description
   can only change with a new version, so put the new text in that version.
5. Edit the Product Hunt description (it says "10 free places").

## Known gaps

- The limit was only ever enforced in the app. Older builds keep the 10 free
  places until the user updates; nothing forces an update.
- The database column `referral_bonus_places` and the function
  `increment_referral_bonus_places` stay, unused. No migration is needed.
