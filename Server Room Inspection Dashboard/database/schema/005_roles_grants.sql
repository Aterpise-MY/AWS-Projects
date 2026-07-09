-- ===========================================================================
-- 005_roles_grants.sql — least-privilege application role.
-- ---------------------------------------------------------------------------
-- Creates `srid_app`, the login role the API/Fargate service will use in a
-- later phase. It is NOT the owner and NOT a superuser: it receives only DML
-- on the base tables, SELECT on the reporting views, and USAGE on the identity
-- sequences. Its search_path is pinned to `srid, public` so unqualified names
-- resolve into the application schema.
--
-- The role is created here WITHOUT a password (idempotent DO-block). The
-- migration Lambda sets its password afterwards from Secrets Manager via a
-- parameterised `ALTER ROLE ... WITH LOGIN PASSWORD` — so no credential is ever
-- written into a committed .sql file.
-- ===========================================================================

SET search_path = srid, public;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'srid_app') THEN
        CREATE ROLE srid_app WITH LOGIN;
    END IF;
END
$$;

-- Pin the application search_path on the role itself.
ALTER ROLE srid_app SET search_path = srid, public;

-- Schema + object grants (least privilege).
GRANT USAGE ON SCHEMA srid TO srid_app;

GRANT SELECT, INSERT, UPDATE, DELETE
    ON srid.sites, srid.inspectors, srid.inspection_log
    TO srid_app;

GRANT SELECT
    ON srid.v_daily_summary, srid.v_monthly_compliance, srid.v_flagged_records
    TO srid_app;

-- Identity columns pull from sequences; the app needs USAGE to INSERT.
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA srid TO srid_app;

-- Future objects created by the migration/master role auto-grant to srid_app.
ALTER DEFAULT PRIVILEGES IN SCHEMA srid
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO srid_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA srid
    GRANT USAGE, SELECT ON SEQUENCES TO srid_app;

-- Explicitly deny the ambient public-schema create right (defence in depth).
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
