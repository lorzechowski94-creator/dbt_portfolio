-- Intermediate: "non-delivered incl. cancelled" pillar — scheduled calls the
-- carer did not attend, from statusChangeEventsRemoved (eventMinutes). No status
-- filter: all removed events in the window. Ports step 1 of the report.
--
-- Grain: source + client_id + location_id + job_type_id + service_date (recurrDate).
-- ACCOUNT-WIDE: reads every care's staging at once (macros/union_cares.sql) and
-- carries the care, because the ids are allocated per care and collide.
-- job_type_id (statusChangeEventsRemoved.jobType) lets the jobtype mart split
-- per job type; the client-level mart re-aggregates over it, unchanged.
--
-- DEVIATION FROM LEGACY: the PHP selects only `id, recurrId, eventMinutes,
-- clientId` and attributes non-delivered at client level, repeating the same
-- total on every job type row — even though the source column exists. We carry
-- the real jobType so a removed event lands on the job type it was scheduled
-- under. Rows with a NULL jobType still collapse into the mart's NO_JOB_TYPE
-- bucket, so nothing is lost either way.
--
-- The mart derives the excl-cancelled figure by subtracting the timesheet
-- cancellations: non_delivered = incl - cancelled_billed - cancelled_not_billed.

with removed_src as (
    {{ union_cares('status_change_events_removed', 'staging') }}
),

removed as (
    select
        source,
        clientid,
        locationid,
        jobtype,
        recurrdate,
        eventminutes
    from removed_src
    where
        deleted is null
        and recurrdate <= {{ report_horizon() }}
        -- Grain keys must be present: a null here would collapse unrelated rows
        -- into one junk aggregate that joins to nothing downstream. jobtype is
        -- deliberately NOT guarded — a null there is meaningful and folds into
        -- the mart's NO_JOB_TYPE (-1) bucket, as the header notes.
        and clientid is not null
        and locationid is not null
        and recurrdate is not null
),

final as (
    select
        source,
        clientid as client_id,
        locationid as location_id,
        jobtype as job_type_id,
        recurrdate as service_date,
        sum(eventminutes) / 60.0 as non_delivered_incl_cancelled_hrs
    from removed
    group by 1, 2, 3, 4, 5
)

select * from final
