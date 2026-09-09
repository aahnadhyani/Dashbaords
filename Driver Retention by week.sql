-- ==========================================================================
-- VALIDATE: "Driver retention by week"
--
-- Recomputes the chart from source, independently of the Hex cells. Run in
-- the Trino adhoc window, then compare row by row.
--
-- One statement. Paste the whole thing. No semicolons anywhere.
-- Always reads live data. The only hardcoded date is a lower bound.
--
-- ┌────────────────────────────────────────────────────────────────────────┐
-- │ HOW TO COMPARE                                                         │
-- │                                                                        │
-- │ Set the market filter to ALL, then match SECTION A:                    │
-- │   drivers       = the bars                                             │
-- │   pct_retained  = the line                                             │
-- │                                                                        │
-- │ SECTION B is per-market for the filtered view. SECTION C names the     │
-- │   individual drivers who churned, which is what you actually want when │
-- │   somebody asks why retention dropped.                                 │
-- └────────────────────────────────────────────────────────────────────────┘
--
-- ══ WHAT "RETAINED" MEANS HERE ══
--
--   A driver counts as retained if they held ANY programme vehicle the
--   following week. Not the same vehicle -- a swap reads as retention,
--   which matches how Ops defines tenure (same-category swaps do not reset
--   it, only gaps do).
--
--   The metric is forward-looking: the figure on week N answers "did these
--   drivers come back in week N+1". That is why the most recent week is
--   always blank -- you cannot know until the following week completes.
--
--   This is deliberately NOT average tenure. With a fleet a few weeks old
--   and almost nobody having left, average tenure just measures elapsed
--   time and reads as a retention problem that does not exist.
--
-- ══ THE BIG CAVEAT: VEHICLE-CAUSED CHURN ══
--
--   A car going out of service ends the rental regardless of what the
--   driver wanted. That shows up here as churn, but it is a fleet problem,
--   not a driver problem. At least one of the churn events to date was the
--   damaged CHI vehicle.
--
--   SECTION C flags this. For each churned driver it shows whether their
--   vehicle was out of service during the week they failed to return. Read
--   pct_retained as a FLOOR on driver satisfaction, not a measure of it.
--
-- THREE MORE THINGS THAT LOOK WRONG BUT ARE NOT
--
--   1. THE MOST RECENT WEEK IS BLANK. Not missing data -- the metric needs
--      the following week to exist. On the chart it gaps rather than
--      plotting zero.
--
--   2. PER-MARKET RETENTION CAN DOUBLE-COUNT. A driver who switches market
--      between weeks reads as churn in the market they left and as a new
--      driver in the one they joined. Fleet-wide totals are unaffected.
--      Section B carries this caveat.
--
--   3. PERCENTAGES SWING HARD. At 6-7 drivers, one person moves the figure
--      14-17 points. Read the counts.
--
-- WHAT THIS PROVES
--   That the dashboard computes retention correctly from the rental table.
--   There is no external source to check retention against -- unlike
--   bonuses, which reconcile to the Ops payout sheet.
-- ==========================================================================

with fm_vins as (
    -- The vehicle cohort.
    --
    -- model like 'Cla%' IS DELIBERATE. One VIN carries model = 'Cla' while
    -- the other 24 read 'Cla-Class Ev'. An exact match silently dropped that
    -- car -- live and on rent at the time -- along with the entire PHI
    -- market. Do not tighten this.
    --
    -- ds filter required, LOWER BOUND ONLY. Open status intervals carry the
    -- sentinel 9999-01-01, so an upper bound drops the live fleet.
    select distinct upper(trim(vin)) as vin
    from xdsa.xd_fleet_status_interval
    where vehicle_class          = 'WP_HYBRID'
      and make                   = 'Mercedes-Benz'
      and model like 'Cla%'
      and vehicle_provider_id    = 'FLEXDRIVE'
      and vehicle_operation_type = 'RENTAL'
      and ds >= '2026-01-01'
),

oos_intervals as (
    -- Every period a programme vehicle spent out of service. Used in
    -- section C to tell vehicle-caused churn from driver-initiated churn.
    --
    -- Uses the interval HISTORY, not current status, so a car repaired
    -- later still reads as out of service for the week it was broken.
    select
        upper(trim(s.vin))                                  as vin,
        s.status_start_time,
        coalesce(s.status_end_time, timestamp '9999-01-01') as status_end_time
    from xdsa.xd_fleet_status_interval s
    where s.vehicle_class          = 'WP_HYBRID'
      and s.make                   = 'Mercedes-Benz'
      and s.model like 'Cla%'
      and s.vehicle_provider_id    = 'FLEXDRIVE'
      and s.vehicle_operation_type = 'RENTAL'
      and s.ds >= '2026-01-01'
      and s.status in ('DAMAGED','CLAIM','INSPECTION','HOLD',
                       'MAINTENANCE','SERVICE','RECALL')
),

driver_weeks as (
    -- Every (driver, market, vehicle, Mon-Sun week) where the driver held a
    -- programme vehicle.
    --
    -- Expanding to days then truncating handles rentals straddling week
    -- boundaries. Rentals are anchored to each driver's own pickup time, so
    -- effectively all of them straddle.
    --
    -- Zero-length rentals excluded: one exists (start = end = 2026-08-20,
    -- replaced the same day) and would double-count a driver-week.
    select distinct
        cast(r.lyft_id as varchar)      as driver_id,
        r.region                        as market,
        upper(trim(r.vin))              as vin,
        date(date_trunc('week', d))     as week_start
    from core.dimension_rentals r
    join fm_vins v on v.vin = upper(trim(r.vin))
    cross join unnest(sequence(
        date(r.start_date_time),
        date(coalesce(r.end_date_time, current_timestamp)),
        interval '1' day
    )) as t(d)
    where r.end_date_time is null
       or r.end_date_time > r.start_date_time
),

-- collapse to one row per driver-week regardless of how many vehicles they
-- touched, so a mid-week swap does not count as two drivers
dw as (
    select distinct driver_id, week_start from driver_weeks
),

dw_market as (
    select distinct driver_id, week_start, market from driver_weeks
),

retention as (
    select
        d.driver_id,
        d.week_start,
        n.driver_id is not null     as returned,
        -- the newest week cannot be measured yet: no following week exists
        d.week_start < (select max(week_start) from dw) as measurable
    from dw d
    left join dw n
      on n.driver_id = d.driver_id
     and n.week_start = d.week_start + interval '7' day
)

-- ---- SECTION A: all markets -- matches the chart with no filter ----------
select
    'A ALL MARKETS'                                     as section,
    cast(r.week_start as varchar)                       as week,
    ''                                                  as market,
    cast(count(*) as varchar)                           as drivers,
    case when max(r.measurable) then cast(count_if(r.returned) as varchar)
         else 'n/a' end                                 as returned,
    case when max(r.measurable) then cast(count_if(not r.returned) as varchar)
         else 'n/a' end                                 as churned,
    case when max(r.measurable)
         then cast(cast(round(100.0 * count_if(r.returned) / count(*), 1)
                   as decimal(5,1)) as varchar) || '%'
         else 'pending -- needs next week' end          as pct_retained
from retention r
group by r.week_start

union all

-- ---- SECTION B: by market -- matches the chart when filtered -------------
-- CAVEAT: a driver who switches market reads as churn in the market they
-- left and as new in the one they joined. Fleet-wide totals are unaffected.
select
    'B BY MARKET',
    cast(r.week_start as varchar),
    m.market,
    cast(count(*) as varchar),
    case when max(r.measurable) then cast(count_if(r.returned) as varchar)
         else 'n/a' end,
    case when max(r.measurable) then cast(count_if(not r.returned) as varchar)
         else 'n/a' end,
    case when max(r.measurable)
         then cast(cast(round(100.0 * count_if(r.returned) / count(*), 1)
                   as decimal(5,1)) as varchar) || '%'
         else 'pending' end
from retention r
join dw_market m on m.driver_id = r.driver_id and m.week_start = r.week_start
group by r.week_start, m.market

union all

-- ---- SECTION C: who churned, and why -------------------------------------
-- Names each driver who did not return, and flags whether their vehicle was
-- out of service during the following week. A vehicle-caused loss is a
-- fleet problem showing up as driver churn.
--
-- Uses interval history rather than current status, so this stays correct
-- after a car is repaired.
select
    'C CHURN DETAIL',
    cast(r.week_start as varchar),
    m.market,
    r.driver_id,
    dwv.vin,
    case when o.vin is not null then 'VEHICLE OUT OF SERVICE'
         else 'driver did not return' end,
    case when o.vin is not null
         then 'fleet issue -- not driver churn'
         else 'genuine churn -- driver chose to leave' end
from retention r
join dw_market m  on m.driver_id  = r.driver_id and m.week_start = r.week_start
join (select distinct driver_id, week_start, vin from driver_weeks) dwv
  on dwv.driver_id = r.driver_id and dwv.week_start = r.week_start
left join oos_intervals o
  on  o.vin = dwv.vin
  and o.status_start_time < cast(r.week_start + interval '14' day as timestamp)
  and o.status_end_time   > cast(r.week_start + interval '7'  day as timestamp)
where r.measurable and not r.returned

order by 1, 2, 3
