-- Migration 017: Enable Realtime for the locations table
--
-- PROBLEM: The locations table was never added to the Supabase realtime publication.
-- migration 007 only added trip_collaborators. Without this, Supabase never broadcasts
-- INSERT/UPDATE/DELETE events for locations — the client-side subscribeToRealtimeChanges()
-- subscription is set up but never fires, so the map and trip details list never update
-- in real-time when collaborators add/change/delete locations.
--
-- SOLUTION: Add locations to the supabase_realtime publication.
-- Note: If this table is already in the publication you will get an error like
--   "relation already exists in publication" — that's fine, realtime is already enabled.

ALTER PUBLICATION supabase_realtime ADD TABLE public.locations;

-- Verify (optional — run manually to confirm):
-- SELECT schemaname, tablename
-- FROM pg_publication_tables
-- WHERE pubname = 'supabase_realtime'
-- ORDER BY tablename;
