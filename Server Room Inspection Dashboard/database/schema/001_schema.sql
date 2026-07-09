-- ===========================================================================
-- 001_schema.sql — namespace for the Server Room Inspection Dashboard.
-- ---------------------------------------------------------------------------
-- Applied by the in-VPC migration Lambda as the RDS master user against the
-- `inspections` database. Idempotent: safe to re-run.
--
-- All application objects live in the `srid` schema (not `public`) so grants
-- and search_path can be scoped tightly. `public` is left for extensions only.
-- ===========================================================================

CREATE SCHEMA IF NOT EXISTS srid;

-- Session search_path for the migration run itself (statements below rely on it
-- but every DDL object is also schema-qualified for safety).
SET search_path = srid, public;

COMMENT ON SCHEMA srid IS
  'Server Room Inspection Dashboard application objects (MCF facilities).';
