-- Migration 010: Add persistent location counter to user_profiles
-- Prevents users from bypassing free tier limit by deleting/re-adding locations
--
-- User Requirements:
-- - Counter freezes when user upgrades to Pro (doesn't increment)
-- - Counter never resets (lifetime accumulator)
-- - Increment for trip owner when location added to their trip
-- - Count all locations including orphaned ones (trip_id = NULL)

-- ============================================================================
-- STEP 1: Add counter column to user_profiles
-- ============================================================================

ALTER TABLE public.user_profiles
ADD COLUMN IF NOT EXISTS locations_added_count INTEGER DEFAULT 0 NOT NULL;

COMMENT ON COLUMN public.user_profiles.locations_added_count IS
'Lifetime count of locations added. Increments for free users, freezes when Pro. Never resets.';

-- ============================================================================
-- STEP 2: Create index for performance
-- ============================================================================

CREATE INDEX IF NOT EXISTS user_profiles_locations_added_count_idx
ON public.user_profiles(locations_added_count);

-- ============================================================================
-- STEP 3: Create trigger function to increment counter
-- ============================================================================

CREATE OR REPLACE FUNCTION public.increment_location_counter()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_user_id uuid;
    v_is_pro boolean;
BEGIN
    -- Only process INSERT operations
    IF (TG_OP != 'INSERT') THEN
        RETURN NEW;
    END IF;

    -- Determine which user's counter to increment:
    -- - If location has trip_id: increment trip owner's counter
    -- - If location has no trip_id: increment location creator's counter
    IF NEW.trip_id IS NOT NULL THEN
        -- Get trip owner
        SELECT user_id INTO v_user_id
        FROM public.trips
        WHERE id = NEW.trip_id;

        -- If trip not found, fall back to location creator
        IF v_user_id IS NULL THEN
            v_user_id := NEW.user_id;
        END IF;
    ELSE
        -- No trip, use location creator
        v_user_id := NEW.user_id;
    END IF;

    -- Skip if no valid user_id found
    IF v_user_id IS NULL THEN
        RETURN NEW;
    END IF;

    -- Check if user is Pro (has active VoyZa Pro subscription)
    SELECT EXISTS (
        SELECT 1
        FROM public.user_subscriptions
        WHERE user_id = v_user_id
        AND entitlement = 'premium'
        AND status = 'active'
    ) INTO v_is_pro;

    -- Only increment counter if user is NOT Pro
    IF NOT v_is_pro THEN
        UPDATE public.user_profiles
        SET locations_added_count = locations_added_count + 1
        WHERE user_id = v_user_id;

        RAISE NOTICE 'Incremented location counter for user %, new count: %',
            v_user_id,
            (SELECT locations_added_count FROM public.user_profiles WHERE user_id = v_user_id);
    ELSE
        RAISE NOTICE 'User % is Pro, counter NOT incremented', v_user_id;
    END IF;

    RETURN NEW;
END;
$$;

-- ============================================================================
-- STEP 4: Attach trigger to locations table
-- ============================================================================

DROP TRIGGER IF EXISTS trg_increment_location_counter ON public.locations;

CREATE TRIGGER trg_increment_location_counter
    AFTER INSERT ON public.locations
    FOR EACH ROW
    EXECUTE FUNCTION public.increment_location_counter();

-- ============================================================================
-- STEP 5: Backfill existing users
-- ============================================================================

-- Calculate current counts for existing users and update their counters
-- This counts all locations in trips owned by the user + orphaned locations they created

WITH user_trip_location_counts AS (
    -- Count locations in trips owned by user
    SELECT
        t.user_id,
        COUNT(l.id) as trip_locations
    FROM public.trips t
    LEFT JOIN public.locations l ON l.trip_id = t.id
    WHERE l.id IS NOT NULL
    GROUP BY t.user_id
),
user_orphaned_location_counts AS (
    -- Count orphaned locations created by user (no trip_id)
    SELECT
        l.user_id,
        COUNT(l.id) as orphaned_locations
    FROM public.locations l
    WHERE l.trip_id IS NULL
    GROUP BY l.user_id
),
combined_counts AS (
    -- Combine both counts
    SELECT
        COALESCE(tlc.user_id, olc.user_id) as user_id,
        COALESCE(tlc.trip_locations, 0) + COALESCE(olc.orphaned_locations, 0) as total_locations
    FROM user_trip_location_counts tlc
    FULL OUTER JOIN user_orphaned_location_counts olc ON tlc.user_id = olc.user_id
)
UPDATE public.user_profiles up
SET locations_added_count = cc.total_locations
FROM combined_counts cc
WHERE up.user_id = cc.user_id;

-- Ensure all user_profiles have a counter value (default to 0 if no locations)
UPDATE public.user_profiles
SET locations_added_count = 0
WHERE locations_added_count IS NULL;

-- ============================================================================
-- STEP 6: Grant permissions
-- ============================================================================

GRANT EXECUTE ON FUNCTION public.increment_location_counter() TO authenticated;
GRANT EXECUTE ON FUNCTION public.increment_location_counter() TO service_role;

-- ============================================================================
-- VERIFICATION QUERIES (Run these after migration to verify)
-- ============================================================================

-- 1. Verify column exists:
-- SELECT column_name, data_type, column_default
-- FROM information_schema.columns
-- WHERE table_name = 'user_profiles' AND column_name = 'locations_added_count';

-- 2. Verify trigger exists:
-- SELECT tgname, tgenabled FROM pg_trigger WHERE tgname = 'trg_increment_location_counter';

-- 3. Check backfilled counts:
-- SELECT user_id, locations_added_count
-- FROM user_profiles
-- WHERE locations_added_count > 0
-- ORDER BY locations_added_count DESC
-- LIMIT 10;

-- 4. Verify counter distribution:
-- SELECT
--     CASE
--         WHEN locations_added_count = 0 THEN '0 locations'
--         WHEN locations_added_count BETWEEN 1 AND 5 THEN '1-5 locations'
--         WHEN locations_added_count > 5 THEN '5+ locations'
--     END as bucket,
--     COUNT(*) as users
-- FROM user_profiles
-- GROUP BY bucket
-- ORDER BY bucket;
