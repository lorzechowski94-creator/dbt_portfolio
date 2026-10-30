-- Intermediate: Anniversary Report — one row per carer with a usable employment
-- start date, plus the work-anniversary maths the report is built on. Ports
-- anniversary.php (getAllCarers() + the per-row area lookup).
--
-- Grain: source + carer_id. carer.id is allocated per care, so the same id is a
-- different person in another care — carer_key carries both.
--
-- ACCOUNT-WIDE: reads every care's staging at once (macros/union_cares.sql), so
-- both area joins carry the care.
--
-- All the date arithmetic is evaluated at BUILD time against current_date(), the
-- same way int__birthday_people does it; the mart is a table rebuilt by the daily
-- refresh, so days_to_go/years_active are "as at the last run".

with carer_src as (
    {{ union_cares('carer', 'staging') }}
),

area_src as (
    {{ union_cares('area', 'staging') }}
),

carer as (
    select
        source,
        id,
        title,
        fname,
        sname,
        startdate,
        sex,
        email,
        area,
        state,
        companyid,
        location
    from carer_src
    where
        state in (1, 2, 3)
        -- care workers only; 2 = top-level admin, 3 = local admin, and neither
        -- belongs in the report even though they live in the same table
        and permissionid = 4
        -- a start date still to come has no anniversary yet, and implausible
        -- years are unusable; both are dropped rather than rendered as the PHP does
        and startdate between date '1900-01-01' and current_date()
),

anniversary as (
    select
        c.*,
        -- completed years of service today — matches MySQL
        -- TIMESTAMPDIFF(YEAR, startDate, CURDATE()), which subtracts the year when
        -- this year's anniversary has not come round yet; datediff alone counts
        -- calendar-year boundaries and would be a year ahead until then
        datediff(year, c.startdate, current_date())
        - iff(to_char(c.startdate, 'MMDD') > to_char(current_date(), 'MMDD'), 1, 0)
            as years_active,
        -- which anniversary comes next: this year's until it has passed, then next
        -- year's, so a December window carries into January. Floored at 1 — the
        -- start date itself is not an anniversary, so a carer who starts today
        -- gets their first one a year from now
        greatest(
            year(current_date()) - year(c.startdate)
            + iff(to_char(c.startdate, 'MMDD') >= to_char(current_date(), 'MMDD'), 0, 1),
            1
        ) as years_at_next_anniversary,
        -- anniversary inside the current calendar year; may already be in the
        -- past, and null for a carer who started this year (no anniversary yet)
        iff(
            year(c.startdate) < year(current_date()),
            dateadd(year, year(current_date()) - year(c.startdate), c.startdate),
            null
        ) as anniversary_this_year
    from carer as c
),

timing as (
    select
        a.*,
        dateadd(year, a.years_at_next_anniversary, a.startdate)
            as next_anniversary_date
    from anniversary as a
),

countdown as (
    select
        t.*,
        datediff(day, current_date(), t.next_anniversary_date) as days_to_go
    from timing as t
),

area as (
    select
        source,
        id,
        name
    from area_src
),

area_hierarchy as (
    select
        source,
        area_id,
        workgroup_names,
        branch_names
    from {{ ref('int__area_hierarchy') }}
),

final as (
    select
        cd.source,
        cd.id as carer_id,
        {{ source_key('cd.source', 'cd.id') }} as carer_key,
        cd.title,
        cd.fname as first_name,
        cd.sname as surname,
        trim(
            coalesce(cd.title, '') || ' '
            || coalesce(cd.fname, '') || ' '
            || coalesce(cd.sname, '')
        ) as full_name,
        cd.startdate as start_date,
        month(cd.startdate) as start_month,
        day(cd.startdate) as start_day,
        cd.anniversary_this_year,
        cd.next_anniversary_date,
        cd.days_to_go,
        cd.years_active,
        cd.years_at_next_anniversary,
        cd.sex as gender,
        nullif(trim(cd.email), '') as email,
        try_to_number(cd.area::varchar) as area_id,             -- branch RLS key
        ar.name as area_name,                                   -- null when unmapped
        h.workgroup_names as workgroup,
        h.branch_names as branch,
        cd.state as state_id,
        case cd.state
            when 1 then 'Active'
            when 2 then 'Pending'
            when 3 then 'Archived'
        end as state,
        'Carer' as person_type_label,                           -- the PHP hardcodes it
        cd.companyid as company_id,                             -- RLS key (with location_id)
        cd.location as location_id
    from countdown as cd
    -- numeric-FK joins wrapped in try_to_number: area is NUMBER in care1 but the
    -- other cares share the model, so a non-numeric value yields null, not a
    -- cast error (same pattern as int__birthday_people).
    left join area as ar
        on
            cd.source = ar.source
            and try_to_number(cd.area::varchar) = ar.id
    left join area_hierarchy as h
        on
            cd.source = h.source
            and try_to_number(cd.area::varchar) = h.area_id
)

select * from final
