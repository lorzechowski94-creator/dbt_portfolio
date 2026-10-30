-- Mart (DIMENSION): one row per task schedule (cmdailyTasksAssign) — the task it
-- is for (cmdailyTasks) and how it is scheduled. Relate to
-- mart__task_review_report on task_schedule_key: it holds the Task slicer and the
-- page's Task column.
--
-- Grain: source + task_assign_id. cmdailyTasksAssign.id is allocated per care, so
-- task_schedule_key carries both.
--
-- The same schedules int__task_review expands: live, with a company, a location
-- and a task row, of a client that is not deleted. Read straight from staging,
-- across every care in the account (macros/union_cares.sql).

with assign_src as (
    {{ union_cares('cm_daily_tasks_assign', 'staging') }}
),

task_src as (
    {{ union_cares('cm_daily_tasks', 'staging') }}
),

client_src as (
    {{ union_cares('client', 'staging') }}
),

client as (
    select
        source,
        id
    from client_src
    where coalesce(state, 0) != 4
),

final as (
    select
        ta.source,
        ta.id as task_assign_id,
        {{ source_key('ta.source', 'ta.id') }} as task_schedule_key,
        ta.clientid as client_id,
        {{ source_key('ta.source', 'ta.clientid') }} as client_key,
        ta.cmdailytasksid as task_id,
        t.name as task_name,
        t.deleted is not null as is_task_deleted,
        coalesce(ta.mandatory = 1, false) as is_mandatory,
        case
            when ta.datestart = ta.datefinish then 'Once'
            -- week is read before everyNumDays, as int__task_review expands it
            when coalesce(ta.week, 0) > 0
                then
                    iff(ta.week = 1, 'Weekly', 'Every ' || ta.week::varchar || ' weeks')
                    || ': '
                    || array_to_string(
                        array_construct_compact(
                            iff(ta.mon = 1, 'Mon', null),
                            iff(ta.tue = 1, 'Tue', null),
                            iff(ta.wed = 1, 'Wed', null),
                            iff(ta.thu = 1, 'Thu', null),
                            iff(ta.fri = 1, 'Fri', null),
                            iff(ta.sat = 1, 'Sat', null),
                            iff(ta.sun = 1, 'Sun', null)
                        ),
                        ', '
                    )
            when coalesce(ta.everynumdays, 0) = 1 then 'Daily'
            when coalesce(ta.everynumdays, 0) > 1 then 'Every ' || ta.everynumdays::varchar || ' days'
            else 'Daily'
        end as schedule_pattern,
        ta.datestart as date_start,
        ta.datefinish as date_finish,
        ta.stoppeddate as stopped_at,
        ta.reasonstop as stop_reason,
        {{ source_key('ta.source', 'ta.locationid') }} as location_key,
        ta.companyid as company_id,                     -- RLS key (with location_id)
        ta.locationid as location_id
    from assign_src as ta
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
        and ta.companyid is not null
        and ta.locationid is not null
)

select * from final
