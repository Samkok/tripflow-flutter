-- Migration 007: Verify and Enable Realtime on trip_collaborators table
-- This ensures that permission changes are broadcast to connected clients in real-time

-- Step 1: Enable Realtime for the trip_collaborators table
-- This allows Supabase to broadcast INSERT, UPDATE, DELETE events
ALTER PUBLICATION supabase_realtime ADD TABLE public.trip_collaborators;

-- Step 2: Verify the publication (for debugging)
-- Run this to check if trip_collaborators is included in realtime
-- SELECT * FROM pg_publication_tables WHERE pubname = 'supabase_realtime';

-- Note: If you get an error that the table is already in the publication, that's OK!
-- The error means realtime is already enabled, which is what we want.

-- Step 3: Ensure RLS policies don't block realtime events
-- Realtime uses a special 'anon' role to broadcast events
-- Users receive events based on their subscription filters, not RLS

-- The existing RLS policies on trip_collaborators should allow users to SELECT
-- their own collaborator records, which is what we need for realtime to work

-- Verify SELECT policy exists (should already be there from migration 003)
DO $$
BEGIN
  -- Check if policy exists
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE tablename = 'trip_collaborators'
    AND policyname = 'trip_collaborators_select_policy'
  ) THEN
    -- Create SELECT policy if it doesn't exist
    EXECUTE 'CREATE POLICY trip_collaborators_select_policy
    ON public.trip_collaborators
    FOR SELECT
    USING (
      user_id = auth.uid()
      OR
      trip_id IN (
        SELECT id FROM public.trips WHERE user_id = auth.uid()
      )
    )';
    RAISE NOTICE 'Created SELECT policy for trip_collaborators';
  ELSE
    RAISE NOTICE 'SELECT policy already exists for trip_collaborators';
  END IF;
END $$;

-- Step 4: Grant necessary permissions for realtime
-- Ensure the authenticated role can select from trip_collaborators
GRANT SELECT ON public.trip_collaborators TO authenticated;
GRANT SELECT ON public.trip_collaborators TO anon;

-- Success message
DO $$
BEGIN
  RAISE NOTICE '✅ Realtime configuration complete for trip_collaborators';
  RAISE NOTICE 'ℹ️  Changes should now broadcast in real-time to connected clients';
  RAISE NOTICE 'ℹ️  Expected latency: 100-2000ms depending on network conditions';
END $$;
