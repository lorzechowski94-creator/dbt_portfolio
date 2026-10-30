-- Intermediate: "staff available" pillar of the workforce capacity report —
-- cmCarerAvailability windows expanded per carer per day, overlaps merged, up to
-- the projection horizon (macros/projection_horizon.sql).
--
-- Grain: source + carer_id + calendar_date. ACCOUNT-WIDE (macros/union_cares.sql).
--
-- Expansion, the cm_assigned_hours rule: `day` is comma-separated ISO weekdays,
-- repeating every `week` weeks from the Monday of the week containing startDate.
-- week = 0 (and startDate = endDate) is a single date. endDate NULL = open-ended;
-- endDate before startDate expands to nothing.
--
-- A window covers [startTime, startTime + length) minutes on its date, and the
-- day's figure is the UNION of its windows: a carer's windows overlap often enough
-- (an updated pattern added beside the old one) that summing them would count the
-- same hours twice. A window running past midnight counts in full on its start
-- date. A day counts 24 hours at most. Clipped to the carer's employment spell.

with calendar as (
    select calendar_date from {{ ref('int__report_calendar') }}
),

availability_src as (
    {{ union_cares('cm_carer_availability', 'staging') }}
),

availability as (
    select
        source,
        carerid,
        day,
        week,
        length,
        startdate,
        enddate,
        starttime
    from availability_src
    where
        deleted is null
        and length > 0
        and startdate <= {{ projection_horizon() }}
),

spells as (
    select
        source,
        carer_id,
        leave_date,
        location_id,
        area_id
    from {{ ref('int__carer_employment_spell') }}
),

windows as (
    select
        a.source,
        a.carerid as carer_id,
        s.location_id,
        s.area_id,
        cal.calendar_date,
        coalesce(hour(a.starttime) * 60 + minute(a.starttime), 0) as start_minute,
        coalesce(hour(a.starttime) * 60 + minute(a.starttime), 0) + a.length as end_minute
    from availability as a
    inner join spells as s
        on
            a.source = s.source
            and a.carerid = s.carer_id
    inner join calendar as cal
        on
            cal.calendar_date
            between a.startdate
            and coalesce(a.enddate, {{ projection_horizon() }})
    where
        (s.leave_date is null or cal.calendar_date < s.leave_date)
        and (
            -- single date
            ((a.week = 0 or a.startdate = a.enddate) and cal.calendar_date = a.startdate)
            -- recurring: matching ISO weekday, every `week` weeks from the Monday anchor
            or (
                a.week > 0
                and (a.startdate <> a.enddate or a.enddate is null)
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
        )
),

-- Union length by sweep: in start order, each window adds only the part that ends
-- after every earlier window on the day has ended.
covered as (
    select
        source,
        carer_id,
        location_id,
        area_id,
        calendar_date,
        greatest(
            0,
            end_minute - greatest(
                start_minute,
                coalesce(
                    max(end_minute) over (
                        partition by source, carer_id, calendar_date
                        order by start_minute, end_minute
                        rows between unbounded preceding and 1 preceding
                    ),
                    start_minute
                )
            )
        ) as covered_minutes
    from windows
)

select
    source,
    carer_id,
    location_id,
    area_id,
    calendar_date,
    least(sum(covered_minutes), 24 * 60) / 60.0 as available_hrs
from covered
group by 1, 2, 3, 4, 5
