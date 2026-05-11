-- Migration 029: Add scheduled_end_date to locations
--
-- Powers the "multi-day stay" / accommodation feature. Paired with the
-- existing `scheduled_date` column to represent an inclusive `[start..end]`
-- range. Null = single-day stop (legacy behavior).
--
-- When non-null, must be on-or-after `scheduled_date`. The constraint is
-- enforced when both columns are present; the IS NULL clauses leave room
-- for backfills or partial writes.

ALTER TABLE public.locations
  ADD COLUMN IF NOT EXISTS scheduled_end_date timestamptz,
  ADD CONSTRAINT scheduled_end_date_after_start
    CHECK (
      scheduled_end_date IS NULL
      OR scheduled_date IS NULL
      OR scheduled_end_date >= scheduled_date
    );
