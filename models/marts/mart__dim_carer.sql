-- Mart (DIMENSION): one row per carer — the demographic / display columns of the
-- carer hours report (carersHoursRpt.php §5). Relate to
-- mart__carer_hours_report on carer_key in Power BI; it also supplies the
-- RLS keys (source / company_id / location_id) for the report secure view over the
-- fact.
--
-- Grain: source + carer_id. carer.id is allocated per care, so the same id is a
-- different person in another care — carer_key carries both, and is the column
-- every relationship uses.
--
-- Carer scope matches the report list query (§3.1): permissionId = 4 (carer role)
-- and deleted IS NULL. Position and area names are looked up (§3.7 / area join);
-- numeric-FK joins are wrapped in try_to_number so free-text ids yield null, not
-- a cast error (same pattern as int__carer_qualifications).

-- Read straight from staging, across every care in the account: no intermediate
-- sits between this mart and these three tables, so the union happens here
-- (macros/union_cares.sql).
with carer_src as (
    {{ union_cares('carer', 'staging') }}
),

positions_src as (
    {{ union_cares('cm_employee_positions', 'staging') }}
),

area_src as (
    {{ union_cares('area', 'staging') }}
),

carer as (
    select
        source,
        id,
        carerid,
        fname,
        sname,
        dob,
        startdate,
        address1,
        town,
        county,
        area,
        position,
        companyid,
        location
    from carer_src
    where
        permissionid = 4
        and deleted is null
),

positions as (
    select
        source,
        id,
        name
    from positions_src
),

area as (
    select
        source,
        id,
        name
    from area_src
),

final as (
    select
        c.source,
        c.id as carer_id,
        {{ source_key('c.source', 'c.id') }} as carer_key,
        c.carerid as carer_no,                          -- No. (front-end id)
        c.sname as surname,
        c.fname as first_name,
        c.fname || ' ' || c.sname as full_name,
        c.dob as date_of_birth,
        c.startdate as start_date,
        try_to_number(c.area::varchar) as area_id,      -- branch RLS key
        a.name as area,
        c.address1 as address,
        c.town,
        c.county,
        p.name as position,                             -- cmEmployeePositions.name
        c.companyid as company_id,                      -- RLS key (with location_id)
        c.location as location_id
    from carer as c
    left join positions as p
        on
            c.source = p.source
            and try_to_number(c.position::varchar) = p.id
    left join area as a
        on
            c.source = a.source
            and try_to_number(c.area::varchar) = a.id
)

select * from final
