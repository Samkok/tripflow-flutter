# VoyZa growth playbook (Contagious + Hooked lenses)

App-specific playbook consumed by the general `app-success-audit` skill (personal skill at `~/.claude/skills/app-success-audit/`). Product context: VoyZa (this repo) is a trip-planning app whose aha moment is the route optimizer — scattered saved places become a clean day-by-day itinerary. Activation work in place: anonymous one-tap sample trip to the optimize aha, centralized ahaThreshold, activation analytics events. Solo founder, no ad budget — word of mouth is the growth engine.

## STEPPS plays (Contagious lens)

### Social Currency
- Travel is identity-laden — people share trips to look adventurous and competent. Give them artifacts that make them look like *savvy planners*: a beautiful optimized-route map, "planned in one evening" stats, hours-saved numbers.
- Inner remarkability candidates: the optimizer's before/after (47 chaotic pins → clean 9-day route), oddly-specific findings ("an extra free afternoon in Rome").
- Game mechanics: countries/cities counters, planning streaks, "trips optimized" milestones — only if visible/shareable; private stats carry no currency.
- Insider angle: invite-gated beta features or founding-member status beats discounts.

### Triggers
- The habitat moment is **"flights booked… now what?"** — frequent, close to the action, weakly claimed. Aim content and lifecycle emails at the post-booking window.
- Secondary cues: Sunday-evening planning, payday travel dreaming, group chats deciding dates, PTO approval.
- Re-engagement notifications should reference the *trip* ("Rome in 12 days"), never the app ("come back to VoyZa" is cue-less).
- App growth is not a movie launch: optimize for ongoing triggers over launch-week spikes.

### Emotion
- High-arousal palette: **awe** (the destination, the map snapping together), **excitement** (countdown to departure), anxiety relieved and reframed as excitement ("stop worrying you're wasting your only week in Japan").
- Ban contentment vocabulary as the main pitch ("easily", "seamlessly", "hassle-free"). Sell the extra afternoon in Rome, not reduced friction.
- The optimize moment is the in-product emotional peak — share prompts, rating asks, and referral offers belong there (arousal transfers to action).

### Public
- **Shared itineraries are the behavioral residue.** Every shared trip link/PDF/image should be gorgeous, useful to the recipient, and carry visible attribution ("Planned with VoyZa" + link) — the Hotmail signature play. Highest-leverage Public mechanic available.
- Shared artifacts must render well where they land (iMessage/WhatsApp link previews, exportable image cards).
- Recipient experience: view WITHOUT an account, one-tap path to "plan yours" — the anonymous sample-trip flow is the right landing.
- Never publicize churn/abandonment norms; publicize the desired norm ("trips planned this week").

### Practical Value
- Destination-specific, narrow content ("3 mistakes that waste a day in Tokyo") — narrow beats broad; it summons the one friend planning that trip.
- The optimizer's output is itself shareable practical value — a good itinerary helps the recipient directly, which spreads better than app recommendations.
- Pricing: Rule of 100 (sub-$100 subscription → show % off); restrictions (launch-window founder pricing) amplify; avoid perpetual discounts.

### Stories
- The retellable kernel must be the optimizer: "I dumped 47 saved places in and it gave me 9 perfect days" passes the Panda test. "I had a great trip" does not.
- Amplify user stories shaped: person + planning struggle + optimizer surprise + concrete payoff. Keep the numbers — they survive retelling.
- No stunt content unrelated to planning (the Evian trap).

## Hook Model notes (Hooked lens)

- **H1 honesty — VoyZa is episodic.** Trip planning is not a daily habit; design for trip-lifecycle waves (dreaming → booked → planning → in-trip → memories) rather than faking daily engagement. Between-trip retention rides on saving/dreaming (low-friction place-saving from reels/screenshots would be the frequent behavior that keeps VoyZa in the Habit Zone).
- **Internal trigger candidates:** pre-trip anxiety ("am I wasting my only week?"), the itch when encountering a place worth saving (fear of losing the find), group-planning chaos frustration.
- **Owned triggers:** notification permission asked in context (after first optimize or first shared trip), then trip-anchored: countdowns, "X unplanned days in Rome", companion activity.
- **Action:** keep save-a-place and optimize each a minimal-step action; anonymous-first flow already matches deferred-signup doctrine (H7 ✅ by design).
- **Variable reward:** hunt (what route/discoveries will the optimizer produce; new place ideas), tribe (companions reacting to the shared plan), self (the trip filling in, days clicking into place).
- **Investment / stored value:** every saved place, note, and completed trip compounds; past trips = memories archive; preferences train future suggestions. Leaving VoyZa = abandoning your travel history.
- **Next trigger loaded:** sharing a trip to companions loads their responses; an upcoming trip loads the countdown; saved-but-unplanned places load "you have 12 saves in Tokyo — want days?".

## Measurement notes
- Instrument the share loop end-to-end: share events at the aha moment, shared-link opens, recipient → sample-trip starts, recipient → activation, `origin_share_token` attribution — natural extensions of the existing activation analytics.
- Habit Testing (identify/codify/modify): define VoyZa's habitual-user threshold per trip-lifecycle stage (not raw weekly visits), find the shared path of retained users, steer new users down it.
- Referral design, if built: social/status rewards (extended Pro, founder badge, "you both get a month") — never cash.
