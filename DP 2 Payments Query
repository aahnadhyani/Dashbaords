###### 1 
-- =============================================================================
-- [Audit] Cancelled rides we don't owe  —  DP2 Waymo Supply Sharing
-- =============================================================================
-- Purpose: identify matched-but-not-completed Waymo rides where Lyft was charged
--          the $4.99 minimum ride fee but the contractual exemption should apply.
--
-- Contract terms this query is meant to encode:
--   Lyft pays Waymo $4.99 when a MATCHED ride is not successfully completed,
--   UNLESS:
--     (a) cancelled by the RIDER within 5 minutes of the MATCH, or
--     (b) caused by Waymo technical/mechanical issues.
--
-- ANNOTATION KEY
--   [Q#  -> LINDSEY]   question for the query author, blocks any edit
--   [Q#  -> CONTRACT]  question for commercial/contract owner
--   [Q#  -> FINANCE]   question for Finance / Payments
--   [CHANGE-x]         spot I expect to edit when updating for the returned file
--   [PARAM]            value that must be hand-edited every invoice cycle
--
-- NOTE: the original file contained a large commented-out ledger query
--       (partnerFee / partnerCancelFee against the Dynamo ledger tables,
--       with hardcoded ride IDs and manual dollar overrides).
--       It is excluded here. [Q0 -> LINDSEY] is that block dead, or does
--       someone uncomment it each month? If it's live, it needs its own review.
-- =============================================================================

USE hive.default;


with
waymo_rides as (
select r.ride_id,
       ride_status,                    -- [Q1 -> LINDSEY] selected but never filtered on.
                                       --   The $4.99 fee only applies to matched rides that
                                       --   were NOT completed. Can a completed ride carry a
                                       --   penalty row and end up in this audit wrongly?
                                       --   Should we add: and ride_status <> 'completed'ct
       route_id,
       autonomous_provider_id,

       requested_at_local,
       canceled_at_local,
       completed_at_local,

       accepted_at_local,              -- [Q2 -> LINDSEY] see Q9 — accepted_at + canceled_at
       arrived_at_local,               --   would let us compute the 5-min window directly
       picked_up_at_local,             --   instead of relying on the p2_time proxy below.
       dropped_off_at_local,

       cancel_type,                    -- [Q3 -> LINDSEY] cancel_type / cancel_reason / canceled_by
       cancel_reason,                  --   are all selected but never used in the final WHERE.
       is_canceled_after_accepted,     --   The exemption is RIDER cancels specifically.
       is_canceled_after_arrived,      --   Is rider-cancel already implied by the
       canceled_by,                    --   event_cancels_driver_paid_for_route table, or are we
                                       --   currently letting Lyft-side cancels into the
                                       --   "we don't owe" list? (We probably DO owe those.)

       rider_payment_usd, -- includes tips, but likely no tips on AV
       f.bookings_adjusted as ride_bookings
                                       -- [Q4 -> LINDSEY] rider_payment_usd and ride_bookings are
                                       --   selected but not used in the final output. Dropping
                                       --   them would remove the join below entirely — is the
                                       --   join to ride_financial_metrics needed for this audit?


  FROM hive.coco.fact_rides r
  left join iceberg.rifi.ride_financial_metrics f
    on r.ride_id = f.ride_id
    and f.ds >= '2026-07-01'           -- [Q5 -> LINDSEY] FAN-OUT RISK.
                                       --   Is ride_financial_metrics one row per ride, or a
                                       --   daily snapshot? With an open-ended ds >= filter, a
                                       --   snapshot table multiplies every ride by the number
                                       --   of days present. Sanity check:
                                       --     select count(*), count(distinct ride_id) from ...
 where autonomous_provider_id = 'waymo'
   and ride_request_region = 'BNA'     -- [Q6 -> LINDSEY] Nashville only. Intentional, or are
                                       --   there other DP2 regions live that should be here?
   and r.ds >= '2026-07-01'                                                     -- [PARAM]
   and date_trunc('month',requested_at_local) = date('2026-08-01')              -- [PARAM]
                                       -- [Q7 -> LINDSEY] the header of the original file said
                                       --   "July 2026 invoice" but this filter is August, and
                                       --   the event table below uses 2026-07-04. Three dates,
                                       --   three values. Which one defines the invoice period?
                                       -- [CHANGE-A] these should become a single parameter so
                                       --   the month can't be changed in one place and missed
                                       --   in another. Suggested:
                                       --     with params as (select date('2026-08-01') as invoice_month)
                                       --   and reference it everywhere below.
)


-- =============================================================================
-- MAIN OUTPUT
-- =============================================================================
-- [CHANGE-B] This is where the Waymo returned-rides file needs to land.
--   The live query currently has NO adjustment mechanism — no ride-ID list, no
--   manual overrides, no reason codes. Whatever gets returned by Waymo has to be
--   joined in as a new CTE. Proposed shape (to confirm with Finance):
--
--     adjustments as (
--       select * from (values
--         (<ride_id>, <corrected_amount>, '<reason>', '<source>', date '2026-09-xx')
--       ) as t(ride_id, adj_amount, adj_reason, adj_source, adj_date)
--     )
--
--   ...then LEFT JOIN it below and coalesce(adj_amount, partner_payment),
--   plus an is_manual_adjustment flag column so Payments can see which rows
--   were touched instead of the adjustment being invisible in the total.
--
-- [Q8 -> FINANCE] before this gets written: does the returned file carry
--   corrected amounts, or only ride IDs? Are these rides being ADDED to this
--   audit, REMOVED from it, or RE-PRICED? And does the correction restate
--   August, or land as a September credit? Those produce different queries.

select wr.route_id,
       wr.ride_id,
       date(wr.requested_at_local) as ride_request_date_local,
       1.0*a.driver_penalty_amount_minor/100 as partner_payment
                                       -- [Q9 -> CONTRACT] this reads whatever the upstream
                                       --   penalty field holds — it does not assert $4.99.
                                       --   Is the minimum ride fee still $4.99 and still flat?
                                       --   If upstream ever writes a wrong penalty, it flows
                                       --   straight into the invoice unchallenged. Worth adding
                                       --   a guard/flag for any row where the value <> 4.99.

 from hive.events.event_cancels_driver_paid_for_route a
 join waymo_rides wr
   on a.route_id = wr.route_id
                                       -- [Q10 -> LINDSEY] FAN-OUT RISK #2.
                                       --   Can one route produce more than one row in
                                       --   event_cancels_driver_paid_for_route? And is route_id
                                       --   1:1 with ride_id for Waymo, or can a route carry
                                       --   multiple rides? Either would duplicate penalties.
                                       --   Check: count(*) vs count(distinct route_id).

where ds >= '2026-07-04'                                                        -- [PARAM]
                                       -- [Q11 -> LINDSEY] why 07-04 here when the CTE uses
                                       --   07-01? Deliberate (table didn't exist before then?)
                                       --   or leftover from a previous run?

-- and autonomous_provider_id = '2'
                                       -- [Q12 -> LINDSEY] commented-out filter using '2' as the
                                       --   provider, where the CTE uses the string 'waymo'.
                                       --   Different encoding in this table? Safe to delete,
                                       --   or was it disabled for a reason?

and arrived_not_bailout = false -- means vehicle has arrived already
                                       -- [Q13 -> LINDSEY]  *** HIGHEST PRIORITY ***
                                       --   The inline comment says this means the vehicle HAS
                                       --   arrived, but a field named "arrived_not_bailout" set
                                       --   to FALSE reads more naturally as "did NOT arrive."
                                       --   If the comment is wrong, this query is returning the
                                       --   exact complement of what it intends — which is the
                                       --   kind of thing that produces a mis-invoice.
                                       --   Please confirm against the field definition, or spot
                                       --   check a few rows against arrived_at_local in the CTE.
                                       -- [CHANGE-C] may need to flip to = true.

and p2_time_in_seconds < 300
                                       -- [Q14 -> LINDSEY] is p2_time accept-to-cancel, or
                                       --   accept-to-ARRIVAL? Does it even populate on cancels?
                                       --   If it's arrival-based, then combining it with
                                       --   arrived_not_bailout = false (Q13) may be filtering to
                                       --   a slice that doesn't mean what we think.
                                       -- [Q15 -> CONTRACT] the contract says "cancelled by a
                                       --   rider within 5 minutes of the MATCH." p2_time is a
                                       --   proxy for that. Does the clock start at match,
                                       --   accept, or dispatch?
                                       -- [CHANGE-D] if the contract clock is match/accept-based,
                                       --   replace this proxy with the literal term using fields
                                       --   already in the CTE:
                                       --     date_diff('second', wr.accepted_at_local,
                                       --                         wr.canceled_at_local) < 300

and driver_penalty_amount_minor > 0
                                       -- fine as-is: only rows we were actually charged for.

order by occurred_at DESC


-- =============================================================================
-- MISSING LOGIC  —  [CHANGE-E]
-- =============================================================================
-- [Q16 -> CONTRACT] The contract lists TWO exemptions. This query only covers
--   the first (rider cancel inside 5 min). Nothing here captures cancels caused
--   by Waymo technical/mechanical issues, which have NO time limit.
--   How are those identified in our data — a cancel_reason value, a separate
--   event, something only Waymo can tell us?
--   As written, this audit UNDERSTATES what we're owed back.
--
-- [Q17 -> FINANCE] what does this output feed? A standalone credit line, or
--   does it net against the total from one of the other queries in the set?
--   Need to know before adding rows to it.
--
-- [Q18 -> LINDSEY] which of the several queries is the one Payments actually
--   runs for the invoice total, and how do the others relate to it — audit-only,
--   or do they feed the number?
