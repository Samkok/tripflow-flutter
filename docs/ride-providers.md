# Ride providers by country — DRAFT for review

Status: **draft, not wired to code.** The in-map ride button is disabled
(see `optimized_map_overlay_provider.dart`, "RIDE PROVIDER BUTTON — DISABLED").

## Rules this table encodes

1. **Order matters** — first entry is the one shown/prioritised.
2. **An empty list means show nothing.** Google Maps only. Never guess a
   provider; a dead button is worse than no button (that's the bug this
   whole exercise came from: Grab offered in Hong Kong, where it doesn't
   operate).
3. **Never fall back to "just show Uber."** Uber is absent or banned in
   real destinations (Bulgaria, Hungary, mainland China, and it sold its
   SEA business to Grab).
4. Providers are shown **whether or not the app is installed** (owner
   decision, 2026-08-05); tapping an uninstalled one opens the store.

## Confidence key

- **A** — verified during research (Aug 2026) or unambiguous market fact
- **B** — well-established, worth a spot-check before shipping
- **C** — lower confidence, **verify before shipping**

---

## Southeast Asia

| Country | Providers (ordered) | Conf | Notes |
|---|---|---|---|
| Singapore | Grab, Gojek | A | Uber exited SEA in 2018 (sold to Grab) |
| Malaysia | Grab | A | |
| Indonesia | Gojek, Grab | A | Gojek is the home-market leader |
| Thailand | Grab, Bolt | B | Gojek exited Thailand |
| Vietnam | Grab, Xanh SM, Be | C | Xanh SM (EV) grew fast; verify ordering |
| Philippines | Grab, Joyride | B | |
| Cambodia | Grab, PassApp | B | PassApp is strong locally (tuk-tuk/car) |
| Myanmar | Grab | B | Check current operating status |

## East Asia

| Country | Providers | Conf | Notes |
|---|---|---|---|
| Hong Kong | Uber | A | **The bug fix.** Uber absorbed Fly Taxi; HKTaxi shut down into Uber (Feb 2025). Licensing regime lands ~Q4 2026 — recheck then |
| Japan | GO, Uber, DiDi | B | GO dominates taxi-hailing; Uber is taxi-dispatch |
| South Korea | Kakao T, Uber | A | Kakao T holds 90%+ share; Uber operates as Uber Taxi |
| Taiwan | Uber, LINE Taxi | B | |
| Mainland China | DiDi, Amap | A | **No Uber.** Amap is an aggregator |
| Macau | — | C | Thin ride-hailing market; likely Maps-only |

## South Asia

| Country | Providers | Conf | Notes |
|---|---|---|---|
| India | Uber, Ola, Rapido | A | Rapido strong for bikes/autos |
| Pakistan | Careem, inDrive, Yango | B | |
| Sri Lanka | PickMe, Uber | B | PickMe is the local leader |
| Bangladesh | Uber, Pathao | B | |
| Nepal | Pathao, inDrive | C | Verify |

## Middle East

| Country | Providers | Conf | Notes |
|---|---|---|---|
| UAE | Careem, Uber, Hala | A | Careem is Uber-owned but a separate app |
| Saudi Arabia | Uber, Careem | A | |
| Qatar / Kuwait / Bahrain / Oman | Careem, Uber | B | |
| Jordan / Lebanon / Iraq | Careem, Uber | C | Verify per country |
| Israel | Gett, Uber | C | Gett is taxi-based; verify |
| Turkey | Uber, BiTaksi | B | Uber operates via licensed taxis |

## Europe — Western

| Country | Providers | Conf | Notes |
|---|---|---|---|
| United Kingdom | Uber, Bolt, FreeNow | A | |
| Ireland | FreeNow, Uber | B | Uber = taxi dispatch only in IE |
| Germany | Uber, Bolt, FreeNow | A | Tight regulation; all three present |
| France | Uber, Bolt, G7 | B | G7 is the incumbent taxi network |
| Spain | Uber, Cabify, Bolt, FreeNow | A | Cabify is strong here |
| Portugal | Uber, Bolt, FreeNow | A | |
| Italy | FreeNow, Uber, itTaxi | B | Uber restricted (largely Uber Black) |
| Netherlands | Uber, Bolt | A | |
| Belgium | Uber, Bolt | B | |
| Switzerland | Uber, Bolt | B | |
| Austria | Uber, Bolt, FreeNow | B | |
| Greece | FreeNow, Uber | B | Both operate via taxis |

## Europe — Nordics, Central & Eastern

| Country | Providers | Conf | Notes |
|---|---|---|---|
| Sweden / Norway / Finland | Uber, Bolt | B | Coverage varies by city |
| Denmark | Bolt, Uber | C | Uber left in 2017, returned later — **verify** |
| Poland | Uber, Bolt, FreeNow | A | |
| Czechia | Uber, Bolt, Liftago | B | |
| Romania | Uber, Bolt | A | |
| **Bulgaria** | Bolt | A | **Uber banned — must not be listed** |
| **Hungary** | Bolt | A | **Uber banned — must not be listed** |
| Croatia / Slovakia / Slovenia | Bolt, Uber | B | |
| Baltics (EE/LV/LT) | Bolt | A | Bolt's home region |
| Ukraine | Bolt, Uklon, Uber | C | Wartime status — verify |
| Russia | Yandex Go | A | |
| Central Asia (KZ/UZ/KG) | Yandex Go, inDrive | B | |

## Africa

| Country | Providers | Conf | Notes |
|---|---|---|---|
| South Africa | Uber, Bolt, inDrive | A | |
| Nigeria | Bolt, Uber, inDrive | A | |
| Kenya | Bolt, Uber, Little | A | |
| Ghana / Uganda / Tanzania | Bolt, Uber | B | |
| Egypt | Uber, Careem, inDrive | A | |
| Morocco / Tunisia | Careem, inDrive, Yango | C | Verify — regulation is messy |

## Americas

| Country | Providers | Conf | Notes |
|---|---|---|---|
| United States | Uber, Lyft | A | |
| Canada | Uber, Lyft | A | |
| Mexico | Uber, DiDi, inDrive, Cabify | A | |
| Brazil | Uber, 99, inDrive | A | 99 is DiDi-owned, separate app |
| Argentina | Uber, Cabify, DiDi | B | |
| Chile / Colombia / Peru | Uber, DiDi, Cabify, inDrive | B | |
| Central America / Caribbean | Uber (spotty), inDrive | C | Very uneven — default to Maps-only |

## Oceania

| Country | Providers | Conf | Notes |
|---|---|---|---|
| Australia | Uber, DiDi, Ola, Bolt | B | |
| New Zealand | Uber, Ola, Bolt | C | Verify Bolt presence |

---

## Everything else

**No entry → no ride section.** Google Maps only. The gap is then logged
(country code, no PII) so the analytics show which countries real users
actually need, turning this into an evidence-ranked backlog instead of an
endless research task.

## Implementation notes (for when this is approved)

- **Store the table in Supabase**, with this file bundled as the offline /
  first-run fallback. Provider coverage changes constantly (Uber↔Careem,
  HKTaxi→Uber, HK licensing ~Q4 2026); fixing a row must not require an
  App Store review cycle.
- **iOS caps `LSApplicationQueriesSchemes` at 50 entries** (apps linked on
  iOS 15+), and undeclared schemes always return `false`. Detecting
  installed apps is therefore capped at ~50 — enough for every provider
  above, but a real ceiling. Android needs matching `<queries>` entries.
- Currently declared on iOS: `grab`, `comgooglemaps` only.
- Deep links to gather per provider (owner to confirm the ones we keep):
  `uber://`, `lyft://`, `grab://`, `gojek://`, `bolt://`, `free-now://`,
  `careem://`, `didi://`, `olacabs://`, `99app://`, `cabify://`,
  `indriver://`, `yandextaxi://`, `kakaot://`.

## Review checklist

- [ ] Confirm every **C** row, or drop it to "Maps only" until verified
- [ ] Confirm Bulgaria + Hungary list **no Uber**
- [ ] Decide how many providers to show per country (all, or top 2?)
- [ ] Confirm store-fallback behaviour for uninstalled apps
- [ ] Decide Supabase table vs bundled-only for v1
