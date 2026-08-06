-- Audit + rate-limit ledger for invite emails (send-invite-email fn).
-- Service-role only: no client policies at all — RLS enabled with no
-- policies denies everything except the service role.
CREATE TABLE IF NOT EXISTS public.invite_email_log (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  inviter_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  invite_id uuid,
  email text NOT NULL,
  sent_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS invite_email_log_rate_idx
  ON public.invite_email_log (inviter_user_id, sent_at DESC);

ALTER TABLE public.invite_email_log ENABLE ROW LEVEL SECURITY;
