-- Rollback for migration 007: Disable Realtime on trip_collaborators
-- WARNING: This will stop broadcasting permission changes in real-time
-- Users will need to manually refresh or reactivate trips to see permission changes

-- Remove trip_collaborators from the realtime publication
ALTER PUBLICATION supabase_realtime DROP TABLE public.trip_collaborators;

-- Note: This doesn't remove the SELECT policy or permissions
-- Those are still needed for normal database operations
-- This only stops the real-time broadcasting of changes

DO $$
BEGIN
  RAISE NOTICE '⚠️  Realtime disabled for trip_collaborators';
  RAISE NOTICE 'ℹ️  Permission changes will no longer broadcast in real-time';
END $$;
