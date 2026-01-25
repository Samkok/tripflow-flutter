-- Rollback Migration 010: Remove persistent location counter
-- This will completely undo the changes made in migration 010

-- ============================================================================
-- STEP 1: Drop trigger
-- ============================================================================

DROP TRIGGER IF EXISTS trg_increment_location_counter ON public.locations;

-- ============================================================================
-- STEP 2: Drop trigger function
-- ============================================================================

DROP FUNCTION IF EXISTS public.increment_location_counter();

-- ============================================================================
-- STEP 3: Drop index
-- ============================================================================

DROP INDEX IF EXISTS public.user_profiles_locations_added_count_idx;

-- ============================================================================
-- STEP 4: Remove column from user_profiles
-- ============================================================================

ALTER TABLE public.user_profiles
DROP COLUMN IF EXISTS locations_added_count;

-- ============================================================================
-- VERIFICATION (Run after rollback)
-- ============================================================================

-- Verify column is removed:
-- SELECT column_name FROM information_schema.columns
-- WHERE table_name = 'user_profiles' AND column_name = 'locations_added_count';
-- Expected: No results

-- Verify trigger is removed:
-- SELECT tgname FROM pg_trigger WHERE tgname = 'trg_increment_location_counter';
-- Expected: No results

-- Verify function is removed:
-- SELECT proname FROM pg_proc WHERE proname = 'increment_location_counter';
-- Expected: No results
