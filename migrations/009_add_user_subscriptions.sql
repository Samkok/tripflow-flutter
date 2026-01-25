-- Migration 009: Add user_subscriptions table for real-time subscription tracking
-- This enables battery-efficient subscription expiration detection via Supabase Realtime
-- Replaces periodic polling with event-driven pub/sub architecture

-- ============================================================================
-- STEP 1: Create user_subscriptions table
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.user_subscriptions (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,

    -- Subscription status
    status text NOT NULL CHECK (status IN ('active', 'expired', 'grace_period', 'billing_retry', 'cancelled')),
    entitlement text NOT NULL, -- 'VoyZa Pro'

    -- RevenueCat data
    revenuecat_app_user_id text NOT NULL,
    product_identifier text, -- 'monthly' or 'yearly'
    store text, -- 'app_store', 'play_store', 'stripe', etc.

    -- Temporal data
    expires_at timestamp with time zone,
    period_type text, -- 'trial', 'normal', 'promotional', 'intro'
    purchase_date timestamp with time zone,

    -- Renewal info
    will_renew boolean NOT NULL DEFAULT false,
    billing_issues_detected_at timestamp with time zone,
    unsubscribe_detected_at timestamp with time zone,

    -- Metadata
    created_at timestamp with time zone DEFAULT timezone('utc'::text, now()) NOT NULL,
    updated_at timestamp with time zone DEFAULT timezone('utc'::text, now()) NOT NULL,
    last_webhook_received_at timestamp with time zone,

    -- Ensure one subscription record per user per entitlement
    UNIQUE(user_id, entitlement)
);

-- ============================================================================
-- STEP 2: Create indexes for performance
-- ============================================================================

CREATE INDEX IF NOT EXISTS user_subscriptions_user_id_idx
    ON public.user_subscriptions(user_id);

CREATE INDEX IF NOT EXISTS user_subscriptions_status_idx
    ON public.user_subscriptions(status);

CREATE INDEX IF NOT EXISTS user_subscriptions_expires_at_idx
    ON public.user_subscriptions(expires_at);

CREATE INDEX IF NOT EXISTS user_subscriptions_revenuecat_app_user_id_idx
    ON public.user_subscriptions(revenuecat_app_user_id);

-- ============================================================================
-- STEP 3: Enable Row Level Security
-- ============================================================================

ALTER TABLE public.user_subscriptions ENABLE ROW LEVEL SECURITY;

-- Policy: Users can only view their own subscription
CREATE POLICY "Users can view their own subscription"
ON public.user_subscriptions
FOR SELECT
USING (auth.uid() = user_id);

-- Policy: Only service role can insert (via webhook)
CREATE POLICY "Service role can insert subscriptions"
ON public.user_subscriptions
FOR INSERT
WITH CHECK (auth.role() = 'service_role');

-- Policy: Only service role can update (via webhook)
CREATE POLICY "Service role can update subscriptions"
ON public.user_subscriptions
FOR UPDATE
USING (auth.role() = 'service_role');

-- ============================================================================
-- STEP 4: Create updated_at trigger
-- ============================================================================

-- Reuse existing handle_updated_at function if it exists
-- Otherwise create it
CREATE OR REPLACE FUNCTION public.handle_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at = timezone('utc'::text, now());
    RETURN NEW;
END;
$$;

CREATE TRIGGER set_user_subscriptions_updated_at
    BEFORE UPDATE ON public.user_subscriptions
    FOR EACH ROW
    EXECUTE FUNCTION public.handle_updated_at();

-- ============================================================================
-- STEP 5: Enable Realtime for this table
-- ============================================================================

-- Add table to supabase_realtime publication
ALTER PUBLICATION supabase_realtime ADD TABLE public.user_subscriptions;

-- ============================================================================
-- STEP 6: Create upsert function for webhook
-- ============================================================================

-- This function will be called by the RevenueCat webhook handler
-- It's idempotent, so webhook retries won't create duplicate records
CREATE OR REPLACE FUNCTION public.upsert_subscription_status(
    p_user_id uuid,
    p_revenuecat_app_user_id text,
    p_status text,
    p_entitlement text,
    p_product_identifier text,
    p_store text,
    p_expires_at timestamp with time zone,
    p_period_type text,
    p_purchase_date timestamp with time zone,
    p_will_renew boolean,
    p_billing_issues_detected_at timestamp with time zone DEFAULT NULL,
    p_unsubscribe_detected_at timestamp with time zone DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    INSERT INTO public.user_subscriptions (
        user_id,
        revenuecat_app_user_id,
        status,
        entitlement,
        product_identifier,
        store,
        expires_at,
        period_type,
        purchase_date,
        will_renew,
        billing_issues_detected_at,
        unsubscribe_detected_at,
        last_webhook_received_at
    ) VALUES (
        p_user_id,
        p_revenuecat_app_user_id,
        p_status,
        p_entitlement,
        p_product_identifier,
        p_store,
        p_expires_at,
        p_period_type,
        p_purchase_date,
        p_will_renew,
        p_billing_issues_detected_at,
        p_unsubscribe_detected_at,
        timezone('utc'::text, now())
    )
    ON CONFLICT (user_id, entitlement)
    DO UPDATE SET
        status = EXCLUDED.status,
        product_identifier = EXCLUDED.product_identifier,
        store = EXCLUDED.store,
        expires_at = EXCLUDED.expires_at,
        period_type = EXCLUDED.period_type,
        purchase_date = EXCLUDED.purchase_date,
        will_renew = EXCLUDED.will_renew,
        billing_issues_detected_at = EXCLUDED.billing_issues_detected_at,
        unsubscribe_detected_at = EXCLUDED.unsubscribe_detected_at,
        last_webhook_received_at = timezone('utc'::text, now()),
        updated_at = timezone('utc'::text, now());
END;
$$;

-- Grant execute permission to service role
GRANT EXECUTE ON FUNCTION public.upsert_subscription_status TO service_role;

-- ============================================================================
-- VERIFICATION COMMENTS
-- ============================================================================
-- After running this migration, verify:
--
-- 1. Table created:
--    SELECT * FROM user_subscriptions;
--
-- 2. RLS enabled:
--    SELECT tablename, rowsecurity FROM pg_tables WHERE tablename = 'user_subscriptions';
--
-- 3. Realtime enabled:
--    SELECT * FROM pg_publication_tables WHERE pubname = 'supabase_realtime' AND tablename = 'user_subscriptions';
--
-- 4. Test upsert function (as service role):
--    SELECT upsert_subscription_status(
--      'YOUR_USER_UUID',
--      'YOUR_USER_UUID',
--      'active',
--      'VoyZa Pro',
--      'monthly',
--      'app_store',
--      NOW() + INTERVAL '1 month',
--      'normal',
--      NOW(),
--      true
--    );
