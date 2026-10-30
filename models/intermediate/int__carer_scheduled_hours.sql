-- Intermediate: "scheduled" pillar of the carer hours report — recurr occurrences
-- aggregated per carer per occurrence date, so the mart can filter by date
-- (Power BI) or roll up to one row per carer for the selected range.
--
-- Grain: source + carer_id + location_id + job_type_id + service_date
-- (occurrence_date). The care comes through int__recurr_occurrences, which is
-- account-wide like every intermediate.
-- job_type_id (recurr.jobType) is preserved so a per-jobtype mart could reuse
-- this; the carer-level mart re-aggregates over it (group by carer + date).
--
-- Reuses int__recurr_occurrences (the set-based returnDates() port) and
-- applies the carer report's recurr filters (carersHoursRpt.php §3.4):
--   * carerId <> 0        -> assigned templates only (the report scopes by carer)
--   * statusId = 1        -> active templates only
--   * not is_no_show      -> no-show dates are non-delivered, not scheduled
-- confirmSch = 'Yes' is already enforced upstream in recurr_occurrences.
-- The occurrences run on to the capacity outlook's projection horizon; this report
-- stops at its own, today + 60 (macros/report_horizon.sql).

with occurrences as (
    select
        source,
        carerid,
        location_id,
        job_type_id,
        occurrence_date,
        event_minutes
    from {{ ref('int__recurr_occurrences') }}
    where
        not is_no_show
        and statusid = 1
        and carerid <> 0
        and occurrence_date <= {{ report_horizon() }}
),

final as (
    select
        source,
        carerid as carer_id,
        location_id,
        job_type_id,
        occurrence_date as service_date,
        sum(event_minutes) / 60.0 as scheduled_hrs
    from occurrences
    group by 1, 2, 3, 4, 5
)

select * from final
