-- ==========================================================================
-- VALIDATE: "Fleet status by market"
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
-- │ SECTION A matches the chart directly -- one row per market per stack   │
-- │   segment. SECTION B gives the bucket totals. SECTION C is the raw     │
-- │   status behind each bucket, which is where a bucketing dispute gets   │
-- │   settled. SECTION D lists every vehicle individually.                 │
-- └────────────────────────────────────────────────────────────────────────┘
--
-- ══ THIS CHART IS A SNAPSHOT, NOT A WEEKLY FIGURE ══
--
--   It shows where each vehicle sits RIGHT NOW, via is_current_row. It does
--   not respond to a week selection and it cannot be compared to a past
--   week. Reconstructing historical fleet state would mean replaying the
--   interval rows, which the dashboard deliberately does not do.
--
--   So this is the one chart where re-running the query minutes later can
--   legitimately give a different answer -- a car changing status is a real
--   event, not drift.
--
-- ══ THE BUCKETING IS A DRAFT ══
--
--   xd_fleet_status_interval has 33 downstream dashboards. Somebody at Lyft
--   has already agreed how to group these statuses. Until that mapping is
--   found and copied, our fleet counts may not match the rest of the org.
--   Section C exists so the raw statuses are visible and any disagreement
--   can be traced to a specific status rather than argued in the abstract.
--
--   NOTE: the literal OUT_OF_SERVICE status has only ~14 intervals across
--   the entire Flexdrive fleet, so it is NOT the downtime bucket. Real
--   downtime shows up as DAMAGED, CLAIM, INSPECTION, MAINTENANCE, SERVICE
--   or RECALL. Anyone mapping "Out of Service" to the literal status would
--   report near-zero downtime forever.
--
-- THREE MORE THINGS THAT LOOK WRONG BUT ARE NOT
--
--   1. "NOT IN FLEET YET" IS THE LARGEST BUCKET. Correct -- the programme
--      is ramping to 25 vehicles and most have not arrived. Those are
--      ORDERED, PRODUCED and INFLEETING. Excluding them would hide the ramp
--      and drop whole markets off the chart.
--
--   2. VEHICLES ON RENT IS LOWER THAN VEHICLES DEPLOYED. The gap is cars
--      that are ready but unrented plus anything out of service. That gap
--      is the actionable number on this chart.
--
--   3. A MARKET CAN HAVE VEHICLES BUT NO DRIVERS. Several do. Those markets
--      appear here but are absent from the rides and bonus charts, which
--      only know about vehicles that have been rented.
--
-- WHAT THIS PROVES
--   That the dashboard reads and buckets the status table correctly. It
--   cannot verify the statuses themselves -- that would need Fleet Ops.
-- ==========================================================================

with cohort as (
    -- Current status of every programme vehicle.
    --
    -- model like 'Cla%' IS DELIBERATE. One VIN carries model = 'Cla' while
    -- the other 24 read 'Cla-Class Ev'. An exact match silently dropped that
    -- car -- live and on rent at the time -- along with the entire PHI
    -- market. Do not tighten this.
    --
    -- ds filter required, LOWER BOUND ONLY. Open status intervals carry the
    -- sentinel 9999-01-01 in ds, so any upper bound or BETWEEN drops every
    -- vehicle's live row and the chart silently empties.
    --
    -- is_current_row is what makes this a snapshot.
    select
        upper(trim(s.vin))          as vin,
        s.region                    as market,
        s.status,
        s.location_id,
        s.status_start_time,
        s.interval_days,
        case s.status
            when 'ACTIVE'        then '1 - On Rent'
            when 'AVAILABLE'     then '2 - Available'
            when 'STAGED'        then '2 - Available'
            when 'STAGING_READY' then '2 - Available'
            when 'CHARGING'      then '2 - Available'
            when 'DAMAGED'       then '3 - Out of Service'
            when 'CLAIM'         then '3 - Out of Service'
            when 'INSPECTION'    then '3 - Out of Service'
            when 'HOLD'          then '3 - Out of Service'
            when 'MAINTENANCE'   then '3 - Out of Service'
            when 'SERVICE'       then '3 - Out of Service'
            when 'RECALL'        then '3 - Out of Service'
            when 'ORDERED'       then '4 - Not In Fleet Yet'
            when 'PRODUCED'      then '4 - Not In Fleet Yet'
            when 'INFLEETING'    then '4 - Not In Fleet Yet'
            -- anything landing here is a status the bucketing does not
            -- know about. It will show up as "5 - Other" in section A,
            -- which is the signal to extend the CASE above.
            else '5 - Other'
        end                         as fleet_bucket
    from xdsa.xd_fleet_status_interval s
    where s.vehicle_class          = 'WP_HYBRID'
      and s.make                   = 'Mercedes-Benz'
      and s.model like 'Cla%'
      and s.vehicle_provider_id    = 'FLEXDRIVE'
      and s.vehicle_operation_type = 'RENTAL'
      and s.is_current_row
      and s.ds >= '2026-01-01'
)

-- ---- SECTION A: matches the chart -- one row per stack segment -----------
select
    'A CHART'                                   as section,
    market,
    fleet_bucket                                as bucket,
    cast(count(*) as varchar)                   as vehicles,
    cast(cast(round(avg(interval_days), 1) as decimal(10,1)) as varchar)
                                                as avg_days_in_status
from cohort
group by market, fleet_bucket

union all

-- ---- SECTION B: bucket totals -- matches the legend ----------------------
select
    'B BUCKET TOTAL', '', fleet_bucket,
    cast(count(*) as varchar),
    cast(cast(round(avg(interval_days), 1) as decimal(10,1)) as varchar)
from cohort
group by fleet_bucket

union all

-- ---- SECTION C: raw statuses behind each bucket --------------------------
-- Where a bucketing dispute gets settled. If somebody disagrees with the
-- grouping, this shows exactly which raw status is in which bucket.
select
    'C RAW STATUS', '', fleet_bucket || '  <-  ' || status,
    cast(count(*) as varchar),
    cast(cast(round(avg(interval_days), 1) as decimal(10,1)) as varchar)
from cohort
group by fleet_bucket, status

union all

-- ---- SECTION D: every vehicle, one row each ------------------------------
-- Should be exactly the roster size. Also the place to look when a market
-- count seems off by one.
select
    'D VEHICLE', market, vin || '  ' || status,
    cast(cast(round(interval_days, 1) as decimal(10,1)) as varchar),
    cast(date(status_start_time) as varchar)
from cohort

union all

-- ---- SECTION E: cohort guard ---------------------------------------------
-- CHECK THIS FIRST. The cohort is derived from vehicle attributes, so a car
-- can silently leave if an attribute changes -- that has happened once
-- already, when one VIN's model string differed. If this count drops, a
-- vehicle has vanished from the chart and from every per-vehicle metric.
--
-- Also flags any status not covered by the bucketing CASE.
select
    'E GUARD', '', 'cohort size',
    cast(count(*) as varchar),
    case when count_if(fleet_bucket = '5 - Other') > 0
         then 'CHECK -- ' || cast(count_if(fleet_bucket = '5 - Other') as varchar)
              || ' vehicle(s) in an unmapped status'
         else 'all statuses mapped' end
from cohort

order by 1, 2, 3
