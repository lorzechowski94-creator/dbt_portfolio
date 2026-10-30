-- Intermediate: Task Review — one row per scheduled task slot per day per result
-- recorded on it: the port of the legacy Digital Task Review page
-- (cm/in/task/companyTaskRpt.php, returnTasks() in taskFunctions.php). A slot with
-- nothing recorded is one blank row, a slot with several results one row each, as
-- on the page. Full history plus a 60-day forward look (macros/report_horizon.sql);
-- the page's date window is a slicer. Which schedules, dates and results make a
-- row, and where this departs from the page, is in _int__models.yml.
--
-- Grain: source + task_assign_id + task_assign_times_id (null for an "Any" slot) +
-- scheduled_date + result_number (null when nothing is recorded).
-- ACCOUNT-WIDE: reads every care's staging at once (macros/union_cares.sql), so
-- every join carries the care; int__report_calendar is the one relation without it.

with calendar as (
    select calendar_date
    from {{ ref('int__report_calendar') }}
    where calendar_date <= {{ report_horizon() }}
),

assign_src as (
    {{ union_cares('cm_daily_tasks_assign', 'staging') }}
),

assign_times_src as (
    {{ union_cares('cm_daily_tasks_assign_times', 'staging') }}
),

task_src as (
    {{ union_cares('cm_daily_tasks', 'staging') }}
),

results_src as (
    {{ union_cares('cm_daily_tasks_results', 'staging') }}
),

reason_src as (
    {{ union_cares('cm_daily_tasks_reason', 'staging') }}
),

category_src as (
    {{ union_cares('cm_daily_tasks_reason_category', 'staging') }}
),

client_src as (
    {{ union_cares('client', 'staging') }}
),

carer_src as (
    {{ union_cares('carer', 'staging') }}
),

client as (
    -- every client but a deleted record (state 4)
    select
        source,
        id,
        area
    from client_src
    where coalesce(state, 0) != 4
),

schedules as (
    select
        ta.source,
        ta.id,
        ta.clientid,
        ta.companyid,
        ta.locationid,
        ta.datestart,
        ta.datefinish,
        ta.everynumdays,
        ta.week,
        ta.mon,
        ta.tue,
        ta.wed,
        ta.thu,
        ta.fri,
        ta.sat,
        ta.sun,
        ta.effectivestoptime
    from assign_src as ta
    -- the page's join to the task: written as a RIGHT JOIN, it acts as an inner
    -- one. A deleted task still shows.
    inner join task_src as t
        on
            ta.source = t.source
            and ta.cmdailytasksid = t.id
    inner join client as c
        on
            ta.source = c.source
            and ta.clientid = c.id
    where
        ta.deleted is null
        -- the page lists one company's location, so a schedule without either is
        -- on no page
        and ta.companyid is not null
        and ta.locationid is not null
),

schedule_dates as (
    select
        s.*,
        cal.calendar_date as scheduled_date,
        -- the schedule's last day, when it ends at effectiveStopTime
        coalesce(
            cal.calendar_date = s.datefinish and s.effectivestoptime is not null,
            false
        ) as is_stop_day
    from schedules as s
    inner join calendar as cal
        on cal.calendar_date between s.datestart and coalesce(s.datefinish, cal.calendar_date)
    where
        -- dateStart = dateFinish: that one date
        s.datestart = s.datefinish
        -- week (checked before everyNumDays, unlike Medication Review): the
        -- ticked weekdays, every `week` weeks counted from the Monday of
        -- dateStart's week
        or (
            coalesce(s.week, 0) > 0
            and decode(
                dayofweekiso(cal.calendar_date),
                1, s.mon, 2, s.tue, 3, s.wed, 4, s.thu, 5, s.fri, 6, s.sat, 7, s.sun
            ) = 1
            and mod(
                floor(
                    datediff(
                        day,
                        dateadd(day, 1 - dayofweekiso(s.datestart), s.datestart),
                        cal.calendar_date
                    ) / 7
                ),
                s.week
            ) = 0
        )
        -- everyNumDays: dateStart, then every N days
        or (
            coalesce(s.week, 0) <= 0
            and coalesce(s.everynumdays, 0) > 0
            and mod(datediff(day, s.datestart, cal.calendar_date), s.everynumdays) = 0
        )
        -- neither: every day
        or (coalesce(s.week, 0) <= 0 and coalesce(s.everynumdays, 0) <= 0)
),

slot_times as (
    -- the time row's own day, week and date fields are not read, as on the page
    select
        source,
        id,
        cmdailytasksassign,
        times,
        timeperiodid
    from assign_times_src
    where deleted is null
),

slots as (
    -- one slot per live time of the schedule; a schedule with no live time is a
    -- single "Any" slot
    select
        d.source,
        d.id as task_assign_id,
        d.clientid,
        d.companyid,
        d.locationid,
        d.scheduled_date,
        t.id as task_assign_times_id,
        t.times as slot_time,
        t.timeperiodid as time_period_id
    from schedule_dates as d
    left join slot_times as t
        on
            d.source = t.source
            and d.id = t.cmdailytasksassign
    -- on its last day a schedule ends at effectiveStopTime: a timed slot after it
    -- is not due
    where not (d.is_stop_day and coalesce(t.times::time > d.effectivestoptime::time, false))
),

results as (
    -- every live result, whatever its status: the page joins the status with a
    -- LEFT JOIN, so a result with an unknown taskDone still shows, its status blank
    select
        source,
        id,
        clientid,
        locationid,
        taskassignid,
        tasksassigntimesid,
        dateentered,
        taskdone,
        subtaskdone,
        createdby,
        timesaid,
        comment,
        created
    from results_src
    where deleted is null
),

spell as (
    select
        source,
        client_id,
        start_date,
        leave_date
    from {{ ref('int__client_service_spell') }}
),

slot_results as (
    select
        s.*,
        r.id as result_id,
        r.taskdone,
        r.subtaskdone,
        r.createdby,
        r.timesaid,
        r.comment,
        r.created as result_created_at
    from slots as s
    left join results as r
        on
            s.source = r.source
            and s.task_assign_id = r.taskassignid
            and s.clientid = r.clientid
            and s.locationid = r.locationid
            and s.scheduled_date = r.dateentered
            -- a timed slot takes the results of its own time, an "Any" slot only
            -- the results with no time (unlike Medication Review, where it takes
            -- every result of the day); -1 is no id
            and coalesce(s.task_assign_times_id, -1) = coalesce(r.tasksassigntimesid, -1)
    left join spell as sp
        on
            s.source = sp.source
            and s.clientid = sp.client_id
    -- an empty slot counts only while the client was a customer; a slot with a
    -- result always does
    where
        r.id is not null
        or (
            s.scheduled_date >= sp.start_date
            and (sp.leave_date is null or s.scheduled_date < sp.leave_date)
        )
),

category_names as (
    select
        source,
        id,
        name
    from category_src
),

category_renames as (
    -- a company's own name for a status in one of its locations; the latest live
    -- one when there are several
    select
        source,
        companyid,
        locationid,
        replacecategoryid,
        name
    from category_src
    where
        replacecategoryid is not null
        and deleted is null
    qualify row_number() over (
        partition by source, companyid, locationid, replacecategoryid
        order by id desc
    ) = 1
),

reasons as (
    select
        source,
        id,
        name
    from reason_src
),

users as (
    -- whoever recorded a result: any carer row, office users and deleted carers
    -- included
    select
        source,
        id,
        nullif(trim(coalesce(fname, '') || ' ' || coalesce(sname, '')), '') as full_name
    from carer_src
),

final as (
    select
        sr.source,
        sr.scheduled_date,
        sr.task_assign_id,
        {{ source_key('sr.source', 'sr.task_assign_id') }} as task_schedule_key,
        sr.task_assign_times_id,
        iff(
            sr.task_assign_times_id is null,
            'Any',
            to_char(sr.slot_time::time, 'HH24:MI')
        ) as assigned_time,
        iff(
            sr.task_assign_times_id is null,
            -1,
            hour(sr.slot_time::time) * 60 + minute(sr.slot_time::time)
        ) as assigned_time_minutes,
        sr.time_period_id,
        sr.result_id,
        iff(
            sr.result_id is null,
            null,
            row_number() over (
                partition by sr.source, sr.task_assign_id, sr.task_assign_times_id, sr.scheduled_date
                order by sr.result_created_at, sr.result_id
            )
        ) as result_number,
        row_number() over (
            partition by sr.source, sr.task_assign_id, sr.task_assign_times_id, sr.scheduled_date
            order by sr.result_created_at desc nulls last, sr.result_id desc
        ) = 1 as is_latest_for_slot,
        sr.result_id is not null as is_recorded,
        sr.taskdone as status_id,
        coalesce(rn.name, cn.name) as status_name,
        sr.subtaskdone as sub_status_id,
        rs.name as sub_status_name,
        sr.createdby as recorded_by_id,
        u.full_name as recorded_by,
        to_char(sr.timesaid::time, 'HH24:MI:SS') as time_recorded,
        sr.comment,
        sr.result_created_at,
        sr.clientid as client_id,
        {{ source_key('sr.source', 'sr.clientid') }} as client_key,
        try_to_number(c.area::varchar) as area_id,                -- branch RLS key
        {{ source_key('sr.source', 'sr.locationid') }} as location_key,
        sr.companyid as company_id,                              -- RLS key (with location_id)
        sr.locationid as location_id
    from slot_results as sr
    inner join client as c
        on
            sr.source = c.source
            and sr.clientid = c.id
    left join category_names as cn
        on
            sr.source = cn.source
            and sr.taskdone = cn.id
    left join category_renames as rn
        on
            sr.source = rn.source
            and sr.companyid = rn.companyid
            and sr.locationid = rn.locationid
            and sr.taskdone = rn.replacecategoryid
    left join reasons as rs
        on
            sr.source = rs.source
            and sr.subtaskdone = rs.id
    left join users as u
        on
            sr.source = u.source
            and sr.createdby = u.id
)

select * from final
