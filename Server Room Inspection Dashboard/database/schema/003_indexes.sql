-- ===========================================================================
-- 003_indexes.sql — supporting indexes.
-- ---------------------------------------------------------------------------
-- The uq_inspection UNIQUE constraint (source_site, inspection_date, shift)
-- already backs the primary access pattern; these add date-range and lookup
-- paths for the dashboard views. Idempotent.
-- ===========================================================================

SET search_path = srid, public;

-- Plant + day + shift is the dashboard's main filter (already unique-indexed,
-- but an explicit btree keeps intent clear and helps partial scans).
CREATE INDEX IF NOT EXISTS ix_inspection_site_date_shift
    ON srid.inspection_log (source_site, inspection_date, shift);

-- Month rollups (v_monthly_compliance) group by date_trunc('month', ...).
CREATE INDEX IF NOT EXISTS ix_inspection_date
    ON srid.inspection_log (inspection_date);

-- Inspector drill-downs.
CREATE INDEX IF NOT EXISTS ix_inspection_inspector
    ON srid.inspection_log (inspector_id);

-- Case-insensitive inspector lookup by SAM account.
CREATE INDEX IF NOT EXISTS ix_inspectors_sam
    ON srid.inspectors (sam_account_name);
