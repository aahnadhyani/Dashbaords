-- =====================================================================
-- WAYMO NASHVILLE — DE-FLEETING / FLEET PAUSE IMPACT ON RO LAUNCHABLE
-- =====================================================================
--
-- PURPOSE
--   Quantifies how much RO Launchable supply is lost to fleet pauses and
--   de-fleeting events, and estimates what Launchable performance WOULD
--   have been had those interruptions not occurred ("counterfactual").
--
-- OUTPUT GRAIN
--   One row per calendar day per shift type (Peak / Off-peak / Standard).
--   ~3 rows per day. Roll up to week or month in the destination sheet
--   with SUMIFS — all hour columns are additive.
--
-- =====================================================================
-- METHODOLOGY
-- =====================================================================
--
-- 1. Source data is one row per MINUTE. Average to HOURLY.
--
-- 2. Flag disrupted hours. Three types:
--
--    a) FULL EVENT — any minute in the hour had Launchable <= 3 AND
--       In-Service <= 3. Catches full pauses and de-fleets.
--       Using "any minute" rather than the hourly average is deliberate:
--       it captures the partial hours at event boundaries. The Aug 20,2026
--       pause began at 02:50, so the 02:00 hour averages 43 Launchable
--       but is genuinely disrupted.
--
--    b) PARTIAL EVENT — hourly-average Launchable below 70% of that
--       week's clean-hour benchmark for that shift. Catches partial
--       de-fleets where a subset of the fleet is pulled but fleet-level
--       numbers never reach zero — e.g. the 7/4-7/5 construction
--       de-fleet, which ran at ~58% of normal for 34 hours.
--
--       The 70% trigger equates to roughly 50% Launchable-of-Capable,
--       against a normal clean-hour KPI of ~72% and a 78% CSL target.
--       Only 0.9% of clean hours dip below that line naturally as of Sept 11,2026.
--
--       THE TRIGGER IS DYNAMIC. The benchmark is recomputed per week per
--       shift, so it tracks the fleet. As the fleet grew 65 -> 91 vehicles
--       the Peak benchmark moved 39.6 -> 54.4 and the trigger moved
--       27.7 -> 38.1, holding the equivalent KPI trigger steady at 48-52%
--       throughout. If Launchable drops structurally (e.g. OJAI chargers)
--       the trigger follows it down automatically.
--
--    c) RECOVERY — hours immediately after an event where Launchable is
--       still below 75% of the benchmark. These are hours still depressed
--       BY the event; leaving them in would drag the benchmark down.
--
-- 3. Recompute the benchmark excluding all three types. This is
--    "what a normal hour looked like that week, for that shift".
--
-- 4. COUNTERFACTUAL = actual Launchable from clean hours
--                     + (disrupted hour count x benchmark).
--    Every bad hour is credited at that week's own normal rate, NOT at
--    fleet size. Average credit is ~48 vehicles vs ~67 Capable — a ~29%
--    haircut — so the estimate is deliberately conservative.
--
-- 5. LOST HOURS = counterfactual - actual.
--
-- DENOMINATOR
--   RO Capable, matching the 78% CSL definition (Launchable / Capable).
--   Not RO Pool — Pool includes vehicles that were never fit to work.
--
-- =====================================================================
-- VALIDATION vs the manual Excel workbook (Jun 9 - Sep 9, 2026)
-- =====================================================================
--   Disrupted hours : 301 vs 306    (-5)
--   Lost hours      : 12,244 vs 12,278  (-0.3%)
--   % of Capable    : 8.53% vs 8.55%
--   Revenue         : $48,977 vs $49,111
--
--   282 hours agree. 19 flagged by the query but not manually; 24 flagged
--   manually but not by the query. 2.0% of 2,144 hours classified
--   differently.
--
--   Of the query-only hours, several look like genuine misses in the
--   manual tagging — notably 7/15 13:00-18:00 (six consecutive hours at
--   27-47% Launchable-of-Capable, same shape as the construction block,
--   never tagged). The manual-only hours are mostly event boundary hours
--   where the hourly average had not yet collapsed.
--
-- =====================================================================
-- NOTES
-- =====================================================================
--   - is_weather_pause is Waymo's own field and covers WEATHER ONLY. It is
--     carried through as a cause label but NOT used for detection, since it
--     would miss ops-driven events such as the 8/14 lug nut inspection and
--     the 7/4-7/5 construction de-fleet. As of this writing it returns 0
--     rows for the whole period — Waymo have said a populated weather
--     filter is going live shortly. Once it is, split weather vs ops-driven
--     causes using this field.
--   - Shift type comes from date_time_info.peak_classification.demand,
--     NOT supply. Validated against the manual Shift Grid: 71/71 day-hour
--     combinations match, so the Shift Grid tab in excel is redundant.
--   - Period starts 2026-06-09, when Lyft operations began. Earlier data
--     is pre-launch and would distort the benchmark.
--   - Revenue at $4 per RO Ready supply hour (DP1 service fee). This is a
--     conservative floor — it excludes the 12% rev share.
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
  WHERE CAST(ops_depot AS STRING) = "NASHVILLE" -- naville onlt
    AND local_date >= DATE "2026-06-09" -- since launch only
    AND date_time_info.peak_classification.demand.peak_category
        IN ("Off-peak", "Peak", "Standard") 
),

-- STEP 2a: collapse to hourly; flag FULL events ------------------------
hourly AS (
  SELECT
    local_date, week_start, hour_of_day, shift,
    DATETIME_ADD(DATETIME(local_date), INTERVAL hour_of_day HOUR) AS dt,
    AVG(launchable) AS launchable,
    AVG(capable)    AS capable,
    AVG(in_service) AS in_service,
    AVG(pool)       AS pool,
    MAX(CASE WHEN launchable <= 3 AND in_service <= 3 THEN 1 ELSE 0 END) AS is_full_event,
    MAX(CASE WHEN is_weather_pause THEN 1 ELSE 0 END)                    AS weather_flag
  FROM base
  GROUP BY local_date, week_start, hour_of_day, shift
),

-- STEP 2b: pass-1 benchmark, excluding full events only ----------------
bench_p1 AS (
  SELECT week_start, shift,
         AVG(CASE WHEN is_full_event = 0 THEN launchable END) AS b1
  FROM hourly
  GROUP BY week_start, shift
),

-- STEP 2c: flag PARTIAL events (< 70% of that week's normal) -----------
partials AS (
  SELECT
    h.*,
    CASE WHEN h.is_full_event = 0
          AND SAFE_DIVIDE(h.launchable, b.b1) < 0.70
         THEN 1 ELSE 0 END AS is_partial_event
  FROM hourly h
  JOIN bench_p1 b USING (week_start, shift)
),

event_flagged AS (
  SELECT *, GREATEST(is_full_event, is_partial_event) AS is_event
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
         SAFE_DIVIDE(e.launchable, b.b2)       AS ratio_to_benchmark,
         SUM(e.is_event) OVER (ORDER BY e.dt)  AS block_id
  FROM event_flagged e
  JOIN bench_p2 b USING (week_start, shift)
),

-- STEP 2f: flag RECOVERY hours -----------------------------------------
-- A clean hour following an event, still under 75% of normal, with no
-- already-recovered hour between it and the end of the event.
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

-- STEP 3: final benchmark, excluding all three flag types --------------
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
  CAST(SUM(f.is_full_event) AS INT64)            AS full_event_hours,
  CAST(SUM(f.is_partial_event) AS INT64)         AS partial_event_hours,
  CAST(SUM(f.is_recovery) AS INT64)              AS recovery_hours,
  CAST(SUM(f.weather_flag) AS INT64)             AS weather_flagged_hours, --- But it currently returns 0 everywhere.Once it's populated, this column starts returning real values and you can split weather from ops-driven causes without changing anything else in the query.
  ROUND(b.benchmark, 4)                          AS clean_hour_benchmark,

  ROUND(SUM(f.launchable), 4)                    AS actual_launchable_hrs,

  ROUND(SUM(CASE WHEN f.is_bad = 0 THEN f.launchable ELSE 0 END)
        + SUM(f.is_bad) * b.benchmark, 4)        AS counterfactual_hrs,

  ROUND(SUM(CASE WHEN f.is_bad = 0 THEN f.launchable ELSE 0 END)
        + SUM(f.is_bad) * b.benchmark
        - SUM(f.launchable), 4)                  AS lost_launchable_hrs,

  ROUND(SUM(f.capable), 4)                       AS capable_hrs,
  ROUND(SUM(f.pool), 4)                          AS pool_hrs,

  ROUND((SUM(CASE WHEN f.is_bad = 0 THEN f.launchable ELSE 0 END)
        + SUM(f.is_bad) * b.benchmark
        - SUM(f.launchable)) * 4, 2)             AS revenue_lost_usd

FROM flagged f
JOIN bench_final b USING (week_start, shift)
GROUP BY f.local_date, f.week_start, f.shift, b.benchmark
ORDER BY f.local_date, f.shift
