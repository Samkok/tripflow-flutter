// deno test --allow-env supabase/functions/tests/email_unsubscribe_test.ts
import {
  assert,
  assertEquals,
  assertStringIncludes,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  commercialFooterHtml,
  isTokenShape,
  randomToken,
  unsubscribeHeaders,
} from "../_shared/email_unsubscribe.ts";
import { handleUnsubscribe } from "../email-unsubscribe/handler.ts";

const FN = "https://x.supabase.co/functions/v1/email-unsubscribe";

function fakeDeps(known: Record<string, string>) {
  const suppressed: Array<[string, string]> = [];
  return {
    suppressed,
    deps: {
      lookup: (t: string) => Promise.resolve(known[t] ?? null),
      suppress: (email: string, source: string) => {
        suppressed.push([email, source]);
        return Promise.resolve();
      },
    },
  };
}

Deno.test("tokens are long, random and URL-safe", () => {
  const a = randomToken(), b = randomToken();
  assert(a !== b);
  assert(isTokenShape(a), a);
  assertEquals(a.length, 43);
});

Deno.test("a GET never unsubscribes: it sends the browser to the page", async () => {
  const t = randomToken();
  const { suppressed, deps } = fakeDeps({ [t]: "a@b.com" });
  const res = await handleUnsubscribe(new Request(`${FN}?t=${t}`), deps);
  assertEquals(res.status, 302);
  assertEquals(
    res.headers.get("Location"),
    `https://voyza.xtremon.com/unsubscribe?t=${t}`,
  );
  assertEquals(suppressed.length, 0);
});

Deno.test("one-click POST from a mail app unsubscribes", async () => {
  const t = randomToken();
  const { suppressed, deps } = fakeDeps({ [t]: "a@b.com" });
  const res = await handleUnsubscribe(
    new Request(`${FN}?t=${t}`, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: "List-Unsubscribe=One-Click",
    }),
    deps,
  );
  assertEquals(res.status, 200);
  assertEquals(suppressed, [["a@b.com", "one_click"]]);
});

Deno.test("the page's JSON POST unsubscribes and allows the site origin", async () => {
  const t = randomToken();
  const { suppressed, deps } = fakeDeps({ [t]: "a@b.com" });
  const res = await handleUnsubscribe(
    new Request(FN, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ t }),
    }),
    deps,
  );
  assertEquals(res.status, 200);
  assertEquals((await res.json()).ok, true);
  assertEquals(res.headers.get("Access-Control-Allow-Origin"), "https://voyza.xtremon.com");
  assertEquals(suppressed, [["a@b.com", "page"]]);
});

Deno.test("unknown and malformed tokens change nothing", async () => {
  const { suppressed, deps } = fakeDeps({});
  const unknown = await handleUnsubscribe(
    new Request(`${FN}?t=${randomToken()}`, { method: "POST" }),
    deps,
  );
  assertEquals(unknown.status, 404);
  const bad = await handleUnsubscribe(
    new Request(`${FN}?t=short`, { method: "POST" }),
    deps,
  );
  assertEquals(bad.status, 400);
  assertEquals(suppressed.length, 0);
});

Deno.test("the browser preflight is answered", async () => {
  const res = await handleUnsubscribe(new Request(FN, { method: "OPTIONS" }), fakeDeps({}).deps);
  assertEquals(res.status, 204);
  assertStringIncludes(res.headers.get("Access-Control-Allow-Methods") ?? "", "POST");
});

Deno.test("a database failure is a 500, not a silent success", async () => {
  const t = randomToken();
  const res = await handleUnsubscribe(
    new Request(`${FN}?t=${t}`, { method: "POST" }),
    {
      lookup: () => Promise.reject(new Error("down")),
      suppress: () => Promise.resolve(),
    },
  );
  assertEquals(res.status, 500);
});

Deno.test("headers ask mail apps for one-click unsubscribe", () => {
  const t = randomToken();
  const h = unsubscribeHeaders(t);
  assertStringIncludes(h["List-Unsubscribe"], `/functions/v1/email-unsubscribe?t=${t}>`);
  assert(h["List-Unsubscribe"].startsWith("<https://") || h["List-Unsubscribe"].startsWith("</functions"));
  assertEquals(h["List-Unsubscribe-Post"], "List-Unsubscribe=One-Click");
});

Deno.test("footer: reason, link, sender and the escaped postal address", () => {
  const t = randomToken();
  Deno.env.set("EMAIL_POSTAL_ADDRESS", "No. 1 <Street>, Phnom Penh");
  const html = commercialFooterHtml(t, "you have a VoyZa account");
  assertStringIncludes(html, "You're getting this email because you have a VoyZa account.");
  assertStringIncludes(html, `https://voyza.xtremon.com/unsubscribe?t=${t}`);
  assertStringIncludes(html, "Kok Heng, No. 1 &lt;Street&gt;, Phnom Penh");
  assert(!html.includes("<Street>"));
});

Deno.test("footer without the secret still names the sender", () => {
  Deno.env.delete("EMAIL_POSTAL_ADDRESS");
  const html = commercialFooterHtml(randomToken(), "x");
  assertStringIncludes(html, "VoyZa · Kok Heng ·");
});
