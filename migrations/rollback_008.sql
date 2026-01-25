-- Rollback for Migration 008: Verify location RLS
-- This rollback restores the original simple policies (NOT RECOMMENDED - these have the bug)

-- Drop the comprehensive policies
DROP POLICY IF EXISTS "locations_select_policy" ON public.locations;
DROP POLICY IF EXISTS "locations_insert_policy" ON public.locations;
DROP POLICY IF EXISTS "locations_update_policy" ON public.locations;
DROP POLICY IF EXISTS "locations_delete_policy" ON public.locations;

-- Restore the original simple policies (WARNING: These have the visibility bug)
CREATE POLICY "Users can select their own locations"
ON public.locations FOR SELECT
USING (auth.uid() = user_id);

CREATE POLICY "Users can insert their own locations"
ON public.locations FOR INSERT
WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update their own locations"
ON public.locations FOR UPDATE
USING (auth.uid() = user_id);

CREATE POLICY "Users can delete their own locations"
ON public.locations FOR DELETE
USING (auth.uid() = user_id);

-- Note: Helper functions are kept since they don't cause any issues
-- and may be used by other parts of the system
