-- Migration 014: Fix device token ownership transfer on user switch
--
-- Problem: When User A logs out and User B logs in on the same device,
-- the FCM token row still has user_id = User A. User B's upsert
-- (onConflict: 'fcm_token') tries to UPDATE that row, but RLS blocks it
-- because User B doesn't own User A's row. Result: User B gets no push notifications.
--
-- Fix: A SECURITY DEFINER function with row_security = off that atomically:
--   1. Deletes any existing row for this FCM token (regardless of which user owns it)
--   2. Inserts a fresh row owned by the calling user (auth.uid())
--
-- NOTE: `SET row_security = off` is required because Supabase's PostgREST layer
-- enforces RLS at the transaction level (`SET LOCAL row_security = on`), which
-- applies even inside SECURITY DEFINER functions. The function-level SET overrides
-- the transaction-level setting for the duration of the call.

CREATE OR REPLACE FUNCTION public.claim_device_token(
  p_token    text,
  p_platform text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET row_security = off
AS $$
DECLARE
  v_user_id uuid;
BEGIN
  -- Resolve the authenticated user from the JWT. Reject unauthenticated calls.
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'claim_device_token: not authenticated';
  END IF;

  -- Remove any existing row for this physical token (could belong to any user).
  -- row_security = off means this DELETE bypasses all RLS policies.
  DELETE FROM public.device_tokens
  WHERE fcm_token = p_token;

  -- Insert a fresh row owned by the calling authenticated user.
  INSERT INTO public.device_tokens (
    user_id,
    fcm_token,
    platform,
    is_active,
    updated_at
  )
  VALUES (
    v_user_id,
    p_token,
    p_platform,
    true,
    now()
  );
END;
$$;

-- Grant execute to authenticated users only
GRANT EXECUTE ON FUNCTION public.claim_device_token(text, text) TO authenticated;

-- Rollback hint:
-- DROP FUNCTION IF EXISTS public.claim_device_token(text, text);
