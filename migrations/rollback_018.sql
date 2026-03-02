-- Rollback 018: Revert upsert_subscription_status to direct-overwrite behaviour

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
        status                       = EXCLUDED.status,
        product_identifier           = EXCLUDED.product_identifier,
        store                        = EXCLUDED.store,
        expires_at                   = EXCLUDED.expires_at,
        period_type                  = EXCLUDED.period_type,
        purchase_date                = EXCLUDED.purchase_date,
        will_renew                   = EXCLUDED.will_renew,
        billing_issues_detected_at   = EXCLUDED.billing_issues_detected_at,
        unsubscribe_detected_at      = EXCLUDED.unsubscribe_detected_at,
        last_webhook_received_at     = timezone('utc'::text, now()),
        updated_at                   = timezone('utc'::text, now());
END;
$$;

GRANT EXECUTE ON FUNCTION public.upsert_subscription_status TO service_role;
