-- Migration 012: Fix incorrect will_renew values from previous webhook bug
-- Previous code used `event.will_renew ?? false` which incorrectly defaulted
-- all subscriptions to false, even active renewable ones
--
-- Event-driven inference (correct):
--   true = INITIAL_PURCHASE, RENEWAL, UNCANCELLATION, PRODUCT_CHANGE
--   false = CANCELLATION, BILLING_ISSUE, EXPIRATION

BEGIN;

-- Fix active subscriptions that should be renewable
-- These are likely from INITIAL_PURCHASE or RENEWAL events that were
-- incorrectly set to will_renew=false due to the ?? false default
UPDATE public.user_subscriptions
SET will_renew = true
WHERE will_renew = false
  AND status = 'active'
  AND expires_at > NOW()
  AND (
    -- Exclude subscriptions that are truly cancelled (in grace period)
    -- These should keep will_renew = false
    unsubscribe_detected_at IS NULL
    AND billing_issues_detected_at IS NULL
  );

-- Add comprehensive documentation
COMMENT ON COLUMN public.user_subscriptions.will_renew IS
'Whether subscription will auto-renew. Inferred from webhook event type per RevenueCat best practices. true = renewable (INITIAL_PURCHASE/RENEWAL/UNCANCELLATION/etc), false = cancelled/expired/non-renewable';

COMMIT;
