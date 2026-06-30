// Supabase Edge Function: Lifecycle Emails (via Resend).
// Cron-driven: emails users at funnel moments (welcome / activate / winback),
// one per user+stage, de-duped via public.lifecycle_emails_sent. Supports a
// dry-run mode (no send) and a test mode (send to one address, bypassing
// targets and the ledger). Auth: verify_jwt + in-function service_role check.

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);
const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY");
const FROM = Deno.env.get("LIFECYCLE_FROM") ?? "VoyZa <onboarding@resend.dev>";

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

const APP_URL = "https://apps.apple.com/us/app/voyza/id6758559163";

// Shared branded email layout (gradient header, body, CTA button, footer).
function layout(heading: string, bodyHtml: string, ctaText: string): string {
  const p = "margin:0 0 12px;color:#46535f;font-size:15px;line-height:1.5";
  return `<div style="background:#f4f6f8;padding:24px;font-family:-apple-system,'Segoe UI',Roboto,sans-serif">`
    + `<div style="max-width:520px;margin:0 auto;background:#fff;border-radius:16px;overflow:hidden;border:1px solid #e6e9ee">`
    + `<div style="background:linear-gradient(135deg,#2B1D70,#2E5BD0 60%,#15BFB6);padding:22px 24px;color:#fff;font-weight:800;font-size:20px">VoyZa</div>`
    + `<div style="padding:24px">`
    + `<h1 style="margin:0 0 14px;font-size:22px;color:#16202b">${heading}</h1>`
    + bodyHtml.replaceAll("<p>", `<p style="${p}">`)
    + `<a href="${APP_URL}" style="display:inline-block;margin-top:6px;background:#2E5BD0;color:#fff;text-decoration:none;font-weight:700;padding:12px 22px;border-radius:10px">${ctaText}</a>`
    + `</div>`
    + `<div style="padding:16px 24px;color:#9aa4ad;font-size:12px;border-top:1px solid #eef1f4">VoyZa · voyza.xtremon.com</div>`
    + `</div></div>`;
}

// Per-stage copy. Plain, benefit-led, mobile-first. Keep it honest.
function render(stage: string): { subject: string; html: string } | null {
  switch (stage) {
    case "welcome":
      return {
        subject: "Plan your first trip in VoyZa",
        html: layout(
          "Plan your first trip 👋",
          "<p>Welcome to VoyZa! Here's the 3-step magic that saves you hours of backtracking:</p>"
            + "<p>📍 <b>Save 3+ places</b> you want to visit</p>"
            + "<p>✨ Tap <b>Optimize</b> — we order them into the smartest route</p>"
            + "<p>🕒 <b>See more, backtrack less</b></p>",
          "Open VoyZa",
        ),
      };
    case "activate":
      return {
        subject: "You're a couple of places from a smarter route",
        html: layout(
          "You're moments from the magic ✨",
          "<p>Your trip is started — nice work. Add a few more places (3+ unlocks it) and tap <b>Optimize</b> to watch VoyZa group nearby spots and cut the backtracking.</p>",
          "Add places & optimize",
        ),
      };
    case "winback":
      return {
        subject: "Your next trip deserves a smarter route",
        html: layout(
          "Your next trip deserves a smarter route",
          "<p>Planning somewhere new? Your saved trips and places are still here. Re-open VoyZa to optimize your next multi-stop day — and start a fresh free trial of Pro.</p>",
          "Start planning",
        ),
      };
    default:
      return null;
  }
}

async function sendEmail(to: string, subject: string, html: string): Promise<boolean> {
  if (!RESEND_API_KEY) {
    console.warn("RESEND_API_KEY not set — cannot send");
    return false;
  }
  try {
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${RESEND_API_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ from: FROM, to, subject, html }),
    });
    if (!res.ok) console.warn(`Resend ${res.status}: ${await res.text()}`);
    return res.ok;
  } catch (e) {
    console.error("Resend send failed:", e);
    return false;
  }
}

serve(async (req) => {
  if (jwtRole(req.headers.get("Authorization") ?? "") !== "service_role") {
    return new Response(JSON.stringify({ error: "Forbidden" }), {
      status: 403,
      headers: { "Content-Type": "application/json" },
    });
  }

  // Dry-run env check — sends NOTHING. Reports which secrets resolve so we can
  // confirm RESEND_API_KEY / LIFECYCLE_FROM are set before going live.
  let body: Record<string, unknown> = {};
  try {
    body = await req.json();
  } catch (_) {
    // empty/no body is fine
  }
  if (body["dryRun"] === true) {
    return new Response(
      JSON.stringify({
        mode: "dryRun",
        env: {
          RESEND_API_KEY: !!RESEND_API_KEY, // boolean only — never the value
          LIFECYCLE_FROM: FROM, // effective From (env value or default)
          LIFECYCLE_FROM_from_env: Deno.env.get("LIFECYCLE_FROM") != null,
          SUPABASE_URL: !!Deno.env.get("SUPABASE_URL"),
          SUPABASE_SERVICE_ROLE_KEY: !!Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"),
        },
      }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    );
  }

  // Test mode: send the template(s) to one explicit address, bypassing the
  // target query AND the dedupe ledger. service_role-only (gated above).
  const testEmail =
    typeof body["testEmail"] === "string" ? body["testEmail"] as string : null;
  if (testEmail) {
    const stages = typeof body["stage"] === "string"
      ? [body["stage"] as string]
      : ["welcome", "activate", "winback"];
    const results: Record<string, string> = {};
    for (const stage of stages) {
      const tpl = render(stage);
      if (!tpl) {
        results[stage] = "no_template";
        continue;
      }
      const ok = await sendEmail(testEmail, `[Test] ${tpl.subject}`, tpl.html);
      results[stage] = ok ? "sent" : "failed";
    }
    return new Response(
      JSON.stringify({ mode: "test", to: testEmail, results }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    );
  }

  const summary: Record<string, number> = {
    sent: 0,
    skipped_no_template: 0,
    send_failed: 0,
    errors: 0,
  };

  try {
    // Target list (deduped, due-now) comes from the SQL function so the join
    // logic lives in one auditable place. See migration.sql.
    const { data: targets, error } = await supabase.rpc("lifecycle_email_targets");
    if (error) {
      console.error("lifecycle_email_targets failed:", error);
      return new Response(JSON.stringify({ error: "Target query failed" }), {
        status: 500,
        headers: { "Content-Type": "application/json" },
      });
    }

    for (const row of (targets ?? []) as Array<{ user_id: string; email: string; stage: string }>) {
      const tpl = render(row.stage);
      if (!tpl) {
        summary.skipped_no_template++;
        continue;
      }
      const ok = await sendEmail(row.email, tpl.subject, tpl.html);
      if (!ok) {
        summary.send_failed++;
        continue;
      }
      // Record so we never email the same (user, stage) twice.
      const { error: insErr } = await supabase
        .from("lifecycle_emails_sent")
        .insert({ user_id: row.user_id, stage: row.stage });
      if (insErr) {
        console.error(`record sent failed for ${row.user_id}/${row.stage}:`, insErr);
        summary.errors++;
      } else {
        summary.sent++;
      }
    }

    console.log("Lifecycle run complete:", summary);
    return new Response(JSON.stringify({ message: "Lifecycle run complete", summary }), {
      status: 200,
      headers: { "Content-Type": "application/json" },
    });
  } catch (e) {
    console.error("lifecycle-emails handler error:", e);
    return new Response(JSON.stringify({ error: "Internal error" }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
});
