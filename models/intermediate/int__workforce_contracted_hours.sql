-- Intermediate: "staff contracted" pillar of the workforce capacity report —
-- cmContractsHours expanded to one contracted-hours figure per carer per day, from
-- the contract history up to the projection horizon (macros/projection_horizon.sql).
--
-- Grain: source + carer_id + calendar_date. ACCOUNT-WIDE (macros/union_cares.sql);
-- the calendar join needs no source condition, int__report_calendar has no tenant.
--
-- Differs from int__carer_contracted_hours (the Carer Hours port) in two ways:
--   * the WHOLE history, archived contracts included (archiveId 2 = superseded),
--     one contract per carer per day. An edit closes the old row on the day the
--     new one starts, so on that day the latest start wins.
--   * clipped to the carer's employment spell: a contract is still open-ended on
--     many carers who have left, and would otherwise project them forward.
-- mon..sun hold contracted MINUTES per ISO weekday (1 = Monday).

with calendar as (
    select calendar_date from {{ ref('int__report_calendar') }}
),

contracts_src as (
    {{ union_cares('cm_contracts_hours', 'staging') }}
),

contracts as (
    select
        source,
        id,
        carerid,
        archiveid,
        startdate,
        enddate,
        mon,
        tue,
        wed,
        thu,
        fri,
        sat,
        sun
    from contracts_src
    where
        deleted is null
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

days as (
    select
        c.source,
        c.carerid as carer_id,
        s.location_id,
        s.area_id,
        cal.calendar_date,
        case dayofweekiso(cal.calendar_date)
            when 1 then c.mon
            when 2 then c.tue
            when 3 then c.wed
            when 4 then c.thu
            when 5 then c.fri
            when 6 then c.sat
            when 7 then c.sun
        end as contracted_minutes
    from contracts as c
    inner join spells as s
        on
            c.source = s.source
            and c.carerid = s.carer_id
    -- endDate NULL = open-ended; the calendar stops at the projection horizon
    inner join calendar as cal
        on
            cal.calendar_date
            between c.startdate
            and coalesce(c.enddate, {{ projection_horizon() }})
    where s.leave_date is null or cal.calendar_date < s.leave_date
    qualify row_number() over (
        partition by c.source, c.carerid, cal.calendar_date
        order by c.startdate desc, c.archiveid asc, c.id desc
    ) = 1
)

select
    source,
    carer_id,
    location_id,
    area_id,
    calendar_date,
    coalesce(contracted_minutes, 0) / 60.0 as contracted_hrs
from days
