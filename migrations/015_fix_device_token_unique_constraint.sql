-- Migration 015: Change device_tokens unique constraint from (fcm_token) to (user_id, fcm_token)
--
-- Problem: fcm_token was declared GLOBALLY unique (one row per physical device across ALL users).
-- When User A logs out and User B logs in on the same device, User B's INSERT hits a unique
-- violation because User A's token row still exists — or the RPC workaround hits RLS.
--
-- Fix: Bind the token to the USER ACCOUNT, not just the device.
-- UNIQUE(user_id, fcm_token) means each user has their own row per device.
-- User B's INSERT uses a different user_id, so there is no conflict with User A's row.
-- User A's row is cleaned up by deregisterToken() on logout (DELETE by fcm_token + RLS).
--
-- Also drops the now-unnecessary claim_device_token RPC.

-- 1. Drop the old global unique constraint on fcm_token
ALTER TABLE public.device_tokens
  DROP CONSTRAINT IF EXISTS device_tokens_fcm_token_key;

-- 2. Add the correct per-user unique constraint
ALTER TABLE public.device_tokens
  ADD CONSTRAINT device_tokens_user_fcm_unique UNIQUE (user_id, fcm_token);

-- 3. Drop the claim_device_token RPC — no longer needed
DROP FUNCTION IF EXISTS public.claim_device_token(text, text);

-- Rollback hint:
-- ALTER TABLE public.device_tokens DROP CONSTRAINT IF EXISTS device_tokens_user_fcm_unique;
-- ALTER TABLE public.device_tokens ADD CONSTRAINT device_tokens_fcm_token_key UNIQUE (fcm_token);
