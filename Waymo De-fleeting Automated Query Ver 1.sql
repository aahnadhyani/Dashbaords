-- =====================================================================
-- WAYMO NASHVILLE — DE-FLEETING / FLEET PAUSE IMPACT ON RO LAUNCHABLE
-- v2 — uses Waymo's native is_weather_pause flag
-- =====================================================================
--
-- WHAT CHANGED FROM v1
--   Waymo populated the is_weather_pause field on operation_timeline_tvc.
--   We now use it directly for weather events instead of deriving them.
--   Validated Jun 9 - Sep 13: 247 of our 269 weather-attributable hours
--   matched their flag (92%), and 247 of their 259 matched ours (95%).
--   Crucially it correctly does NOT flag the two ops-driven events
--   (7/4-7/5 construction, 8/14 lug nut), so it gives us clean cause
--   attribution for the first time.
--
-- OUTPUT GRAIN
--   One row per calendar day per shift type (Peak / Off-peak / Standard).
--   ~3 rows/day. Roll up to week or month with SUMIFS — hour columns are
--   additive. Now also splits lost hours into weather vs ops-driven.
--
-- =====================================================================
-- METHODOLOGY
-- =====================================================================
--
-- 1. Source is one row per MINUTE. Average to HOURLY.
--
-- 2. Flag disrupted hours. Four types, in priority order:
--
--    a) WEATHER — Waymo's is_weather_pause is TRUE for any minute in the
--       hour. Their flag runs from when a weather event is filed to when
--       their team confirms service resumed, so it already covers the
--       partial hours at each end of an event. No derivation needed.
--
--    b) OPS FULL EVENT — not weather-flagged, and Launchable <= 3 AND
--       In-Service <= 3. Catches full pauses/de-fleets that Waymo does
--       not attribute to weather (e.g. the 8/14 lug nut inspection).
--
--    c) OPS PARTIAL EVENT — not weather-flagged, not a full event, and
--       hourly Launchable below 70% of that week's clean-hour benchmark
--       for that shift. Catches partial de-fleets where a subset of the
--       fleet is pulled but fleet-level numbers never reach zero —
--       e.g. the 7/4-7/5 construction de-fleet at ~58% of normal.
--       The 70% trigger equates to roughly 50% Launchable-of-Capable,
--       vs a normal clean-hour KPI of ~72% and a 78% CSL target. Only
--       ~1% of clean hours dip below that line naturally.
--       The benchmark is per week per shift, so the trigger is DYNAMIC —
--       it tracks the fleet as it grows and will follow Launchable down
--       if efficiency drops structurally (e.g. OJAI chargers).
--
--    d) RECOVERY — a clean hour following an event where Launchable is
--       still below 75% of the benchmark. These hours are still depressed
--       BY the event; leaving them in would drag the benchmark down.
--       Waymo's flag stops when service resumes, so this stays ours.
--
-- 3. Recompute the benchmark excluding all four types. This is
--    "what a normal hour looked like that week, for that shift".
--
-- 4. COUNTERFACTUAL = actual Launchable from clean hours
--                     + (disrupted hour count x benchmark).
--    Each bad hour is credited at that week's own normal rate, NOT at
--    fleet size. Average credit ~48 vehicles vs ~67 Capable — a ~29%
--    haircut — so the estimate is deliberately conservative.
--
-- 5. LOST HOURS = counterfactual - actual, split weather vs ops by the
--    share of disrupted hours in each category.
--
-- DENOMINATOR
--   RO Capable, matching the 78% CSL definition (Launchable / Capable).
--   Not RO Pool — Pool includes vehicles never fit to work.
--
-- =====================================================================
-- VALIDATION vs the manual Excel workbook (Jun 9 - Sep 13, 2026)
-- =====================================================================
--   Disrupted hours : 321 vs 312     (+9)
--   Lost hours      : 12,551 vs 12,462   (+0.7%)
--   % of Capable    : 8.00% vs 8.27%
--   Revenue         : $50,206 vs $49,850
--
--   Composition: 259 weather, 13 ops-full, 41 ops-partial, 8 recovery.
--   The query picks up 4 hours on 6/9 00:00-03:00 that were never flagged
--   manually — Launchable hit zero and Waymo marks it as weather, so it
--   looks like a genuine miss in the manual tagging.
--
-- =====================================================================
-- NOTES
-- =====================================================================
--   - Shift type comes from date_time_info.peak_classification.demand,
--     NOT supply. Validated against the manual Shift Grid: 71/71 day-hour
--     combinations match, so that tab is now redundant.
--   - Uses funnel_stage.cumulative (not .ultimate).
--   - Period starts 2026-06-09, when Lyft operations began.
--   - Revenue at $4 per RO Ready supply hour (DP1 service fee). A
--     conservative floor — excludes the 12% rev share.
--   - Runs inception-to-date with no manual inputs. Re-run weekly and
--     replace the whole output range rather than appending, so partial
--     weeks correct themselves as they fill in.
-- =====================================================================

WITH

-- STEP 1: raw minute rows; unpack the nested metrics_set field ---------
base AS (
  SELECT
    local_date,
    date_time_info.local.week_start                         AS week_start,
    CAST(date_time_info.local.hour_of_day_display AS INT64) AS hour_of_day,
    date_time_info.peak_classification.demand.peak_category AS shift,
    is_weather_pause,
    metrics_set.vehicle.funnel_stage.cumulative.ro_launchable.minutes AS launchable,
    metrics_set.vehicle.funnel_stage.cumulative.ro_capable.minutes    AS capable,
    metrics_set.vehicle.funnel_stage.cumulative.in_service.minutes    AS in_service,
    metrics_set.vehicle.funnel_stage.cumulative.ro_pool.minutes       AS pool
  FROM waymo_data.ro_utilization.operation_timeline_tvc
  WHERE CAST(ops_depot AS STRING) = 'NASHVILLE'
    AND local_date >= DATE '2026-06-09'
    AND date_time_info.peak_classification.demand.peak_category
        IN ('Off-peak', 'Peak', 'Standard')
),

-- STEP 2a: collapse to hourly; flag WEATHER and OPS FULL events --------
hourly AS (
  SELECT
    local_date, week_start, hour_of_day, shift,
    DATETIME_ADD(DATETIME(local_date), INTERVAL hour_of_day HOUR) AS dt,
    AVG(launchable) AS launchable,
    AVG(capable)    AS capable,
    AVG(in_service) AS in_service,
    AVG(pool)       AS pool,
    MAX(CASE WHEN is_weather_pause THEN 1 ELSE 0 END) AS is_weather,
    CASE WHEN MAX(CASE WHEN is_weather_pause THEN 1 ELSE 0 END) = 0
          AND AVG(launchable) <= 3
          AND AVG(in_service) <= 3
         THEN 1 ELSE 0 END                            AS is_ops_full
  FROM base
  GROUP BY local_date, week_start, hour_of_day, shift
),

-- STEP 2b: pass-1 benchmark, excluding weather + ops-full --------------
bench_p1 AS (
  SELECT week_start, shift,
         AVG(CASE WHEN is_weather = 0 AND is_ops_full = 0
                  THEN launchable END) AS b1
  FROM hourly
  GROUP BY week_start, shift
),

-- STEP 2c: flag OPS PARTIAL events (< 70% of that week's normal) -------
partials AS (
  SELECT
    h.*,
    CASE WHEN h.is_weather = 0
          AND h.is_ops_full = 0
          AND SAFE_DIVIDE(h.launchable, b.b1) < 0.70
         THEN 1 ELSE 0 END AS is_ops_partial
  FROM hourly h
  JOIN bench_p1 b USING (week_start, shift)
),

event_flagged AS (
  SELECT *,
    GREATEST(is_weather, is_ops_full, is_ops_partial) AS is_event
  FROM partials
),

-- STEP 2d: pass-2 benchmark, now excluding partials too ----------------
bench_p2 AS (
  SELECT week_start, shift,
         AVG(CASE WHEN is_event = 0 THEN launchable END) AS b2
  FROM event_flagged
  GROUP BY week_start, shift
),

-- STEP 2e: number each contiguous run of event hours -------------------
blocks AS (
  SELECT e.*, b.b2,
         SAFE_DIVIDE(e.launchable, b.b2)      AS ratio_to_benchmark,
         SUM(e.is_event) OVER (ORDER BY e.dt) AS block_id
  FROM event_flagged e
  JOIN bench_p2 b USING (week_start, shift)
),

-- STEP 2f: flag RECOVERY hours -----------------------------------------
recovery AS (
  SELECT *,
    CASE
      WHEN is_event = 0
       AND ratio_to_benchmark < 0.75
       AND MIN(CASE WHEN ratio_to_benchmark >= 0.75 THEN dt END)
             OVER (PARTITION BY block_id ORDER BY dt
                   ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) IS NULL
      THEN 1 ELSE 0
    END AS is_recovery
  FROM blocks
),

flagged AS (
  SELECT *, GREATEST(is_event, is_recovery) AS is_bad
  FROM recovery
),

-- STEP 3: final benchmark, excluding all four flag types ---------------
bench_final AS (
  SELECT week_start, shift,
         AVG(CASE WHEN is_bad = 0 THEN launchable END) AS benchmark
  FROM flagged
  GROUP BY week_start, shift
)

-- STEPS 4-5: roll up to day x shift; build the counterfactual ----------
SELECT
  f.local_date                                   AS day,
  f.week_start,
  f.shift,

  CAST(COUNT(*) AS INT64)                        AS total_hours,
  CAST(SUM(f.is_bad) AS INT64)                   AS disrupted_hours,

  -- cause split
  CAST(SUM(f.is_weather) AS INT64)               AS weather_hours,
  CAST(SUM(f.is_ops_full) AS INT64)              AS ops_full_hours,
  CAST(SUM(f.is_ops_partial) AS INT64)           AS ops_partial_hours,
  CAST(SUM(f.is_recovery) AS INT64)              AS recovery_hours,

  ROUND(b.benchmark, 4)                          AS clean_hour_benchmark,
  ROUND(SUM(f.launchable), 4)                    AS actual_launchable_hrs,

  ROUND(SUM(CASE WHEN f.is_bad = 0 THEN f.launchable ELSE 0 END)
        + SUM(f.is_bad) * b.benchmark, 4)        AS counterfactual_hrs,

  ROUND(SUM(CASE WHEN f.is_bad = 0 THEN f.launchable ELSE 0 END)
        + SUM(f.is_bad) * b.benchmark
        - SUM(f.launchable), 4)                  AS lost_launchable_hrs,

  -- lost hours attributed to weather vs everything else
  ROUND(SUM(f.is_weather) * b.benchmark
        - SUM(CASE WHEN f.is_weather = 1 THEN f.launchable ELSE 0 END), 4)
                                                 AS lost_hrs_weather,
  ROUND((SUM(f.is_ops_full) + SUM(f.is_ops_partial) + SUM(f.is_recovery)) * b.benchmark
        - SUM(CASE WHEN f.is_weather = 0 AND f.is_bad = 1
                   THEN f.launchable ELSE 0 END), 4)
                                                 AS lost_hrs_ops,

  ROUND(SUM(f.capable), 4)                       AS capable_hrs,
  ROUND(SUM(f.pool), 4)                          AS pool_hrs,

  ROUND((SUM(CASE WHEN f.is_bad = 0 THEN f.launchable ELSE 0 END)
        + SUM(f.is_bad) * b.benchmark
        - SUM(f.launchable)) * 4, 2)             AS revenue_lost_usd

FROM flagged f
JOIN bench_final b USING (week_start, shift)
GROUP BY f.local_date, f.week_start, f.shift, b.benchmark
ORDER BY f.local_date, f.shift
