-- ==========================================================================
-- VALIDATE: "Bonus spend by week"
--
-- Recomputes the chart from source, independently of the Hex cells. Run in
-- the Trino adhoc window, then compare row by row.
--
-- One statement. Paste the whole thing. No semicolons anywhere.
-- Always reads live data -- the only hardcoded dates are lower bounds, so
-- new weeks appear automatically and nothing needs editing over time.
--
-- ┌────────────────────────────────────────────────────────────────────────┐
-- │ HOW TO COMPARE                                                         │
-- │                                                                        │
-- │ Set the dashboard's market filter to ALL, then match SECTION A:        │
-- │   total_paid      = the blue bars (left axis)                          │
-- │   avg_per_earner  = the orange line (right axis)                       │
-- │                                                                        │
-- │ The chart rounds to whole dollars, so an avg of $121.43 displays as     │
-- │ $121 or $122. That is display rounding, not a mismatch.                │
-- │                                                                        │
-- │ To check the filtered view, select one market and match SECTION B.     │
-- └────────────────────────────────────────────────────────────────────────┘
--
-- FOUR THINGS THAT LOOK WRONG BUT ARE NOT
--
--   1. THE MOST RECENT COMPLETE WEEK IS ABSENT from sections A and B.
--      Bonuses are disbursed the Tuesday AFTER the week they are earned, so
--      that week has no payouts yet. It appears in section C. On the chart
--      it shows as a gap, never a zero bar. Absence here is correct.
--
--   2. THE AVERAGE IS PER EARNING DRIVER, not per driver in the programme.
--      Denominator is drivers_paid, not the full driver count. A week where
--      6 of 7 drivers earned $1,165 gives $194.17, not $166.43. This is
--      deliberate -- nobody is actually paid $166, and mixing "how many
--      qualified" into "how much did they get" makes the line unreadable.
--
--   3. THE AVERAGE RISES SHARPLY IN EARLY WEEKS. That is proration
--      unwinding, not a change to the incentive. Drivers who picked up
--      mid-week faced prorated thresholds AND prorated payouts -- Top tier
--      on a 3-day rental pays 250 x 3/7 = $107.14. As they move onto full
--      weeks the payouts step up to the full $140/$175/$250.
--
--   4. TOTALS TRACK DRIVER COUNT as much as performance. More drivers means
--      more bonuses regardless of how hard anyone worked. The average line
--      is the per-head signal, the bars are programme cost.
--
-- WHAT THIS PROVES
--   That the dashboard aggregates the bonus ledger correctly. It reads the
--   same tables, so it cannot prove the ledger itself is right. The
--   independent check for that is the payout tracker spreadsheet, which has
--   reconciled to the cent every time it has been run.
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

legal_tiers (amount_usd) as (
    -- 3 tiers x 7 day-fractions, prorated. Anything NOT on this list is not
    -- a mapping bonus. localOfficeStaffBonusDriver is a generic manual
    -- adjustment bucket that also carries tow-downtime refunds, flat-tire
    -- compensation, mileage corrections and at least one test entry.
    --
    -- Full week:  140 / 175 / 250
    -- 6/7:        120 / 150 / 214.29
    -- 5/7:        100 / 125 / 178.57
    -- 4/7:         80 / 100 / 142.86
    -- 3/7:         60 /  75 / 107.14
    -- 2/7:         40 /  50 /  71.43
    -- 1/7:         20 /  25 /  35.71
    values (140.00), (175.00), (250.00),
           (120.00), (150.00), (214.29),
           (100.00), (125.00), (178.57),
           ( 80.00),           (142.86),
           ( 60.00), ( 75.00), (107.14),
           ( 40.00), ( 50.00), ( 71.43),
           ( 20.00), ( 25.00), ( 35.71)
),

driver_weeks as (
    -- Every (driver, market, Mon-Sun week) where the driver held a program
    -- vehicle. Used to scope payouts and to supply the market dimension.
    --
    -- Expanding to days then truncating handles rentals straddling week
    -- boundaries. Rentals are anchored to each driver's own pickup time, so
    -- effectively every rental straddles two calendar weeks.
    --
    -- Zero-length rentals excluded: one exists (start = end = 2026-08-20,
    -- replaced the same day) and would double-count a driver-week.
    select distinct
        cast(r.lyft_id as varchar)      as driver_id,
        r.region                        as market,
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

bonuses as (
    -- event_driver_bonus is an EVENT log, not a state table. One bonus emits
    -- several rows as it moves pending -> finalized, so dedupe on bonus_id
    -- or every total doubles.
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
    -- local-office bonus leaks in -- the first build returned $857.14 for a
    -- week whose real total was $607.14. Scoped on driver AND week, so a
    -- bonus paid to a program driver in a week they were not holding a
    -- program vehicle is also correctly excluded.
    select bo.*, dw.market
    from bonuses bo
    join driver_weeks dw
      on dw.driver_id = bo.driver_id and dw.week_start = bo.week_start
    where bo.rn = 1
),

weekly_denom as (
    select week_start, count(distinct driver_id) as drivers_held_vehicle
    from driver_weeks group by 1
)

-- ---- SECTION A: all markets -- matches the chart with no filter ----------
select
    'A ALL MARKETS'                                     as section,
    cast(s.week_start as varchar)                       as week,
    ''                                                  as market,
    '$' || cast(round(sum(s.amount_usd), 2) as varchar) as total_paid,
    cast(count(*) as varchar)                           as drivers_paid,
    '$' || cast(round(sum(s.amount_usd)/count(*), 2) as varchar)
                                                        as avg_per_earner,
    cast(d.drivers_held_vehicle as varchar)             as drivers_held_vehicle,
    -- for reference only, NOT what the chart line shows
    '$' || cast(round(sum(s.amount_usd)/nullif(d.drivers_held_vehicle,0), 2) as varchar)
                                                        as avg_per_all_drivers
from scoped s
join weekly_denom d on d.week_start = s.week_start
group by s.week_start, d.drivers_held_vehicle

union all

-- ---- SECTION B: by market -- matches the chart when filtered -------------
select
    'B BY MARKET',
    cast(s.week_start as varchar),
    s.market,
    '$' || cast(round(sum(s.amount_usd), 2) as varchar),
    cast(count(*) as varchar),
    '$' || cast(round(sum(s.amount_usd)/count(*), 2) as varchar),
    '', ''
from scoped s
group by s.week_start, s.market

union all

-- ---- SECTION C: cumulative by market -------------------------------------
-- Cross-check against the "Total bonuses paid" tile. These should sum to it.
select
    'C CUMULATIVE',
    '',
    s.market,
    '$' || cast(round(sum(s.amount_usd), 2) as varchar),
    cast(count(*) as varchar),
    '$' || cast(round(sum(s.amount_usd)/count(*), 2) as varchar),
    '', ''
from scoped s
group by s.market

union all

-- ---- SECTION D: weeks awaiting payout ------------------------------------
-- Drivers held vehicles but no bonuses exist yet. The chart gaps here rather
-- than plotting a zero bar. If a week appears here that should have been
-- paid, either the payout run has not happened or the earning-week
-- derivation has drifted.
select
    'D PENDING',
    cast(d.week_start as varchar),
    '', '', '', '',
    cast(d.drivers_held_vehicle as varchar),
    'awaiting payout'
from weekly_denom d
left join scoped s on s.week_start = d.week_start
group by d.week_start, d.drivers_held_vehicle
having count(s.driver_id) = 0

order by 1, 2, 3
