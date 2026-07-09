-- ===========================================================================
-- 004_views.sql — reporting views for the dashboard.
-- ---------------------------------------------------------------------------
-- Threshold bands (documented once, referenced by v_flagged_records):
--   temperature_c : recommended 18.0 – 27.0 °C  (ASHRAE A1 upper bound 27 °C)
--   humidity_pct  : recommended 40.0 – 60.0 %RH
--   ups voltage   : nominal 415 V line; acceptable band 395.0 – 430.0 V
-- Anything outside a band is "flagged". Bands live in the view definition so a
-- single ALTER VIEW re-tunes them without touching stored data.
-- Idempotent: CREATE OR REPLACE VIEW.
-- ===========================================================================

SET search_path = srid, public;

-- --------------------------------------------------------------------------
-- v_daily_summary — per plant/day AM+PM completeness + reading extremes.
-- Completeness = did both the AM and PM inspection happen? (2 expected/day.)
-- --------------------------------------------------------------------------
CREATE OR REPLACE VIEW srid.v_daily_summary AS
SELECT
    il.source_site,
    il.inspection_date,
    COUNT(*)                                        AS inspections_recorded,
    COUNT(*) FILTER (WHERE il.shift = 'AM')         AS am_count,
    COUNT(*) FILTER (WHERE il.shift = 'PM')         AS pm_count,
    (COUNT(*) FILTER (WHERE il.shift = 'AM') > 0
     AND COUNT(*) FILTER (WHERE il.shift = 'PM') > 0) AS is_complete,
    MIN(il.temperature_c)                           AS min_temperature_c,
    MAX(il.temperature_c)                           AS max_temperature_c,
    ROUND(AVG(il.temperature_c), 2)                 AS avg_temperature_c,
    MIN(il.humidity_pct)                            AS min_humidity_pct,
    MAX(il.humidity_pct)                            AS max_humidity_pct,
    ROUND(AVG(il.humidity_pct), 2)                  AS avg_humidity_pct,
    ROUND(AVG(il.ups1_voltage_v), 2)                AS avg_ups1_voltage_v,
    ROUND(AVG(il.ups2_voltage_v), 2)                AS avg_ups2_voltage_v
FROM srid.inspection_log il
GROUP BY il.source_site, il.inspection_date;

COMMENT ON VIEW srid.v_daily_summary IS
  'Per plant/day AM+PM completeness and min/max/avg readings.';

-- --------------------------------------------------------------------------
-- v_monthly_compliance — per plant/month expected vs actual + compliance %.
-- Expected = days_in_month * 2 shifts. Actual = distinct recorded inspections.
-- --------------------------------------------------------------------------
CREATE OR REPLACE VIEW srid.v_monthly_compliance AS
WITH monthly AS (
    SELECT
        il.source_site,
        date_trunc('month', il.inspection_date)::date AS month_start,
        COUNT(*) AS actual_inspections
    FROM srid.inspection_log il
    GROUP BY il.source_site, date_trunc('month', il.inspection_date)
)
SELECT
    m.source_site,
    m.month_start,
    to_char(m.month_start, 'YYYY-MM')                        AS month_label,
    (EXTRACT(DAY FROM (m.month_start + INTERVAL '1 month - 1 day'))::int * 2)
                                                             AS expected_inspections,
    m.actual_inspections,
    ROUND(
        100.0 * m.actual_inspections
        / NULLIF(EXTRACT(DAY FROM (m.month_start + INTERVAL '1 month - 1 day'))::int * 2, 0),
        1
    )                                                        AS compliance_pct
FROM monthly m;

COMMENT ON VIEW srid.v_monthly_compliance IS
  'Per plant/month expected (days*2) vs actual inspection count and compliance %.';

-- --------------------------------------------------------------------------
-- v_flagged_records — readings outside the documented threshold bands.
-- --------------------------------------------------------------------------
CREATE OR REPLACE VIEW srid.v_flagged_records AS
SELECT
    il.log_id,
    il.source_site,
    il.inspection_date,
    il.shift,
    il.inspected_at,
    il.sam_account_name,
    il.temperature_c,
    il.humidity_pct,
    il.ups1_voltage_v,
    il.ups2_voltage_v,
    il.status,
    ARRAY_REMOVE(ARRAY[
        CASE WHEN il.temperature_c > 27.0                       THEN 'TEMP_HIGH'  END,
        CASE WHEN il.temperature_c < 18.0                       THEN 'TEMP_LOW'   END,
        CASE WHEN il.humidity_pct  > 60.0                       THEN 'HUMID_HIGH' END,
        CASE WHEN il.humidity_pct  < 40.0                       THEN 'HUMID_LOW'  END,
        CASE WHEN il.ups1_voltage_v NOT BETWEEN 395.0 AND 430.0 THEN 'UPS1_VOLT'  END,
        CASE WHEN il.ups2_voltage_v NOT BETWEEN 395.0 AND 430.0 THEN 'UPS2_VOLT'  END
    ], NULL) AS breach_reasons
FROM srid.inspection_log il
WHERE il.temperature_c  > 27.0
   OR il.temperature_c  < 18.0
   OR il.humidity_pct   > 60.0
   OR il.humidity_pct   < 40.0
   OR il.ups1_voltage_v NOT BETWEEN 395.0 AND 430.0
   OR il.ups2_voltage_v NOT BETWEEN 395.0 AND 430.0;

COMMENT ON VIEW srid.v_flagged_records IS
  'Readings breaching threshold bands: temp 18-27C, humidity 40-60%, UPS 395-430V.';
