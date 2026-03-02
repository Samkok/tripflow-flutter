-- Migration 019: Add user_subscription_history table
--
-- Every call to upsert_subscription_status now also inserts a row here,
-- giving a full immutable audit trail of every subscription event per user.
-- The history table is append-only; rows are never updated or deleted.

-- ============================================================================
-- STEP 1: Create user_subscription_history table
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.user_subscription_history (
    id                          uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id                     uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,

    -- Which RevenueCat event triggered this record
    event_type                  text,  -- INITIAL_PURCHASE, RENEWAL, TRANSFER, EXPIRATION, etc.

    -- Subscription state as received from the webhook at this point in time
    status                      text NOT NULL,
    entitlement                 text NOT NULL,
    revenuecat_app_user_id      text NOT NULL,
    product_identifier          text,
    store                       text,
    expires_at                  timestamp with time zone,
    period_type                 text,
    purchase_date               timestamp with time zone,
    will_renew                  boolean NOT NULL DEFAULT false,
    billing_issues_detected_at  timestamp with time zone,
    unsubscribe_detected_at     timestamp with time zone,

    -- When this history record was written
    created_at                  timestamp with time zone DEFAULT timezone('utc'::text, now()) NOT NULL
);

-- ============================================================================
-- STEP 2: Indexes
-- ============================================================================

CREATE INDEX IF NOT EXISTS user_subscription_history_user_id_idx
    ON public.user_subscription_history(user_id);

CREATE INDEX IF NOT EXISTS user_subscription_history_event_type_idx
    ON public.user_subscription_history(event_type);

-- Most recent events first
CREATE INDEX IF NOT EXISTS user_subscription_history_created_at_idx
    ON public.user_subscription_history(created_at DESC);

-- ============================================================================
-- STEP 3: Row Level Security
-- ============================================================================

ALTER TABLE public.user_subscription_history ENABLE ROW LEVEL SECURITY;

-- Users can read their own history
CREATE POLICY "Users can view their own subscription history"
ON public.user_subscription_history
FOR SELECT
USING (auth.uid() = user_id);

-- Only the service role (webhook) can insert history rows
CREATE POLICY "Service role can insert subscription history"
ON public.user_subscription_history
FOR INSERT
WITH CHECK (auth.role() = 'service_role');

-- No UPDATE or DELETE policies — history is immutable by design

-- ============================================================================
-- STEP 4: Replace upsert_subscription_status with a 13-parameter version
--
-- IMPORTANT: Adding p_event_type changes the function signature.
-- CREATE OR REPLACE with a different signature creates a new overload rather
-- than replacing the existing function, leaving two ambiguous versions.
-- We must DROP the old 12-parameter overload first.
-- ============================================================================

-- Drop the old 12-parameter overload (migrations 009 / 018)
DROP FUNCTION IF EXISTS public.upsert_subscription_status(
    uuid,
    text,
    text,
    text,
    text,
    text,
    timestamp with time zone,
    text,
    timestamp with time zone,
    boolean,
    timestamp with time zone,
    timestamp with time zone
);

-- Create the definitive 13-parameter version that also logs history
CREATE OR REPLACE FUNCTION public.upsert_subscription_status(
    p_user_id                       uuid,
    p_revenuecat_app_user_id        text,
    p_status                        text,
    p_entitlement                   text,
    p_product_identifier            text,
    p_store                         text,
    p_expires_at                    timestamp with time zone,
    p_period_type                   text,
    p_purchase_date                 timestamp with time zone,
    p_will_renew                    boolean,
    p_billing_issues_detected_at    timestamp with time zone DEFAULT NULL,
    p_unsubscribe_detected_at       timestamp with time zone DEFAULT NULL,
    p_event_type                    text DEFAULT NULL   -- RevenueCat event type label
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    -- Upsert the current subscription state (one row per user per entitlement)
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
        status                      = EXCLUDED.status,
        -- COALESCE: keep existing value when the incoming value is NULL.
        -- Prevents TRANSFER events (no product/expiry details) from wiping
        -- data written by a previous INITIAL_PURCHASE or RENEWAL.
        product_identifier          = COALESCE(EXCLUDED.product_identifier,       user_subscriptions.product_identifier),
        store                       = COALESCE(EXCLUDED.store,                     user_subscriptions.store),
        expires_at                  = COALESCE(EXCLUDED.expires_at,                user_subscriptions.expires_at),
        period_type                 = COALESCE(EXCLUDED.period_type,               user_subscriptions.period_type),
        purchase_date               = COALESCE(EXCLUDED.purchase_date,             user_subscriptions.purchase_date),
        -- Direct overwrite: these must be explicitly settable to NULL/false
        will_renew                  = EXCLUDED.will_renew,
        billing_issues_detected_at  = EXCLUDED.billing_issues_detected_at,
        unsubscribe_detected_at     = EXCLUDED.unsubscribe_detected_at,
        last_webhook_received_at    = timezone('utc'::text, now()),
        updated_at                  = timezone('utc'::text, now());

    -- Always append an immutable history record with exactly what was received.
    -- Records the raw webhook payload values (before COALESCE merging),
    -- giving a precise audit trail of what each event carried.
    INSERT INTO public.user_subscription_history (
        user_id,
        event_type,
        status,
        entitlement,
        revenuecat_app_user_id,
        product_identifier,
        store,
        expires_at,
        period_type,
        purchase_date,
        will_renew,
        billing_issues_detected_at,
        unsubscribe_detected_at
    ) VALUES (
        p_user_id,
        p_event_type,
        p_status,
        p_entitlement,
        p_revenuecat_app_user_id,
        p_product_identifier,
        p_store,
        p_expires_at,
        p_period_type,
        p_purchase_date,
        p_will_renew,
        p_billing_issues_detected_at,
        p_unsubscribe_detected_at
    );
END;
$$;

-- Grant execute permission
GRANT EXECUTE ON FUNCTION public.upsert_subscription_status TO service_role;
