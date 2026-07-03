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

## Done when

- `https://voyza.xtremon.com/r/VOYZA-TEST12` renders with the code `VOYZA-TEST12`
- "Copy code" works on iOS Safari and Android Chrome
- Both store buttons resolve (App Store link is live; Play link once the app is published)
