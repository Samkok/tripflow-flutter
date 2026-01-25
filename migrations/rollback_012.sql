-- Rollback Migration 012: Remove will_renew documentation comment
-- Note: Data fixes from migration 012 are intentional and NOT rolled back
-- (those fixes corrected incorrect will_renew values from the webhook bug)

BEGIN;

-- Remove the documentation comment
COMMENT ON COLUMN public.user_subscriptions.will_renew IS NULL;

COMMIT;

-- ============================================================================
-- VERIFICATION (Run after rollback)
-- ============================================================================

-- Verify comment is removed:
-- SELECT col_description('public.user_subscriptions'::regclass,
--   (SELECT attnum FROM pg_attribute
--    WHERE attrelid = 'public.user_subscriptions'::regclass
--    AND attname = 'will_renew'));
-- Expected: Empty/NULL result
