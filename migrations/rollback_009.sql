-- Rollback for Migration 009: Remove user_subscriptions table and related objects

-- Drop policies
DROP POLICY IF EXISTS "Users can view their own subscription" ON public.user_subscriptions;
DROP POLICY IF EXISTS "Service role can insert subscriptions" ON public.user_subscriptions;
DROP POLICY IF EXISTS "Service role can update subscriptions" ON public.user_subscriptions;

-- Drop trigger
DROP TRIGGER IF EXISTS set_user_subscriptions_updated_at ON public.user_subscriptions;

-- Drop function
DROP FUNCTION IF EXISTS public.upsert_subscription_status;

-- Remove from realtime publication
ALTER PUBLICATION supabase_realtime DROP TABLE IF EXISTS public.user_subscriptions;

-- Drop indexes
DROP INDEX IF EXISTS public.user_subscriptions_user_id_idx;
DROP INDEX IF EXISTS public.user_subscriptions_status_idx;
DROP INDEX IF EXISTS public.user_subscriptions_expires_at_idx;
DROP INDEX IF EXISTS public.user_subscriptions_revenuecat_app_user_id_idx;

-- Drop table
DROP TABLE IF EXISTS public.user_subscriptions;
