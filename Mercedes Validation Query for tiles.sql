-- ==========================================================================
-- DASHBOARD VALIDATION -- SECTION 1: THE SIX SUMMARY TILES
--
-- Recomputes each tile from source, independently of the Hex cells. Run in
-- the Trino adhoc window and compare to what the dashboard shows.
--
-- One statement. Paste the whole thing. No semicolons anywhere.
--
-- This query always reads live data. The only hardcoded dates are lower
-- bounds and the programme start, so new weeks are picked up automatically
-- and nothing needs editing as time passes.
--
-- WHICH FIGURES ARE STABLE
--   Bonuses, driver counts and fleet counts are exact -- they come from a
--   ledger and a status table, and they only change when something real
--   changes.
--
--   TOTAL RIDES IS NOT STABLE. Ride counts sit at rental grain and get
--   prorated across calendar weeks, so the total re-derives on every run.
--   It moved 1,446 -> 1,437 in a single day. Treat a small drift as normal,
--   not as an error. Anything beyond a few percent is worth investigating.
--
-- WHAT THIS PROVES AND WHAT IT DOES NOT
--   It proves the dashboard's aggregation is right. It cannot prove the
--   source data is right -- it reads the same tables. The only genuinely
--   independent check is the payout tracker spreadsheet, and that covers
--   bonuses only.
-- ==========================================================================

with fm_vins as (
    -- The 25-vehicle cohort, derived from vehicle attributes rather than a
    -- hardcoded VIN list.
    --
    -- model like 'Cla%' IS DELIBERATE. One VIN (W1KFJ1DB6TJ015891) carries
    -- model = 'Cla' while the other 24 read 'Cla-Class Ev'. An exact match
    -- silently dropped that car -- which was live and on rent -- along with
    -- the entire PHI market. Do not tighten this.
    --
    -- ds filter is required, LOWER BOUND ONLY. Open status intervals carry
    -- the sentinel 9999-01-01, so an upper bound drops the live fleet.
    select distinct upper(trim(vin)) as vin
    from xdsa.xd_fleet_status_interval
    where vehicle_class          = 'WP_HYBRID'
      and make                   = 'Mercedes-Benz'
      and model like 'Cla%'
      and vehicle_provider_id    = 'FLEXDRIVE'
      and vehicle_operation_type = 'RENTAL'
      and ds >= '2026-01-01'
),

fleet_now as (
    -- Current status of every cohort vehicle. is_current_row gives the live
    -- state, so this is a snapshot, not a weekly figure.
    select upper(trim(vin)) as vin, status
    from xdsa.xd_fleet_status_interval
    where vehicle_class          = 'WP_HYBRID'
      and make                   = 'Mercedes-Benz'
      and model like 'Cla%'
      and vehicle_provider_id    = 'FLEXDRIVE'
      and vehicle_operation_type = 'RENTAL'
      and is_current_row
      and ds >= '2026-01-01'
),

legal_tiers (amount_usd, bonus_tier) as (
    -- 3 tiers x 7 day-fractions, prorated. Any payout NOT on this list is
    -- not a mapping bonus. localOfficeStaffBonusDriver is a generic manual
    -- adjustment bucket that also carries tow-downtime refunds, flat-tire
    -- compensation and mileage corrections.
    values
        (140.00,'1 - Low'),   (175.00,'2 - Mid'), (250.00,'3 - Top'),
        (120.00,'1 - Low'),   (150.00,'2 - Mid'), (214.29,'3 - Top'),
        (100.00,'AMBIGUOUS'), (125.00,'2 - Mid'), (178.57,'3 - Top'),
        ( 80.00,'1 - Low'),                       (142.86,'3 - Top'),
        ( 60.00,'1 - Low'),   ( 75.00,'2 - Mid'), (107.14,'3 - Top'),
        ( 40.00,'1 - Low'),   ( 50.00,'2 - Mid'), ( 71.43,'3 - Top'),
        ( 20.00,'1 - Low'),   ( 25.00,'2 - Mid'), ( 35.71,'3 - Top')
),

rentals as (
    select
        r.rental_id,
        cast(r.lyft_id as varchar)                      as driver_id,
        upper(trim(r.vin))                              as vin,
        r.start_date_time,
        coalesce(r.end_date_time, current_timestamp)    as end_or_now,
        r.completed_rides
    from core.dimension_rentals r
    join fm_vins v on v.vin = upper(trim(r.vin))
    -- zero-length rentals excluded. One exists (start = end = 2026-08-20,
    -- replaced the same day) and would double-count a driver-week.
    where r.end_date_time is null
       or r.end_date_time > r.start_date_time
),

driver_weeks as (
    -- Every (driver, Mon-Sun week) pair where the driver held a program
    -- vehicle. Expanding to days and truncating handles rentals straddling
    -- week boundaries, which effectively all of them do -- rentals are
    -- anchored to each driver's own pickup time, not to Monday.
    select distinct
        r.driver_id,
        date(date_trunc('week', d)) as week_start
    from rentals r
    cross join unnest(sequence(
        date(r.start_date_time), date(r.end_or_now), interval '1' day
    )) as t(d)
),

bonuses as (
    -- event_driver_bonus is an EVENT log, not a state table. One bonus emits
    -- several rows as it moves pending -> finalized, so dedupe on bonus_id.
    --
    -- earning_week is derived: payouts land the Tuesday AFTER the week the
    -- hours were earned, hence minus 7 days.
    select
        b.driver_id,
        round(b.amount_cents/100.0, 2)  as amount_usd,
        date(date_trunc('week', b.occurred_at) - interval '7' day) as week_start,
        row_number() over (partition by b.bonus_id order by b.occurred_at desc) as rn
    from default.event_driver_bonus b
    join legal_tiers t on t.amount_usd = round(b.amount_cents/100.0, 2)
    where b.ds >= '2026-08-01'
      and b.bonus_type = 'localOfficeStaffBonusDriver'
      and b.state      = 'finalized'
),

scoped as (
    -- *** THIS JOIN IS LOAD-BEARING ***
    -- Scopes payouts to program driver-weeks. Without it an unrelated
    -- local-office bonus leaks in -- week 8/17 validated at $857.14 instead
    -- of $607.14 the first time this was built. Scoped on driver AND week,
    -- so a bonus paid to a program driver in a week they were not holding a
    -- program vehicle is also excluded.
    select bo.*
    from bonuses bo
    join (select distinct driver_id, week_start from driver_weeks) d
      on d.driver_id = bo.driver_id and d.week_start = bo.week_start
    where bo.rn = 1
),

rides_total as (
    -- Prorated across calendar weeks by time overlap, matching how the
    -- dashboard computes it. Complete weeks only -- the in-flight week is
    -- partial and would understate.
    --
    -- This is an ESTIMATE. completed_rides is recorded per rental and
    -- rentals span week boundaries, so rides are split by overlap share.
    -- Verified conserved: the prorated total equals the raw total.
    select sum(
        r.completed_rides
        * cast(date_diff('second',
                greatest(r.start_date_time, cast(w as timestamp)),
                least(r.end_or_now, cast(w + interval '7' day as timestamp))) as double)
          / nullif(date_diff('second', r.start_date_time, r.end_or_now), 0)
    ) as total_rides
    from rentals r
    cross join unnest(sequence(
        date '2026-08-03',
        date_trunc('week', current_date) - interval '7' day,
        interval '7' day
    )) as t(w)
    where r.start_date_time < cast(w + interval '7' day as timestamp)
      and r.end_or_now      > cast(w as timestamp)
)

select '1' as ord, 'Total bonuses paid' as tile,
       '$' || cast(round(sum(amount_usd), 2) as varchar) as expected,
       'sum of all program bonus payouts to date' as note
from scoped

union all
select '2', 'Drivers who earned a bonus',
    cast(round(100.0 * (select count(distinct driver_id) from scoped)
        / nullif((select count(distinct driver_id) from driver_weeks), 0), 1) as varchar) || '%',
    cast((select count(distinct driver_id) from scoped) as varchar) || ' of '
    || cast((select count(distinct driver_id) from driver_weeks) as varchar)
    || ' drivers -- cumulative, only ever rises'

union all
select '3', 'Total rides',
    cast(round(total_rides, 0) as varchar),
    'PRORATED ESTIMATE -- re-derives each run, small drift is normal'
from rides_total

union all
select '4', 'Vehicles on rent now',
    cast(count_if(status = 'ACTIVE') as varchar),
    'current snapshot, not weekly'
from fleet_now

union all
select '5', 'Vehicles deployed',
    cast(count_if(status not in ('ORDERED','PRODUCED','INFLEETING')) as varchar),
    'of ' || cast(count(*) as varchar)
    || ' in cohort -- on rent + available + out of service'
from fleet_now

union all
select '6', 'Drivers participated',
    cast(count(distinct driver_id) as varchar),
    'anyone who ever held a program vehicle, including those who left'
from driver_weeks

union all
select '7', 'COHORT GUARD',
    cast(count(distinct vin) as varchar),
    'CHECK THIS FIRST -- should equal the roster. If it drops, a vehicle '
    || 'has silently left the attribute filter and every per-vehicle number '
    || 'is affected. This has happened once already.'
from fm_vins

order by 1
