// Supabase Edge Function: Public Trip Page (verify_jwt: false — like the
// store webhooks; the unguessable trip_shares token IS the auth).
//
// GET ?t={token} → a wall-free, read-only HTML itinerary for a shared trip:
// the recipient gets real value with NO account wall (Contagious A9), the
// page carries OG tags so the link unfurls with a real map preview in chat
// apps (behavioral residue + attribution), and the only CTA is "plan your
// own" → the store listing.
//
// og:image uses the Google STATIC MAPS API — the URL itself is the image, no
// server-side rendering. Requires the MAPS_STATIC_KEY secret (a key enabled
// for the Static Maps API and safe to expose in URLs — restrict it to that
// API); if unset the page still works, just without the map preview.

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);
const MAPS_KEY = Deno.env.get("MAPS_STATIC_KEY") ?? "";

const APPSTORE_URL = "https://apps.apple.com/app/id6758559163";
const PLAY_URL =
  "https://play.google.com/store/apps/details?id=com.superiordev.voyza";

function esc(s: string): string {
  return s.replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[
      c
    ] ?? c)
  );
}

function staticMapUrl(
  points: { lat: number; lng: number }[],
): string | null {
  if (!MAPS_KEY || points.length === 0) return null;
  // Markers only (labels 1-9 then plain) — the optimized ORDER isn't
  // persisted server-side, so we show the stops honestly, not a sequence.
  const markers = points
    .slice(0, 20) // static-maps URL length guard
    .map((p, i) =>
      `markers=color:0x00D4FF%7Clabel:${i < 9 ? i + 1 : ""}%7C${
        p.lat.toFixed(5)
      },${p.lng.toFixed(5)}`
    )
    .join("&");
  return `https://maps.googleapis.com/maps/api/staticmap?size=640x336&scale=2&${markers}&key=${MAPS_KEY}`;
}

function notFound(): Response {
  return new Response(
    "<!doctype html><meta charset=utf-8><title>VoyZa</title><body style='font-family:sans-serif;padding:40px'><h1>Link not available</h1><p>This trip link was revoked or never existed.</p>",
    { status: 404, headers: { "content-type": "text/html; charset=utf-8" } },
  );
}

serve(async (req) => {
  try {
    const url = new URL(req.url);
    const token = url.searchParams.get("t") ?? "";
    // Token shape gate before touching the DB.
    if (!/^[0-9a-f]{32,80}$/.test(token)) return notFound();

    const { data: share } = await supabase
      .from("trip_shares")
      .select("trip_id, revoked_at")
      .eq("token", token)
      .maybeSingle();
    if (!share || share.revoked_at) return notFound();

    const { data: trip } = await supabase
      .from("trips")
      .select("id, name, start_date, end_date, country_code")
      .eq("id", share.trip_id)
      .maybeSingle();
    if (!trip) return notFound();

    const { data: locations } = await supabase
      .from("locations")
      .select("name, lat, lng, scheduled_date, is_skipped")
      .eq("trip_id", trip.id)
      .order("scheduled_date", { ascending: true })
      .order("created_at", { ascending: true });

    const stops = (locations ?? []).filter((l) => !l.is_skipped);
    const title = `${trip.name} — ${stops.length} stops, planned with VoyZa`;
    const desc =
      `A route-optimized itinerary. VoyZa puts your stops in the smartest order so you see more and backtrack less.`;
    const ogImage = staticMapUrl(
      stops.map((s) => ({ lat: s.lat as number, lng: s.lng as number })),
    );

    // Group stops by day for the list.
    const byDay = new Map<string, string[]>();
    for (const s of stops) {
      const day = s.scheduled_date
        ? new Date(s.scheduled_date as string).toISOString().slice(0, 10)
        : "Unscheduled";
      if (!byDay.has(day)) byDay.set(day, []);
      byDay.get(day)!.push(s.name as string);
    }
    const daysHtml = [...byDay.entries()]
      .map(([day, names]) =>
        `<h3 style="margin:20px 0 8px;color:#16202b">${esc(day)}</h3><ol style="margin:0;padding-left:22px;color:#46535f;line-height:1.7">` +
        names.map((n) => `<li>${esc(n)}</li>`).join("") + `</ol>`
      )
      .join("");

    const html = `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc(title)}</title>
<meta property="og:title" content="${esc(title)}">
<meta property="og:description" content="${esc(desc)}">
${ogImage ? `<meta property="og:image" content="${esc(ogImage)}">` : ""}
<meta property="og:type" content="website">
<meta name="twitter:card" content="summary_large_image">
</head>
<body style="margin:0;font-family:-apple-system,'Segoe UI',Roboto,sans-serif;background:#f4f6f8">
<div style="max-width:560px;margin:0 auto;padding:24px 16px">
  <div style="background:#fff;border-radius:16px;overflow:hidden;border:1px solid #e6e9ee">
    <div style="background:linear-gradient(135deg,#2B1D70,#2E5BD0 60%,#15BFB6);padding:22px 24px;color:#fff;font-weight:800;font-size:20px">VoyZa</div>
    <div style="padding:24px">
      <h1 style="margin:0 0 6px;font-size:24px;color:#16202b">${esc(trip.name as string)}</h1>
      <p style="margin:0 0 4px;color:#46535f">${stops.length} stops · planned & route-optimized with VoyZa</p>
      ${ogImage ? `<img src="${esc(ogImage)}" alt="Map of the stops" style="width:100%;border-radius:12px;margin:14px 0">` : ""}
      ${daysHtml}
      <div style="margin-top:26px;padding-top:18px;border-top:1px solid #eef1f4">
        <p style="margin:0 0 12px;color:#46535f">Planning your own trip? VoyZa puts your stops in the smartest order — see more, backtrack less.</p>
        <a href="${APPSTORE_URL}" style="display:inline-block;background:#00D4FF;color:#04222b;font-weight:700;padding:12px 18px;border-radius:12px;text-decoration:none;margin-right:8px">Get VoyZa for iPhone</a>
        <a href="${PLAY_URL}" style="display:inline-block;color:#2E5BD0;font-weight:600;padding:12px 6px;text-decoration:none">Android →</a>
      </div>
    </div>
    <div style="padding:14px 24px;color:#9aa4ad;font-size:12px;border-top:1px solid #eef1f4">VoyZa · voyza.xtremon.com</div>
  </div>
</div>
</body></html>`;

    return new Response(html, {
      headers: {
        "content-type": "text/html; charset=utf-8",
        // Short public cache: fine for a read-only page, keeps revocation
        // reasonably fresh.
        "cache-control": "public, max-age=300",
      },
    });
  } catch (e) {
    console.error("public-trip error:", e);
    return notFound();
  }
});
