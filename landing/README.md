# VoyZa referral landing page

`r/index.html` is the referral invite page. It's fully self-contained (inline
CSS/JS, no dependencies). Share links look like:

```
https://voyza.xtremon.com/r/VOYZA-ABC234
```

The page reads the code from the URL path, shows it in a big copyable pill,
and sends the visitor to the right store.

## Upload

Copy the `r/` folder to the voyza.xtremon.com static host **and add a rewrite**
so every `/r/{CODE}` path serves `r/index.html`:

| Host | Rule |
|---|---|
| **Netlify** | `_redirects` file: `/r/* /r/index.html 200` |
| **Vercel** | `vercel.json`: `{ "rewrites": [{ "source": "/r/:code", "destination": "/r/index.html" }] }` |
| **nginx** | `location ~ ^/r/ { try_files $uri /r/index.html; }` |
| **Apache** | `.htaccess` in `/r/`: `FallbackResource /r/index.html` |

**If your host can't rewrite paths:** the page also accepts
`https://voyza.xtremon.com/r/?c=VOYZA-ABC234`. In that case change the share
URL in [lib/services/referral_service.dart](../lib/services/referral_service.dart)
(`shareInvite`) to the `?c=` form so the two match.

## Public trip links (`/t/*`) — REQUIRED before shipping builds ≥ 2026-07-15

The app now shares branded public-itinerary links of the form
`https://voyza.xtremon.com/t/<token>` (flipped in
[lib/services/route_share_card_service.dart](../lib/services/route_share_card_service.dart),
`_brandedPublicTripBase`). The host must **server-side redirect** them to the
Supabase function — a 301/302, NOT a rewrite or JS/meta redirect, so chat
unfurlers follow it to the function's OG tags:

```
/t/<token>  →  https://dkbibfjszsohtixjxlle.supabase.co/functions/v1/public-trip?t=<token>
```

| Host | Rule |
|---|---|
| **Netlify** | ship the included [`_redirects`](_redirects) file at the site root |
| **Vercel** | `vercel.json`: `{ "redirects": [{ "source": "/t/:token", "destination": "https://dkbibfjszsohtixjxlle.supabase.co/functions/v1/public-trip?t=:token", "permanent": false }] }` |
| **Cloudflare** | Rules → Redirect Rules: wildcard `voyza.xtremon.com/t/*` → `https://dkbibfjszsohtixjxlle.supabase.co/functions/v1/public-trip?t=${1}` (302) |
| **nginx** | `location ~ ^/t/(.+)$ { return 302 https://dkbibfjszsohtixjxlle.supabase.co/functions/v1/public-trip?t=$1; }` |
| **Apache** | `.htaccess`: `RedirectMatch 302 ^/t/(.+)$ https://dkbibfjszsohtixjxlle.supabase.co/functions/v1/public-trip?t=$1` |

## Done when

- `https://voyza.xtremon.com/r/VOYZA-TEST12` renders with the code `VOYZA-TEST12`
- "Copy code" works on iOS Safari and Android Chrome
- Both store buttons resolve (App Store link is live; Play link once the app is published)
- `https://voyza.xtremon.com/t/anything` 302s to the public-trip function URL
  (test with `curl -sI` and check the `location:` header)
