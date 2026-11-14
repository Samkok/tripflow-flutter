// Supabase Edge Function: email-unsubscribe
//
// Called from the unsubscribe page (voyza.xtremon.com/unsubscribe) and by
// mail apps' one-click "Unsubscribe" button (List-Unsubscribe-Post). Puts
// the address behind the token on public.email_suppressions; lifecycle
// emails and trip invitations skip suppressed addresses.
//
// verify_jwt = false (supabase/config.toml): mail providers and a signed-out
// browser call it without a session. The 256-bit random token is the
// credential, and it can only ever unsubscribe, never read anything.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.0";
import { handleUnsubscribe } from "./handler.ts";

const db = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

Deno.serve((req) =>
  handleUnsubscribe(req, {
    async lookup(token) {
      const { data, error } = await db
        .from("email_unsubscribe_tokens")
        .select("email")
        .eq("token", token)
        .maybeSingle();
      if (error) throw new Error(error.message);
      return (data?.email as string | undefined) ?? null;
    },
    async suppress(email, source) {
      const { error } = await db
        .from("email_suppressions")
        .upsert({ email, source }, { onConflict: "email", ignoreDuplicates: true });
      if (error) throw new Error(error.message);
    },
  })
);
