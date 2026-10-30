-- Intermediate: "contracted/allocated" pillar — expand cmAssignedHours over the
-- report window and sum per occurrence date. Set-based port of getAllocatedHrs().
--
-- Grain: source + client_id + location_id + job_type_id + service_date
-- (occurrence_date). ACCOUNT-WIDE: reads every care's staging at once
-- (macros/union_cares.sql). The calendar join needs NO source condition —
-- int__report_calendar is a generated date spine with no tenant in it.
-- job_type_id (cmAssignedHours.jobType) lets the jobtype mart split per job type;
-- the client-level mart re-aggregates over it (group by client + date), unchanged.
--
-- Each occurrence contributes `length` minutes; allocated hours = total / 60.
-- `day` is comma-separated ISO day numbers (1=Mon..7=Sun). Occurrences repeat
-- every 7*week days, anchored to the Monday of the week containing startDate.
-- endDate NULL = open-ended (clamped to the projection horizon,
-- macros/projection_horizon.sql). This pillar feeds the Workforce Capacity outlook
-- as well as Client Hours, so it runs three whole months ahead;
-- mart__client_hours_report caps it back to its own today + 60.

with calendar as (
    select calendar_date from {{ ref('int__report_calendar') }}
),

assigned_src as (
    {{ union_cares('cm_assigned_hours', 'staging') }}
),

assigned as (
    select
        source,
        clientid,
        locationid,
        jobtype,
        length,
        startdate,
        enddate,
        day,
        week
    from assigned_src
    where
        deleted is null
        and startdate <= {{ projection_horizon() }}
),

occurrences as (
    select
        a.source,
        a.clientid as client_id,
        a.locationid as location_id,
        a.jobtype as job_type_id,
        a.length as length_minutes,
        cal.calendar_date as occurrence_date
    from assigned as a
    inner join calendar as cal
        on
            cal.calendar_date
            between a.startdate
            and least(coalesce(a.enddate, {{ projection_horizon() }}), {{ projection_horizon() }})
    where
        -- once-off (single-day) assignment
        (a.startdate = a.enddate and cal.calendar_date = a.startdate)
        -- recurring: matching ISO weekday, every 7*week days from Monday anchor
        or (
            (a.startdate <> a.enddate or a.enddate is null)
            and array_contains(
                dayofweekiso(cal.calendar_date)::varchar::variant,
                split(replace(a.day, ' ', ''), ',')
            )
            and mod(
                floor(
                    datediff(
                        day,
                        dateadd(day, -(dayofweekiso(a.startdate) - 1), a.startdate),
                        cal.calendar_date
                    ) / 7
                ),
                a.week
            ) = 0
        )
),

final as (
    select
        source,
        client_id,
        location_id,
        job_type_id,
        occurrence_date as service_date,
        sum(length_minutes) / 60.0 as allocated_hrs
    from occurrences
    group by 1, 2, 3, 4, 5
)

select * from final
