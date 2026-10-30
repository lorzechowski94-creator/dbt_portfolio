-- Intermediate: "contracted" pillar of the carer hours report (cmContractsHours).
-- Set-based port of the PHP weekday-counting logic (carersHoursRpt.php §4.2):
-- the mon/tue/.../sun columns store the contracted duration (in MINUTES) for each
-- weekday; PHP counts how many of each weekday fall in the (clamped) report range
-- and multiplies. Here we instead enumerate every day via the report calendar and
-- attribute that day's contracted minutes to its service_date, so the figure stays
-- additive and the mart can apply any Power BI date range.
--
-- Grain: source + carer_id + location_id + service_date. ACCOUNT-WIDE: reads every
-- care's staging at once (macros/union_cares.sql). The calendar join below needs
-- NO source condition — int__report_calendar is a generated date spine with no
-- tenant in it, the one relation here that is genuinely care-free.
--
-- Filters (§3.5): deleted IS NULL, archiveId = 1 (current active contract only).
-- endDate NULL = open-ended (clamped to the report horizon, macros/report_horizon.sql).
-- DAYOFWEEKISO: 1 = Monday ... 7 = Sunday (matches PHP date('N')).

with calendar as (
    select calendar_date from {{ ref('int__report_calendar') }}
),

contracts_src as (
    {{ union_cares('cm_contracts_hours', 'staging') }}
),

contracts as (
    select
        source,
        carerid,
        locationid,
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
        and archiveid = 1
        and startdate <= {{ report_horizon() }}
),

days as (
    select
        c.source,
        c.carerid as carer_id,
        c.locationid as location_id,
        cal.calendar_date as service_date,
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
    inner join calendar as cal
        on
            cal.calendar_date
            between c.startdate
            and least(coalesce(c.enddate, {{ report_horizon() }}), {{ report_horizon() }})
),

final as (
    select
        source,
        carer_id,
        location_id,
        service_date,
        sum(coalesce(contracted_minutes, 0)) / 60.0 as contracted_hrs
    from days
    group by 1, 2, 3, 4
)

select * from final
