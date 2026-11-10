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

## Rolled out on 2026-11-10

- Server functions `redeem-referral`, `claim-invites` and `lifecycle-emails`
  are deployed. No one held bonus slots, so retiring them took nothing away.
- The website is live with the new Terms and the free-plan wording. A push to
  `main` of `voyza_landing` deploys it.
- Product Hunt description edited.
- Google Play: the new last line of the description is saved as a draft. It
  goes live once the AI asset declaration on that page is answered, the
  listing is saved and the change is sent for review.
- App Store: nothing changed yet. The promotional text can change at any
  time; the description only inside a new version. The pipeline submits a
  tagged build for review straight away, with the previous description, so
  the description has to be edited on the new version before it is reviewed.
  The lines are at the end of `marketing/app-store-listing.md`.
- The build itself: not tagged.

## Old builds

Builds up to 1.11.53 keep the 10 free places. This cannot be closed well
from the server:

- A guest's places never reach the server, so no server rule can see them.
- An old build cannot say whether a row is a new place or a place saved
  earlier that is only now syncing (a guest who signs up). Builds 1.9.0 to
  1.11.53 delete a place from the device when the server refuses it, so every
  wrong guess is a lost place.
- The app stamps `created_at` in local time without an offset, so the server
  cannot tell a fresh place from one a few hours old.
- Very few signed-in users on old builds add places at all (checked against
  the database on 2026-11-10), so there is little to close.

A rule that does the safest possible version of this is written and tested
(19 cases, in-process Postgres) but NOT applied:
`supabase/manual/locations_pro_gate_old_builds.sql`. It is outside
`supabase/migrations` on purpose. Builds from this change on send the header
`x-voyza-pro-gate` and are never touched by it. Its remaining risk and the
three statements that remove it are in the file's header. If it is ever
applied, do it only once this build is live in both stores.

## Known gaps

- Older builds keep the 10 free places until the user updates; nothing
  forces an update (see "Old builds").
- The database column `referral_bonus_places` and the function
  `increment_referral_bonus_places` stay, unused. No migration is needed.
