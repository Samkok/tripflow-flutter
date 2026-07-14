-- Make collaborator permission changes propagate over Realtime.
--
-- trip_collaborators is already in the supabase_realtime publication, but its
-- replica identity was DEFAULT (primary key only). With RLS enabled, Supabase
-- Realtime authorizes UPDATE/DELETE events by evaluating the SELECT policy
-- against the changed row — and for UPDATE/DELETE the row it sees is the
-- REPLICA IDENTITY. Under PK-only identity the policy (is_trip_member(trip_id,
-- auth.uid())) has no trip_id to check, so Realtime drops the event and the
-- subscriber never hears about it. Two visible symptoms:
--   * An owner toggling a collaborator's permission (read<->write) did NOT
--     reach the collaborator's device in realtime — e.g. the per-date
--     "add place" button wouldn't appear/disappear until a manual refresh.
--   * DELETE ("collaborator removed / left") events carry only the PK in the
--     old record, so the client's oldRecord['trip_id'] read was null.
--
-- REPLICA IDENTITY FULL logs the complete old row, so the RLS check succeeds
-- and the full record (trip_id, user_id, permission) is delivered. The table
-- is tiny and rarely written, so the extra WAL volume is negligible.

ALTER TABLE public.trip_collaborators REPLICA IDENTITY FULL;
