// Supabase Edge Function: Trip-Date Nudges.
// Cron-driven (daily): closes the habit loop for an episodic product by firing
// owned triggers off the user's OWN trip dates (Hooked: the next trigger is
// loaded by the user's investment — their trip):
//   pre_trip  (start_date - 2d): "add your last places, we'll order your day"
//   day_of    (each trip day with stops): "your N stops for today are ready"
//   post_trip (end_date + 1d): "how was it? plan the next one"
//
// Delivery: INSERT into public.notifications — the existing DB webhook →
// send-push-notification function pushes it via FCM, and the row doubles as
// the in-app notification. One nudge per (trip, stage) ever, deduped via
// public.trip_nudges_sent (day_of stages carry the date). Copy always names
// the user's trip/content, never "come back!" (autonomy — H4).
//
// Auth: verify_jwt + in-function service_role check (cron calls with the
// vault service key). Supports ?dryRun=1 (report, no writes).

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

function jwtRole(authHeader: string): string | null {
  const token = authHeader.replace(/^Bearer\s+/i, "");
  const parts = token.split(".");
  if (parts.length !== 3) return null;
  try {
    const b64 = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    const pad = b64.length % 4 ? "=".repeat(4 - (b64.length % 4)) : "";
    return (JSON.parse(atob(b64 + pad)).role as string) ?? null;
  } catch {
    return null;
  }
}

/** UTC date-only ISO (YYYY-MM-DD). */
function dayIso(d: Date): string {
  return d.toISOString().slice(0, 10);
}
function addDays(d: Date, n: number): Date {
  const r = new Date(d);
  r.setUTCDate(r.getUTCDate() + n);
  return r;
}

interface TripRow {
  id: string;
  user_id: string;
  name: string;
  start_date: string | null;
  end_date: string | null;
}

interface Nudge {
  tripId: string;
  userId: string;
  stage: string;
  title: string;
  body: string;
}

serve(async (req) => {
  const role = jwtRole(req.headers.get("Authorization") ?? "");
  if (role !== "service_role") {
    return new Response(JSON.stringify({ error: "forbidden" }), {
      status: 403,
      headers: { "content-type": "application/json" },
    });
  }

  const url = new URL(req.url);
  const dryRun = url.searchParams.get("dryRun") === "1";

  const now = new Date();
  const today = dayIso(now);
  const inTwoDays = dayIso(addDays(now, 2));
  const yesterday = dayIso(addDays(now, -1));

  try {
    // Trips whose window makes any stage possible today. Dates are stored as
    // timestamptz; compare on the UTC date part.
    const { data: trips, error } = await supabase
      .from("trips")
      .select("id, user_id, name, start_date, end_date")
      .not("start_date", "is", null)
      .gte("end_date", addDays(now, -2).toISOString())
      .lte("start_date", addDays(now, 3).toISOString());
    if (error) throw error;

    const candidates: Nudge[] = [];
    for (const t of (trips ?? []) as TripRow[]) {
      if (!t.start_date || !t.end_date) continue;
      const start = dayIso(new Date(t.start_date));
      const end = dayIso(new Date(t.end_date));
      const name = (t.name ?? "your trip").trim();

      if (start === inTwoDays) {
        candidates.push({
          tripId: t.id,
          userId: t.user_id,
          stage: "pre_trip",
          title: `${name} is in 2 days ✈️`,
          body:
            "Add your last places and VoyZa will put your days in the smartest order.",
        });
      }

      if (start <= today && today <= end) {
        // Only nudge days that actually have stops planned.
        const { count } = await supabase
          .from("locations")
          .select("id", { count: "exact", head: true })
          .eq("trip_id", t.id)
          .eq("is_skipped", false)
          .gte("scheduled_date", `${today}T00:00:00Z`)
          .lt("scheduled_date", `${dayIso(addDays(now, 1))}T00:00:00Z`);
        if ((count ?? 0) > 0) {
          candidates.push({
            tripId: t.id,
            userId: t.user_id,
            stage: `day_of:${today}`,
            title: `Today on ${name} 🗺️`,
            body:
              `Your ${count} ${count === 1 ? "stop" : "stops"} for today ` +
              "are ready — open VoyZa for the smartest order.",
          });
        }
      }

      if (end === yesterday) {
        candidates.push({
          tripId: t.id,
          userId: t.user_id,
          stage: "post_trip",
          title: `How was ${name}?`,
          body:
            "Plan your next trip while it's fresh — save a few places and VoyZa maps the smartest route.",
        });
      }
    }

    // Dedupe against the ledger.
    const sent: Nudge[] = [];
    for (const n of candidates) {
      const { data: prior } = await supabase
        .from("trip_nudges_sent")
        .select("stage")
        .eq("trip_id", n.tripId)
        .eq("stage", n.stage)
        .maybeSingle();
      if (prior) continue;
      sent.push(n);
    }

    if (!dryRun) {
      for (const n of sent) {
        // The notifications INSERT is the delivery: the existing DB webhook →
        // send-push-notification function fans it out to the user's devices.
        const { error: insErr } = await supabase.from("notifications").insert({
          user_id: n.userId,
          type: "trip_nudge",
          title: n.title,
          body: n.body,
          data: { trip_id: n.tripId, stage: n.stage },
        });
        if (insErr) {
          console.error(`notify failed for trip ${n.tripId}: ${insErr.message}`);
          continue; // don't ledger a failed send
        }
        await supabase
          .from("trip_nudges_sent")
          .insert({ trip_id: n.tripId, stage: n.stage });
      }
    }

    return new Response(
      JSON.stringify({
        ok: true,
        dryRun,
        today,
        considered: candidates.length,
        sent: dryRun ? 0 : sent.length,
        stages: sent.map((n) => `${n.tripId}:${n.stage}`),
      }),
      { headers: { "content-type": "application/json" } },
    );
  } catch (e) {
    console.error("trip-date-nudges error:", e);
    return new Response(JSON.stringify({ ok: false, error: String(e) }), {
      status: 500,
      headers: { "content-type": "application/json" },
    });
  }
});
