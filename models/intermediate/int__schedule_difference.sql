-- Intermediate: Schedule Difference Report — one row per individual scheduled
-- call occurrence, comparing the scheduled template against the matched
-- timesheet. Ports scheduleReport_diff.php.
--
-- Grain: source + recurr_id + occurrence_date (carer_id is 1:1 with recurr_id).
-- ACCOUNT-WIDE: reads every care's staging at once (macros/union_cares.sql).
-- recurr, carer, client and timesheet ids are all allocated per care and collide
-- across them, so every join and every window PARTITION BY below carries the care.
--
-- Date expansion is reused from int__recurr_occurrences (the shared
-- returnDates() port). That model already drops bank-holiday occurrences when
-- offBankHolidays = 1 and flags no-shows, matching the PHP returnDates() the
-- report relies on. Here we additionally:
--   * keep only statusId IN (1, 2) — active AND cancelled schedules (the report
--     shows cancelled rows too, unlike the hours reports which are active-only);
--   * require confirmSch = 'Yes' (join back to recurr — recurr_occurrences also
--     admits confirmSch='No' unassigned rows, which this report excludes);
--   * restrict to carers in state IN (1, 2, 3) (Active / Pending / Archived —
--     the report's carer loop driver), which also drops unassigned
--     (carerId = 0) templates.
--
-- STAR, not a flat export: the row carries dimension KEYS (client_id, carer_id,
-- job_type_id, occurrence_date) and only the measures/attributes unique to the
-- occurrence. Names and hierarchies come from mart__dim_client / mart__dim_carer /
-- mart__dim_jobtype / mart__dim_date — repeating them on ~100M rows was the bulk of
-- the fact's storage. See the note on the client key in occurrence_detail.
--
-- Timesheet is matched exactly by carerId + recurrId + occurrence date (logDate),
-- LEFT joined so scheduled calls with no timesheet still produce a row
-- (timesheet columns empty, TimeSheet status "None"). See §3.4 / §8.
--
-- Time columns: recurr.timeStart/timeFinish and recurr.hours are VARCHAR "HH:MM";
-- timesheet.logIn/logOut/duration are TIME. Both are cast to ::time for the
-- minute-difference maths and formatted to "HH24:MI" for display. Midnight end of
-- day ('00:00:00') displays as '24:00' (§4.5).

with recurr_src as (
    {{ union_cares('recurr', 'staging') }}
),

carer_src as (
    {{ union_cares('carer', 'staging') }}
),

timesheet_src as (
    {{ union_cares('timesheet', 'staging') }}
),

recurr_cancel_src as (
    {{ union_cares('recurr_cancel', 'staging') }}
),

reason_cancel_src as (
    {{ union_cares('reason_cancel', 'staging') }}
),

occurrences as (
    select
        source,
        recurr_id,
        client_id,
        location_id,
        carerid as carer_id,
        statusid as status_id,
        job_type_id,
        occurrence_date
    from {{ ref('int__recurr_occurrences') }}
    where
        statusid in (1, 2)
        -- returnDates() step 5 removes dateNoShow occurrences; recurr_occurrences
        -- only flags them, so exclude them here to enumerate the same dates.
        and not is_no_show
        -- the occurrences run on to the capacity outlook's projection horizon;
        -- this report stops at its own, today + 60 (macros/report_horizon.sql)
        and occurrence_date <= {{ report_horizon() }}
),

-- Join back to recurr for the schedule times / duration and to enforce
-- confirmSch = 'Yes' (see header note).
recurr as (
    select
        source,
        id,
        timestart,
        timefinish,
        hours
    from recurr_src
    where
        deleted is null
        and confirmsch = 'Yes'
),

-- Kept as a FILTER only (inner join below), not for its columns: the carer name
-- now comes from mart__dim_carer.
carer as (
    select
        source,
        id
    from carer_src
    where state in (1, 2, 3)         -- 1 = Active, 2 = Pending, 3 = Archived
),

-- Also a filter (inner join): an occurrence whose client is absent here produces
-- no row. Client attributes come from mart__dim_client, which is built from this
-- same model, so every fact row's client_id is guaranteed to exist there.
client as (
    select
        source,
        client_id,
        company_id,
        location_id
    from {{ ref('int__client_information') }}
),

-- One timesheet row per carer x schedule template x date. Dedup defensively.
timesheet as (
    select
        source,
        carerid,
        recurrid,
        logdate,
        id as timesheet_id,
        status,
        login,
        logout,
        duration,
        timeconfirmed,
        comment
    from timesheet_src
    qualify row_number() over (
        partition by source, carerid, recurrid, logdate
        order by updated desc
    ) = 1
),

-- Cancellation info (only surfaced when status_id = 2). One row per recurr.
cancellations as (
    select
        rc.source,
        rc.recurrid,
        rc.comment as cancel_comment,
        rs.reason as cancel_reason
    from recurr_cancel_src as rc
    left join reason_cancel_src as rs
        on
            rc.source = rs.source
            and rc.reasoncancelid = rs.id
    qualify row_number() over (
        partition by rc.source, rc.recurrid
        order by rc.updated desc
    ) = 1
),

-- The joined occurrence with its measures. Split from `final` only so the display
-- string below can be derived from early_late_minutes instead of repeating the
-- datediff; everything substantive happens here.
occurrence_detail as (
    select
        o.source,
        o.recurr_id,
        o.occurrence_date,
        o.status_id,

        -- DIMENSION KEYS ONLY. Client name / area / workgroup / branch /
        -- council_id are in mart__dim_client, the carer name in mart__dim_carer,
        -- the job type name in mart__dim_jobtype, and week / day name in
        -- mart__dim_date (relate it on occurrence_date). Each of those used to be
        -- denormalised onto every one of ~100M rows.
        --
        -- The client key CHANGED MEANING: this column used to hold client_no
        -- (residentId, the front-end display id) under the name client_id, which
        -- cannot be related to dim_client and would silently match the wrong rows —
        -- both values are numeric. It is now the real client.id; the display id is
        -- dim_client.client_no.
        o.client_id,
        o.carer_id,
        -- -1 = source recorded no job type (project-wide convention, as on the
        -- hours facts); dim_jobtype holds no row for it.
        coalesce(o.job_type_id, -1) as job_type_id,

        -- schedule times (recurr) — "HH:MM"; midnight finish -> "24:00"
        to_char(r.timestart::time, 'HH24:MI') as schedule_start,
        case
            when r.timefinish::time = '00:00:00' then '24:00'
            else to_char(r.timefinish::time, 'HH24:MI')
        end as schedule_finish,

        -- actual times (timesheet). clocked_in shows even when status='In' — the
        -- carer has clocked in, only clocked_out/worked are unknown (§4.6). Empty
        -- only when there is no timesheet.
        case
            when t.timesheet_id is null then null
            else to_char(t.login::time, 'HH24:MI')
        end as clocked_in,
        case
            when t.timesheet_id is null or t.status = 'In' then null
            when t.logout::time = '00:00:00' then '24:00'
            else to_char(t.logout::time, 'HH24:MI')
        end as clocked_out,

        -- early / late: actual logIn - scheduled start, in minutes
        -- (+ = late, - = early); NULL when no timesheet (§4.2). The legacy display
        -- string is derived from this column in `final` (early_late).
        case
            when t.timesheet_id is null then null
            else datediff('minute', r.timestart::time, t.login::time)
        end as early_late_minutes,

        -- scheduled event duration "HH:MM"
        to_char(r.hours::time, 'HH24:MI') as scheduled_time,

        -- worked duration "HH:MM"; empty when no timesheet or still clocked in
        case
            when t.timesheet_id is null or t.status = 'In' then null
            else to_char(t.duration::time, 'HH24:MI')
        end as worked_time,

        -- time diff: worked - scheduled in minutes (+ = over, - = under); §4.3
        case
            when t.timesheet_id is null or t.status = 'In' then null
            else
                datediff('minute', '00:00:00'::time, t.duration::time)
                - datediff('minute', '00:00:00'::time, r.hours::time)
        end as time_diff_minutes,

        -- cancellation — only for cancelled schedules (§4 / §5)
        case when o.status_id = 2 then cn.cancel_reason end as cancellation_reason,
        case when o.status_id = 2 then cn.cancel_comment end as cancellation_comment,

        -- timesheet status (§4.4)
        case
            when t.timesheet_id is null then 'None'
            when t.timeconfirmed = 'Yes' then 'Confirmed'
            else 'Submitted'
        end as timesheet_status,

        t.comment as system_comments,

        -- RLS keys (resolved per client, consistent with dim_client)
        cl.company_id,
        cl.location_id
    from occurrences as o
    inner join recurr as r
        on
            o.source = r.source
            and o.recurr_id = r.id
    inner join carer as ca
        on
            o.source = ca.source
            and o.carer_id = ca.id
    inner join client as cl
        on
            o.source = cl.source
            and o.client_id = cl.client_id
    left join timesheet as t
        on
            o.source = t.source
            and o.carer_id = t.carerid
            and o.recurr_id = t.recurrid
            and o.occurrence_date = t.logdate
    left join cancellations as cn
        on
            o.source = cn.source
            and o.recurr_id = cn.recurrid
),

final as (
    select
        d.*,

        -- Legacy display string for early_late_minutes (§4.2): 'On time' / '+15' /
        -- '- 10' — note the space after the minus, which the source report emits.
        -- NULL when there is no timesheet, like the other timesheet columns.
        --
        -- Formatted here rather than in Power BI so the report layer needs no format
        -- string. early_late_minutes STAYS: it sorts numerically ('+9' before '+10',
        -- which the string cannot) and the On Time % / Avg Early-Late measures
        -- average it. Both columns describe one fact, so keep them in step.
        case
            when d.early_late_minutes is null then null
            when d.early_late_minutes = 0 then 'On time'
            when d.early_late_minutes > 0 then '+' || d.early_late_minutes::varchar
            else '- ' || abs(d.early_late_minutes)::varchar
        end as early_late
    from occurrence_detail as d
)

select * from final
