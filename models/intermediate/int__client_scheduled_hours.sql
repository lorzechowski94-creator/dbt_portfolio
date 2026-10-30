-- Intermediate: "scheduled" pillar — recurr occurrences aggregated per client
-- per occurrence date, so downstream can filter by date (Power BI) or roll up.
--
-- Grain: source + client_id + location_id + job_type_id + service_date
-- (occurrence_date). The care comes through int__recurr_occurrences, which is
-- account-wide like every intermediate.
-- job_type_id (recurr.jobType) lets the jobtype mart split per job type; the
-- client-level mart re-aggregates over it (group by client + date), unchanged.
--
-- Raw components; the mart derives the report figures:
--   total_scheduled      = scheduled_event_hrs_all - scheduled_unpaid_break_hrs_all
--   scheduled_unassigned = event_hrs_unassigned - unpaid_break_hrs_unassigned
--   breaks_paid_sched (assigned)   = paid_break_hrs_all - paid_break_hrs_unassigned
--   breaks_unpaid_sched (assigned) = unpaid_break_hrs_all - unpaid_break_hrs_unassigned
--   breaks_paid_sched_unassigned   = paid_break_hrs_unassigned

with occurrences as (
    -- no-show occurrences are non-delivered, not scheduled -> exclude them.
    -- The occurrences run on to the capacity outlook's projection horizon; this
    -- report stops at its own, today + 60 (macros/report_horizon.sql).
    select
        source,
        client_id,
        location_id,
        job_type_id,
        occurrence_date,
        event_minutes,
        unpaid_break_minutes,
        paid_break_minutes,
        is_unassigned
    from {{ ref('int__recurr_occurrences') }}
    where
        not is_no_show
        and occurrence_date <= {{ report_horizon() }}
),

final as (
    select
        source,
        client_id,
        location_id,
        job_type_id,
        occurrence_date as service_date,
        sum(event_minutes) / 60.0 as scheduled_event_hrs_all,
        sum(unpaid_break_minutes) / 60.0 as scheduled_unpaid_break_hrs_all,
        sum(paid_break_minutes) / 60.0 as scheduled_paid_break_hrs_all,
        sum(iff(is_unassigned, event_minutes, 0)) / 60.0 as scheduled_event_hrs_unassigned,
        sum(iff(is_unassigned, unpaid_break_minutes, 0)) / 60.0 as scheduled_unpaid_break_hrs_unassigned,
        sum(iff(is_unassigned, paid_break_minutes, 0)) / 60.0 as scheduled_paid_break_hrs_unassigned

    from occurrences
    group by 1, 2, 3, 4, 5
)

select * from final
