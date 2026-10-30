-- Intermediate: Birthday Report — one row per person (client or carer) with a
-- usable date of birth, plus the anniversary maths the report is built on.
-- Ports birthday.php (client leg UNION ALL carer leg + the per-row area lookup).
--
-- Grain: source + person_type + person_id (client ids and carer ids overlap, so
-- neither alone is unique). person_key packs all three into one integer, so it is
-- unique on its own; the layout is in _int__models.yml.
--
-- ACCOUNT-WIDE: reads every care's staging at once (macros/union_cares.sql), so
-- both area joins carry the care.
--
-- All the date arithmetic is evaluated at BUILD time against current_date(), the
-- same way int__carer_qualifications derives expire_status; the mart is a table
-- rebuilt by the daily refresh, so days_to_go/age_years are "as at the last run".
-- date_of_birth, birth_month and birth_day are stable and let Power BI redo the
-- maths in DAX if a same-day-accurate figure is ever needed.

with client_src as (
    {{ union_cares('client', 'staging') }}
),

carer_src as (
    {{ union_cares('carer', 'staging') }}
),

area_src as (
    {{ union_cares('area', 'staging') }}
),

client as (
    select
        source,
        id,
        title,
        fname,
        sname,
        dob,
        sex,
        email,
        area,
        state,
        companyid,
        location
    from client_src
    where state in (1, 2, 3)
),

carer as (
    select
        source,
        id,
        title,
        fname,
        sname,
        dob,
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
),

people as (
    select
        source,
        'client' as person_type,
        id as person_id,
        title,
        fname,
        sname,
        dob,
        sex,
        email,
        area,
        state,
        companyid,
        location
    from client

    union all

    select
        source,
        'carer' as person_type,
        id as person_id,
        title,
        fname,
        sname,
        dob,
        sex,
        email,
        area,
        state,
        companyid,
        location
    from carer
),

anniversary as (
    select
        p.*,
        -- anniversary inside the current calendar year; may already be in the past
        dateadd(year, year(current_date()) - year(p.dob), p.dob)
            as birthday_this_year,
        -- next anniversary on or after today: the +1 rolls into next year once
        -- this year's has passed, so a December window carries into January
        dateadd(
            year,
            year(current_date()) - year(p.dob)
            + iff(to_char(p.dob, 'MMDD') >= to_char(current_date(), 'MMDD'), 0, 1),
            p.dob
        ) as next_birthday_date,
        -- age today, not age at the upcoming birthday — matches MySQL
        -- TIMESTAMPDIFF(YEAR, dob, CURDATE()), which also subtracts the year when
        -- the birthday has not come round yet
        datediff(year, p.dob, current_date())
        - iff(to_char(p.dob, 'MMDD') > to_char(current_date(), 'MMDD'), 1, 0)
            as age_years
    from people as p
    -- the source holds birth years 0001, 0137 and 6414 as well as dates in the
    -- future; the PHP renders them, here they are dropped as unusable
    where p.dob between date '1900-01-01' and current_date()
),

timing as (
    select
        a.*,
        datediff(day, current_date(), a.next_birthday_date) as days_to_go
    from anniversary as a
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
        t.source,
        t.person_type,
        t.person_id,
        (
            {{ source_code('t.source') }} * 10000000000000
            + case t.person_type when 'client' then 1 when 'carer' then 2 end * 1000000000000
            + t.person_id::int
        )::bigint as person_key,
        initcap(t.person_type) as person_type_label,            -- Client / Carer
        t.title,
        t.fname as first_name,
        t.sname as surname,
        trim(
            coalesce(t.title, '') || ' '
            || coalesce(t.fname, '') || ' '
            || coalesce(t.sname, '')
        ) as full_name,
        t.dob as date_of_birth,
        month(t.dob) as birth_month,
        day(t.dob) as birth_day,
        t.birthday_this_year,
        t.next_birthday_date,
        t.days_to_go,
        case
            when t.days_to_go = 0 then 'Happy Birthday!'
            when t.days_to_go = 1 then '1 day until birthday'
            else t.days_to_go::varchar || ' days until birthday'
        end as days_to_go_label,
        t.age_years,
        datediff(year, t.dob, t.next_birthday_date) as age_at_next_birthday,
        t.sex as gender,
        nullif(trim(t.email), '') as email,
        try_to_number(t.area::varchar) as area_id,              -- branch RLS key
        coalesce(ar.name, t.area::varchar) as area_name,        -- raw id when unmapped
        h.workgroup_names as workgroup,
        h.branch_names as branch,
        t.state as state_id,
        case t.state
            when 1 then 'Active'
            when 2 then 'Pending'
            when 3 then 'Archived'
        end as state,
        t.companyid as company_id,                              -- RLS key (with location_id)
        t.location as location_id
    from timing as t
    -- numeric-FK joins wrapped in try_to_number: area is NUMBER in care1 but the
    -- other cares share the model, so a non-numeric value yields null, not a
    -- cast error (same pattern as int__client_information).
    left join area as ar
        on
            t.source = ar.source
            and try_to_number(t.area::varchar) = ar.id
    left join area_hierarchy as h
        on
            t.source = h.source
            and try_to_number(t.area::varchar) = h.area_id
)

select * from final
