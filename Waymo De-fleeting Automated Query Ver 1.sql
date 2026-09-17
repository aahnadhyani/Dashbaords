-- ============================================================================
-- WAYMO NASHVILLE — IMPACT OF FLEET PAUSES & DE-FLEETING ON RO LAUNCHABLE
-- ============================================================================
--
-- THE QUESTION THIS ANSWERS
--   When the fleet is paused or de-fleeted, how much launchable supply do we
--   lose? And what would our RO Launchable % have been if it hadn't happened?
--
-- THE SHORT VERSION OF THE METHOD
--   For each week, split the hours into "something went wrong" and "nothing
--   went wrong". Average the good hours to get a benchmark for what a normal
--   hour looked like that week. Then credit every bad hour at that benchmark
--   instead of what actually happened. The difference is the loss.
--
-- WHY THE BENCHMARK IS THAT WEEK'S OWN PERFORMANCE
--   We are NOT claiming every vehicle in the fleet would have been launchable.
--   We only credit what the fleet actually achieved on a normal hour that same
--   week — roughly 48 vehicles against ~67 Capable, a ~29% haircut. It also
--   means the benchmark moves with the fleet: as it grew 65 -> 91 vehicles the
--   benchmark moved 40 -> 56. If Launchable drops structurally (OJAI chargers,
--   the Ellery move) the benchmark follows it down automatically.
--
-- DENOMINATOR
--   RO Capable, matching the 78% CSL definition (Launchable / Capable).
--   Not RO Pool — Pool includes vehicles that were never fit to work.
--
-- OUTPUT
--   One row per calendar day per shift type (Peak / Off-peak / Standard).
--   ~3 rows/day. Every hour column is additive, so roll up to week or month
--   with SUMIFS. Runs inception-to-date with no manual inputs.
--
-- MAINTENANCE
--   Re-run weekly and REPLACE the whole output range rather than appending.
--   Benchmarks recalculate across the full history, so a partial week can
--   shift slightly once it fills in — full replace keeps everything consistent.
--   The $4/hour service fee in the last column is the only hardcoded value.
--
-- VALIDATION (Jun 9 - Sep 13, 2026, vs the manual Excel workbook)
--   Disrupted hours  321 vs 312       (+9)
--   Lost hours    12,551 vs 12,462    (+0.7%)
--   % of Capable    8.00% vs 8.27%
--   Revenue       $50,206 vs $49,850
--   The +9 is largely 6/9 00:00-03:00 — launch-day hours with Launchable at
--   zero that Waymo flags as weather but were never tagged manually.
-- ============================================================================

WITH

-- ============================================================================
-- STEP 1 — GET THE RAW DATA
-- ============================================================================
-- The source table has one row per MINUTE per depot. The vehicle counts live
-- inside a nested field called metrics_set, so we reach into it here and pull
-- out the four funnel stages we need. Doing this in a CTE keeps the nested
-- paths in one place rather than repeating them throughout the query.
--
-- Use funnel_stage.cumulative, NOT .ultimate. Cumulative gives the standard
-- ROSO funnel counts; ultimate is a different breakdown and will not match.
--
-- Shift type comes from the table's own demand.peak_category. We validated
-- this against the manual Shift Grid tab: 71 of 71 day-hour combinations
-- match, so the grid is redundant. Note it must be DEMAND, not supply —
-- supply has different categories and disagrees with our definition.
-- ============================================================================
base AS (
  SELECT
    local_date,
    date_time_info.local.week_start                         AS week_start,
    CAST(date_time_info.local.hour_of_day_display AS INT64) AS hour_of_day,
    date_time_info.peak_classification.demand.peak_category AS shift,

    -- Waymo's own weather flag. Set per minute, from when a weather event is
    -- filed internally to when their team confirms service can resume.
    is_weather_pause,

    metrics_set.vehicle.funnel_stage.cumulative.ro_launchable.minutes AS launchable,
    metrics_set.vehicle.funnel_stage.cumulative.ro_capable.minutes    AS capable,
    metrics_set.vehicle.funnel_stage.cumulative.in_service.minutes    AS in_service,
    metrics_set.vehicle.funnel_stage.cumulative.ro_pool.minutes       AS pool

  FROM waymo_data.ro_utilization.operation_timeline_tvc
  WHERE CAST(ops_depot AS STRING) = 'NASHVILLE'
    -- Lyft operations began 2026-06-09. Earlier data is pre-launch and would
    -- distort the benchmark, so it is excluded from all reporting.
    AND local_date >= DATE '2026-06-09'
    AND date_time_info.peak_classification.demand.peak_category
        IN ('Off-peak', 'Peak', 'Standard')
),


-- ============================================================================
-- STEP 2 — COLLAPSE TO HOURLY, AND FIND THE OBVIOUS OUTAGES
-- ============================================================================
-- Average the 60 minute-rows into one row per hour.
--
-- TWO FLAGS ARE SET HERE:
--
-- is_weather — uses MAX(), so the hour counts as weather if ANY minute within
--   it was flagged. This matters at event boundaries: the Aug 20 pause began
--   at 02:50, so only 10 of that hour's 60 minutes were flagged, but the hour
--   was genuinely disrupted. A test on the hourly AVERAGE would miss it.
--
-- is_zero_hour — Launchable AND In-Service both at or near zero. This is the
--   signature of a full stop: the fleet is present and capable, but nothing
--   is dispatching. We use <= 3 rather than = 0 because the hourly average
--   picks up a few vehicles in the partial minutes at each end of an event.
--   Validated against 66 manually-tagged hours in August: exact match, no
--   false positives.
-- ============================================================================
hourly AS (
  SELECT
    local_date, week_start, hour_of_day, shift,
    DATETIME_ADD(DATETIME(local_date), INTERVAL hour_of_day HOUR) AS dt,

    AVG(launchable) AS launchable,
    AVG(capable)    AS capable,
    AVG(in_service) AS in_service,
    AVG(pool)       AS pool,

    MAX(CASE WHEN is_weather_pause THEN 1 ELSE 0 END) AS is_weather,

    CASE WHEN AVG(launchable) <= 3 AND AVG(in_service) <= 3
         THEN 1 ELSE 0 END                            AS is_zero_hour

  FROM base
  GROUP BY local_date, week_start, hour_of_day, shift
),


-- ============================================================================
-- STEP 3 — WEATHER TAIL: OUTAGE HOURS WAYMO STOPPED TAGGING
-- ============================================================================
-- THE PROBLEM THIS SOLVES
--   Waymo's flag ends when they LIFT the hold. But the fleet often stays at
--   zero for another hour or two before vehicles are actually back out. Those
--   hours are weather-caused but unflagged.
--
--   Checked across all 29 zero-Launchable runs in the data: 25 are fully
--   flagged, 3 are flagged at the start and unflagged at the tail, 1 has no
--   weather flag at all (the 8/14 lug nut inspection). There is not a single
--   case of the flag dropping out MID-outage — the pattern is always
--   "WWWW." never "WW.W" — so this is safe to treat as a tail effect.
--
-- WHAT COUNTS
--   A zero hour, not weather-flagged, where the current unbroken run of zero
--   hours BEGAN with a weather-flagged hour. The two LAST_VALUE windows find
--   the most recent weather-flagged zero hour and the most recent non-zero
--   hour; if the weather hour is more recent, we are still inside that run.
--   This chains correctly through multi-hour tails.
--
-- WHY IT IS A SEPARATE COLUMN, NOT FOLDED INTO is_weather
--   This is OUR classification, not Waymo's. Keeping it separate means anyone
--   reading the output can see exactly where we diverged from their flag.
--
-- NOT THE SAME AS RECOVERY (step 7)
--   weather tail -> Launchable at ZERO. The fleet is still down.
--   recovery     -> Launchable PARTIALLY back, under 75% of normal. The
--                   fleet is coming back, just not yet at full rate.
--
--   Validated Jun 9 - Sep 13: 5 such hours. 7/20 01:00, 8/7 21:00-22:00,
--   8/12 02:00-03:00. Each directly follows a flagged weather block.
-- ============================================================================
seq AS (
  SELECT *,
    -- when was the most recent zero hour that WAS weather-flagged?
    LAST_VALUE(CASE WHEN is_zero_hour = 1 AND is_weather = 1 THEN dt END IGNORE NULLS)
      OVER (ORDER BY dt ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)
                                                       AS last_weather_zero_dt,

    -- when did the fleet last have vehicles out? (i.e. where did this run of
    -- zero hours start)
    LAST_VALUE(CASE WHEN is_zero_hour = 0 THEN dt END IGNORE NULLS)
      OVER (ORDER BY dt ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)
                                                       AS last_nonzero_dt
  FROM hourly
),

classified AS (
  SELECT *,
    CASE
      WHEN is_zero_hour = 1              -- fleet is down
       AND is_weather = 0                -- but Waymo is not flagging it
       AND last_weather_zero_dt IS NOT NULL
       -- and the weather-flagged hour is more recent than the last hour the
       -- fleet was up, meaning we are still inside the same outage
       AND (last_nonzero_dt IS NULL OR last_weather_zero_dt > last_nonzero_dt)
      THEN 1 ELSE 0
    END AS is_weather_tail_full
  FROM seq
),


-- ============================================================================
-- STEP 4 — OPS FULL EVENTS: OUTAGES THAT ARE NOT WEATHER
-- ============================================================================
-- What is left after weather and weather-tail: the fleet went to zero and
-- Waymo does not attribute it to weather. These are ops-driven.
--
-- Over the whole validation period this resolves to exactly ONE event: the
-- 8/14 lug nut inspection, 8 hours. That is a good sign — it means Waymo's
-- weather flag is comprehensive, and the ops bucket is not absorbing
-- unexplained gaps.
--
-- NOTE ON ATTRIBUTION: the vehicle counts alone cannot tell a weather pause
-- from an ops de-fleet — both look identical (Launchable and In-Service at
-- zero). The ONLY thing separating them is Waymo's flag. If they miss coding
-- an event as weather, we will label it ops. Worth re-checking the flag's
-- reliability periodically rather than assuming.
-- ============================================================================
flags_ab AS (
  SELECT *,
    CASE WHEN is_zero_hour = 1
          AND is_weather = 0
          AND is_weather_tail_full = 0
         THEN 1 ELSE 0 END AS is_ops_full
  FROM classified
),


-- ============================================================================
-- STEP 5 — PARTIAL DE-FLEETS: WHEN THE FLEET DIPS BUT NEVER STOPS
-- ============================================================================
-- THE PROBLEM THIS SOLVES
--   The 7/4-7/5 construction work (rolling door replacement, DZ activated,
--   RO operating outside with limited charging) pulled about half the Capable
--   pool for 34 hours. But Launchable only fell to ~58% of normal, never zero.
--   The zero-hour test cannot see it. In the raw numbers it looks identical to
--   a couple of slow days.
--
-- THE RULE
--   Flag an hour where Launchable falls below 70% of that week's clean-hour
--   benchmark for that shift.
--
-- WHY 70%, AND WHAT THAT MEANS IN KPI TERMS
--   70% of benchmark works out to roughly 50% Launchable-of-Capable, against
--   a normal clean-hour KPI of ~72% and a 78% CSL target. So the trigger only
--   fires on a ~22-point collapse below normal. Only ~1% of clean hours ever
--   dip below that line naturally, so the risk of tagging ordinary bad
--   performance as an interruption is low.
--
-- WHY THE TRIGGER IS DYNAMIC
--   The benchmark is recomputed per week per shift, so the threshold moves
--   with the fleet. Across Jun-Sep the Peak benchmark went 39.6 -> 54.4
--   vehicles and the trigger moved 27.7 -> 38.1, holding the equivalent KPI
--   trigger steady at 48-52% throughout. If Launchable drops structurally
--   (OJAI chargers, the Ellery move) the trigger follows it down rather than
--   suddenly flagging everything.
--
-- TWO-PASS BENCHMARK
--   bench_p1 is computed BEFORE partials are known — it has to be, since the
--   partial rule needs something to compare against. We exclude the obvious
--   outages (weather, tail, ops-full) so they do not drag it down. Once
--   partials are identified we recompute in bench_p2.
-- ============================================================================
bench_p1 AS (
  SELECT week_start, shift,
         AVG(CASE WHEN is_weather = 0
                   AND is_weather_tail_full = 0
                   AND is_ops_full = 0
                  THEN launchable END) AS b1
  FROM flags_ab
  GROUP BY week_start, shift
),

partials AS (
  SELECT f.*,
    CASE WHEN f.is_weather = 0
          AND f.is_weather_tail_full = 0
          AND f.is_ops_full = 0
          AND SAFE_DIVIDE(f.launchable, b.b1) < 0.70
         THEN 1 ELSE 0 END AS is_ops_partial
  FROM flags_ab f
  JOIN bench_p1 b USING (week_start, shift)
),

-- an hour is an "event" if it falls into any of the four categories above
event_flagged AS (
  SELECT *,
    GREATEST(is_weather, is_weather_tail_full, is_ops_full, is_ops_partial) AS is_event
  FROM partials
),


-- ============================================================================
-- STEP 6 — RECOMPUTE THE BENCHMARK NOW THAT PARTIALS ARE KNOWN
-- ============================================================================
bench_p2 AS (
  SELECT week_start, shift,
         AVG(CASE WHEN is_event = 0 THEN launchable END) AS b2
  FROM event_flagged
  GROUP BY week_start, shift
),


-- ============================================================================
-- STEP 7 — RECOVERY: THE RAMP-UP AFTER AN EVENT ENDS
-- ============================================================================
-- WHY THESE HOURS MATTER
--   After an outage the fleet does not snap straight back to normal — vehicles
--   have to be redeployed. Those hours are still depressed BY the event. If we
--   left them in the "clean" pool they would drag the benchmark down and we
--   would understate the loss.
--
-- THE RULE
--   An hour following an event where Launchable has partially returned but is
--   still below 75% of the benchmark. Walk forward from the end of each event
--   and stop at the first hour that recovers past 75%.
--
--   block_id increments on every event hour, so all the clean hours following
--   a given event share the same block_id. The windowed MIN finds the first
--   recovered hour in that block; anything before it is still ramping.
--
-- DISTINCT FROM WEATHER TAIL (step 3)
--   Recovery = Launchable partially back. Weather tail = still at zero.
--
-- HONEST CAVEAT
--   This was previously an eyeball judgement in the manual process. The 75%
--   rule reproduces most but not all of those calls — the manual ones did not
--   follow a consistent threshold. Going forward the rule is at least applied
--   consistently, which the manual approach was not.
-- ============================================================================
blocks AS (
  SELECT e.*, b.b2,
         SAFE_DIVIDE(e.launchable, b.b2)      AS ratio_to_benchmark,
         SUM(e.is_event) OVER (ORDER BY e.dt) AS block_id
  FROM event_flagged e
  JOIN bench_p2 b USING (week_start, shift)
),

recovery AS (
  SELECT *,
    CASE
      WHEN is_event = 0                      -- not itself an event hour
       AND ratio_to_benchmark < 0.75         -- still below normal
       -- and no hour between here and the end of the event has recovered
       AND MIN(CASE WHEN ratio_to_benchmark >= 0.75 THEN dt END)
             OVER (PARTITION BY block_id ORDER BY dt
                   ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) IS NULL
      THEN 1 ELSE 0
    END AS is_recovery
  FROM blocks
),

-- is_bad = the hour is disrupted for ANY reason. This is what drives the
-- counterfactual; the individual flags are kept for cause attribution.
flagged AS (
  SELECT *, GREATEST(is_event, is_recovery) AS is_bad
  FROM recovery
),


-- ============================================================================
-- STEP 8 — FINAL BENCHMARK
-- ============================================================================
-- Now that all five categories are known, compute the definitive benchmark:
-- the average Launchable across hours where nothing was wrong, per week per
-- shift. This is the number every disrupted hour gets credited at.
-- ============================================================================
bench_final AS (
  SELECT week_start, shift,
         AVG(CASE WHEN is_bad = 0 THEN launchable END) AS benchmark
  FROM flagged
  GROUP BY week_start, shift
)


-- ============================================================================
-- STEP 9 — BUILD THE COUNTERFACTUAL AND ROLL UP
-- ============================================================================
-- COUNTERFACTUAL = the Launchable hours we actually delivered in clean hours
--                  + (number of disrupted hours x that week's benchmark)
--
-- LOST = counterfactual - actual
--
-- Worked example, Peak in the week of 9/7:
--   58 Peak hours, 6 disrupted, 52 clean. The 52 clean hours are counted as
--   they were. The 6 disrupted hours are credited at ~55.6 vehicles each
--   (that week's Peak benchmark) instead of the near-zero they actually
--   delivered. The difference is the loss.
--
-- The cause columns split the loss between weather and ops so we can report
-- attribution, which previously relied on the ops team's recollection.
-- ============================================================================
SELECT
  f.local_date                                   AS day,
  f.week_start,
  f.shift,

  CAST(COUNT(*) AS INT64)                        AS total_hours,
  CAST(SUM(f.is_bad) AS INT64)                   AS disrupted_hours,

  -- ---- cause breakdown -----------------------------------------------
  -- weather_hours and weather_tail_full_hours are BOTH full de-fleet
  -- (Launchable at zero). The tail column is our label for hours Waymo's
  -- flag stopped short of. recovery_hours is different — partial ramp-up,
  -- not a full outage.
  CAST(SUM(f.is_weather) AS INT64)               AS weather_hours,
  CAST(SUM(f.is_weather_tail_full) AS INT64)     AS weather_tail_full_hours,
  CAST(SUM(f.is_ops_full) AS INT64)              AS ops_full_hours,
  CAST(SUM(f.is_ops_partial) AS INT64)           AS ops_partial_hours,
  CAST(SUM(f.is_recovery) AS INT64)              AS recovery_hours,

  -- ---- the benchmark used for this week/shift -------------------------
  ROUND(b.benchmark, 4)                          AS clean_hour_benchmark,

  -- ---- what actually happened -----------------------------------------
  ROUND(SUM(f.launchable), 4)                    AS actual_launchable_hrs,

  -- ---- what would have happened ----------------------------------------
  ROUND(SUM(CASE WHEN f.is_bad = 0 THEN f.launchable ELSE 0 END)
        + SUM(f.is_bad) * b.benchmark, 4)        AS counterfactual_hrs,

  -- ---- the gap between them = the loss ---------------------------------
  ROUND(SUM(CASE WHEN f.is_bad = 0 THEN f.launchable ELSE 0 END)
        + SUM(f.is_bad) * b.benchmark
        - SUM(f.launchable), 4)                  AS lost_launchable_hrs,

  -- ---- loss attributed to weather (Waymo's flag + our tail) ------------
  ROUND((SUM(f.is_weather) + SUM(f.is_weather_tail_full)) * b.benchmark
        - SUM(CASE WHEN f.is_weather = 1 OR f.is_weather_tail_full = 1
                   THEN f.launchable ELSE 0 END), 4)
                                                 AS lost_hrs_weather,

  -- ---- loss attributed to ops-driven events ----------------------------
  ROUND((SUM(f.is_ops_full) + SUM(f.is_ops_partial)) * b.benchmark
        - SUM(CASE WHEN f.is_ops_full = 1 OR f.is_ops_partial = 1
                   THEN f.launchable ELSE 0 END), 4)
                                                 AS lost_hrs_ops,

  -- ---- loss during ramp-up (can follow either cause) -------------------
  ROUND(SUM(f.is_recovery) * b.benchmark
        - SUM(CASE WHEN f.is_recovery = 1 THEN f.launchable ELSE 0 END), 4)
                                                 AS lost_hrs_recovery,

  -- ---- denominators ----------------------------------------------------
  ROUND(SUM(f.capable), 4)                       AS capable_hrs,
  ROUND(SUM(f.pool), 4)                          AS pool_hrs,

  -- ---- revenue ---------------------------------------------------------
  -- $4 per RO Ready supply hour, the DP1 service fee. A conservative floor:
  -- it excludes the 12% revenue share on Waymo One rides.
  ROUND((SUM(CASE WHEN f.is_bad = 0 THEN f.launchable ELSE 0 END)
        + SUM(f.is_bad) * b.benchmark
        - SUM(f.launchable)) * 4, 2)             AS revenue_lost_usd

FROM flagged f
JOIN bench_final b USING (week_start, shift)
GROUP BY f.local_date, f.week_start, f.shift, b.benchmark
ORDER BY f.local_date, f.shift
