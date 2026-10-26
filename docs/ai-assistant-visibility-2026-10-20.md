# Getting VoyZa recommended by ChatGPT, Claude and the other assistants

Written 2026-10-20. Question from Sam: "I want the app to appear in the
answers from AI agents like ChatGPT or Claude. How to achieve that?"

## 1. How the assistants choose an app

The only large measurement specific to apps is AppTweak's May 2026 study
of 125,000+ ChatGPT answers to app-recommendation prompts (US market).
What it found:

| Where ChatGPT's citations came from | Share |
|---|---|
| App Store listing pages | 37.6% |
| Google Play listing pages | 9.6% |
| Open web (developer sites, support pages, aggregators) | 27% |
| No source at all (answered from training) | 22.6% |

Two more findings that matter for a small app:

- Positions 1 to 4 in an answer are cited 80 to 85% of the time;
  position 7 under 50%; position 8 under 25%. The lower, unsourced slots
  are where a challenger gets in first.
- The engine matches the *need described in the prompt* to the app whose
  positioning fits it best, not to category rank. AppTweak's example: a
  narrowly positioned ADHD planner outranked the category leader for an
  ADHD-planning prompt. Narrow, specific positioning wins; "best travel
  app" prompts go to incumbents.

General findings about ChatGPT citations (Ahrefs, Profound, Semrush,
seoClarity; all vendor data, directionally consistent): zero-citation
answers run between 28% and 48%; identical prompts return the same brand
list under 1% of the time; a prompt fans out into about 7 web searches;
Reddit's and Wikipedia's shares have fallen sharply during 2026 in favour
of original sources; 44% of citations come from the first 30% of a page.
Claude cites less than ChatGPT and Perplexity by design, so it is the
hardest to target directly; Perplexity cites the most and favours
fresh, structured pages.

`llms.txt`: no evidence any major assistant reads it. Harmless, not a
lever.

## 2. Where VoyZa stands today

| Surface | State |
|---|---|
| App Store page `apps.apple.com/app/id6758559163` | Live, title "VoyZa: Trip Route Planner". Not found by web search for "VoyZa trip planner", so not yet indexed, or ranked below name-alikes (VOYA, Voyage Trip Planner, voyay) |
| Google Play page | Live, likewise unindexed in search |
| Website voyza.xtremon.com | One page plus privacy and terms. No `robots.txt`, no `sitemap.xml`, no structured data. Home page says "Plan complex trips without the chaos"; the store says "See more. Walk less." Two different positionings |
| Third-party web | One Product Hunt page (February 2026, framed as "multi-stop route planner for road trips, deliveries, client visits", a third positioning). Nothing else |
| Training-data presence | None; the app is too new and too thinly described on the web |

So today an assistant that searches finds Product Hunt and a brand site
that disagree with the store listing, and an assistant that does not
search has never heard of VoyZa.

## 3. What to do, in order of leverage

### A. Fix the store listings first (half of all citations)

1. Rewrite the long description around the intents VoyZa can own, in
   plain sentences an extractor can lift: "reorders the places you saved
   into the shortest walking route", "multi-day itinerary with
   opening hours", "shared trip that syncs live with friends", "no
   account needed for the first 5 places". Lead with what and for whom
   in the first three lines (the part shown before "more").
2. Keep title and subtitle as they are; make sure the keyword field
   carries the intent phrases people type into an assistant
   ("itinerary", "day trip", "multi-stop", "walking route").
3. Pick ONE positioning sentence and use it everywhere: store, site,
   Product Hunt, press. "Reorder your saved places into one clean route
   and see more with less walking" is the store's; adopt it.

### B. Give the site something to cite (next quarter of citations)

1. `robots.txt` that allows GPTBot, ClaudeBot, PerplexityBot, Bingbot and
   Googlebot; `sitemap.xml`; submit the site to Bing Webmaster Tools and
   Google Search Console. ChatGPT search runs on Bing's index, so a site
   Bing has not crawled cannot be cited.
2. A "what / who / how" product page in plain prose with an FAQ: "What
   does VoyZa do", "Who is it for", "How is it different from Wanderlog /
   Google Maps lists / TripIt", "Does it work offline", "Is it free".
   First 30% of the page carries the answers. Add `SoftwareApplication`
   and `FAQPage` JSON-LD, and a visible "last updated" date.
3. Use-case pages, one intent each, each a few hundred words:
   "Plan a 3-day Tokyo itinerary in the right order", "Multi-stop road
   trip planner", "Plan a group trip together". These are the pages a
   fan-out search for a described need can land on.
4. Public trip pages already exist (`/t/<token>`, `/c/<code>`). Make a
   handful of curated sample itineraries public and indexable with real
   place names and a one-paragraph summary; they are exactly the kind
   of page a "3 days in Lisbon" prompt retrieves.

### C. Earn third-party mentions (what training data and fan-out searches find)

1. Get VoyZa into the "best trip planner apps" listicles that already
   rank: pitch the writers at the usual travel and tech sites with the
   one positioning sentence and a press kit page. One good listicle
   outranks fifty self-published posts.
2. Reddit and travel forums: answer real "how do I order my stops"
   questions with the method, mention the app once. Reddit's citation
   share has fallen but it still feeds training data.
3. Keep the Product Hunt page's description identical to the store's.
4. An AlternativeTo entry and a Wikidata item (software, developer,
   platform, website) cost nothing and are the structured records the
   engines resolve names against. Wikipedia itself is out of reach at
   this size.

### D. Be inside the assistants, not just cited by them

Both companies now run directories that put third-party tools inside the
chat:

- **ChatGPT apps** (submissions open since December 2025): a remote MCP
  server over HTTPS, listing metadata, privacy and terms URLs, domain
  verification, 5 positive and 3 negative test cases, a demo video. No
  in-app monetisation yet, so the ChatGPT app would be a free planner
  that hands the finished trip to the VoyZa mobile app via a share link.
- **Claude connectors directory**: a remote MCP server with tool
  annotations (`readOnlyHint` / `destructiveHint`), OAuth for
  authenticated tools, privacy policy covering data handling. Sunpeak's
  May 2026 write-up says a developer portal at claude.ai/directory/manage
  opened in September; the official docs still describe submission from a
  Team or Enterprise admin, so check which applies.

VoyZa is unusually well placed for this: the route optimiser and the
Supabase backend are already server-side, and public trip links exist.
An MCP server exposing "optimise this list of places into a day order"
and "create a shareable trip" turns VoyZa into the tool the assistant
calls when someone asks it to plan a day, with the app as the place the
plan lives afterwards. This is the one lever where a small app can be
first rather than fifth; it is a two-to-four week build.

## 4. How to measure

Pick 15 prompts in three groups and run them monthly in ChatGPT (with
search), Claude, Perplexity and Gemini, logging whether VoyZa appears,
at which position, and what is cited:

- Need-described: "I saved 12 places in Lisbon, how do I visit them in
  the best order over 3 days"
- Category: "best trip itinerary planner app iPhone"
- Comparison: "Wanderlog alternative that optimises walking routes"

Baseline before changing anything; expect the need-described group to
move first and the category group last. Identical prompts vary run to
run, so run each three times.

## 5. What not to spend on

- GEO tool subscriptions at this stage: they measure, they do not move
  anything the steps above do not.
- `llms.txt`: no engine reads it.
- Keyword-stuffed pages: the engines quote passages, so a page has to
  read as a direct answer.
- Chasing "best travel app" prompts: owned by incumbents with thousands
  of citations; VoyZa wins on the narrow intents.

## Sources

- AppTweak, which sources AI search engines cite when recommending
  mobile apps (May 2026, 125k ChatGPT answers):
  https://www.apptweak.com/en/aso-blog/which-sources-do-ai-search-engines-cite-when-recommending-mobile-apps
- AppTweak, how AI engines decide which app to recommend (positioning
  over category rank):
  https://www.apptweak.com/en/aso-blog/how-ai-engines-decide-which-app-to-recommend
- GoGoChimp, what ChatGPT actually cites in 2026 (collects Ahrefs,
  Profound, Semrush, seoClarity, SparkToro figures; vendor):
  https://www.gogochimp.com/blog/what-chatgpt-actually-cites-2026
- Everything-PR, AI citation source index 2026:
  https://everything-pr.com/ai-platform-citation-source-index-2026
- Winston Digital, how to get cited by ChatGPT in 2026:
  https://www.winstondigitalmarketing.com/playbooks/how-to-get-cited-by-chatgpt-in-2026/
- OpenAI, apps submission requirements:
  https://developers.openai.com/apps-sdk/deploy/submission and
  https://openai.com/index/developers-can-now-submit-apps-to-chatgpt/
- Anthropic, connector directory submission:
  https://claude.com/docs/connectors/building/submission
- Sunpeak, Claude connector directory submission (May 2026):
  https://sunpeak.ai/blogs/claude-connector-directory-submission
- Foresight Mobile, how AI recommends apps in 2026:
  https://foresightmobile.com/blog/how-ai-recommends-apps-2026
- AppFollow, ASO news 2026: https://appfollow.io/blog/aso-news
- GEO overviews (vendor, general):
  https://www.aimagicx.com/blog/generative-engine-optimization-chatgpt-perplexity-2026 ,
  https://www.enrichlabs.ai/blog/generative-engine-optimization-geo-complete-guide-2026
