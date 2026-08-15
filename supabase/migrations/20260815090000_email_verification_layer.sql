-- ─────────────────────────────────────────────────────────────────────────
-- OWN email-verification layer (6-digit codes via Resend).
--
-- Context: the dashboard's "Confirm email" toggle is now OFF (owner call,
-- Aug 2026) so signups get a session immediately — but gotrue then
-- AUTO-STAMPS email_confirmed_at at signup (verified live), which makes
-- the built-in flag meaningless as proof of inbox ownership and reopens
-- the email-squat vector on every email-keyed feature (claim-invites,
-- referral rewards, invite sending, collaborator matching).
--
-- This migration moves "verified" to a flag WE control:
--   • user_profiles.email_verified_at — set only by verify-email-otp after
--     a correct code; backfilled for everyone who genuinely clicked a
--     confirmation link in the old regime (safe: zero signups exist after
--     2026-08-12, so every current email_confirmed_at predates the toggle);
--   • email_otp_codes / email_otp_sends — hashed one-time codes + send
--     rate-limiting, service-role only (RLS on, zero policies);
--   • gates: get_user_id_by_email matches VERIFIED users only (a squatter
--     holding someone else's address can't be attached to trips), and
--     create_pending_trip_invite requires a verified inviter (spam
--     control). The edge-function gates (claim-invites, redeem-referral,
--     send-invite-email) ship in the same release.
-- ─────────────────────────────────────────────────────────────────────────

alter table public.user_profiles
  add column if not exists email_verified_at timestamptz;

update public.user_profiles p
set email_verified_at = u.email_confirmed_at
from auth.users u
where u.id = p.user_id
  and u.email_confirmed_at is not null
  and p.email_verified_at is null;

-- Single source of truth for "has this uid proven its inbox".
create or replace function public.is_email_verified(uid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists(
    select 1 from public.user_profiles
    where user_id = uid and email_verified_at is not null
  );
$$;

-- ── OTP storage ──────────────────────────────────────────────────────────

create table public.email_otp_codes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  purpose text not null check (purpose in ('verify', 'email_change')),
  -- The address being PROVEN: current email for 'verify', the new address
  -- for 'email_change'.
  target_email text not null,
  code_hash text not null,
  attempts integer not null default 0,
  consumed_at timestamptz,
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);
create index email_otp_codes_user_purpose_idx
  on public.email_otp_codes (user_id, purpose, created_at desc);
alter table public.email_otp_codes enable row level security;

create table public.email_otp_sends (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  sent_at timestamptz not null default now()
);
create index email_otp_sends_user_idx
  on public.email_otp_sends (user_id, sent_at desc);
alter table public.email_otp_sends enable row level security;

-- ── Gates ────────────────────────────────────────────────────────────────

-- Collaborator matching: only verified users are matchable by email. An
-- unverified (possibly squatted) account resolves to NULL, which routes the
-- inviter down the pending-invite path — the email lands in the REAL inbox,
-- and claiming it requires a verified account.
create or replace function public.get_user_id_by_email(user_email text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  found_user_id uuid;
begin
  select u.id into found_user_id
  from auth.users u
  join public.user_profiles p on p.user_id = u.id
  where lower(u.email) = lower(trim(user_email))
    and p.email_verified_at is not null;
  return found_user_id;
end;
$$;

-- Inviting requires a verified sender (pending invites trigger real emails
-- via send-invite-email — unverified throwaway accounts don't get a relay).
create or replace function public.create_pending_trip_invite(
  p_trip_id uuid,
  p_email text,
  p_permission text default 'read'::text
)
returns text
language plpgsql
security definer
set search_path to 'public'
as $function$
DECLARE
  v_caller uuid := auth.uid();
  v_email text := lower(trim(p_email));
  v_code text;
  v_can_write boolean;
BEGIN
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;
  IF NOT public.is_email_verified(v_caller) THEN
    RAISE EXCEPTION 'email_unverified';
  END IF;
  IF v_email IS NULL OR v_email = '' THEN
    RAISE EXCEPTION 'email is required';
  END IF;
  IF p_permission NOT IN ('read', 'write') THEN
    RAISE EXCEPTION 'invalid permission';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM public.trips t
    WHERE t.id = p_trip_id AND t.user_id = v_caller
    UNION
    SELECT 1 FROM public.trip_collaborators c
    WHERE c.trip_id = p_trip_id AND c.user_id = v_caller AND c.permission = 'write'
  ) INTO v_can_write;
  IF NOT v_can_write THEN
    RAISE EXCEPTION 'no write access to this trip';
  END IF;

  v_code := public.get_or_create_referral_code();

  INSERT INTO public.pending_trip_invites
    (trip_id, email, permission, invited_by, referral_code)
  VALUES (p_trip_id, v_email, p_permission, v_caller, v_code)
  ON CONFLICT (trip_id, email) DO UPDATE
    SET permission = EXCLUDED.permission,
        invited_by = EXCLUDED.invited_by,
        referral_code = EXCLUDED.referral_code,
        expires_at = now() + interval '30 days';

  RETURN v_code;
END;
$function$;
