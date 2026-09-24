-- upsert_subscription_status: an event that names a product owns the expiry.
--
-- The DO UPDATE branch kept the stored expires_at whenever the incoming one
-- was NULL, so that TRANSFER events (which carry no product or expiry) don't
-- wipe details written by an earlier purchase. A lifetime purchase also has
-- a NULL expiry ("never"), so a row that once held a subscription kept that
-- subscription's expiry forever. Seen 2026-09-24: a premium.lifetime buyer's
-- row still said expires_at = 2026-08-16; reconcile-subscriptions saw expiry
-- drift against RevenueCat every 30 minutes and rewrote the row each time
-- (53 RECONCILE history rows in a day), and duplicate_public_trip, which
-- counts Pro as active AND (expires_at IS NULL OR expires_at > now()),
-- treated the paying customer as free.
--
-- Rule now: an event that names a product owns expires_at (NULL = never
-- expires); an event without a product (TRANSFER, the reconciler's plain
-- "expired" write) keeps the stored value, as before. The reconciler's next
-- write clears the stale date and the loop ends on its own.
--
-- First copy of this function in the repo: the body is the live definition
-- (pg_get_functiondef, 2026-09-24) with only the expires_at line changed.

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
    p_unsubscribe_detected_at timestamp with time zone DEFAULT NULL,
    p_event_type text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $function$
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
        -- expires_at is owned by any event that names a product (NULL means
        -- "never expires", e.g. premium.lifetime) and kept when the event
        -- has no product (TRANSFER, reconciler "expired" writes).
        expires_at                  = CASE
                                          WHEN EXCLUDED.product_identifier IS NULL THEN user_subscriptions.expires_at
                                          ELSE EXCLUDED.expires_at
                                      END,
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
$function$;
