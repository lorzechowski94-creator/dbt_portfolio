-- Intermediate: All Carers — one row per carer of the legacy All Carers page
-- (cm/in/carer/carersTotalAll.php, rows from ajax/tables/carerTblTotalAll.php),
-- with every column the page can show. The current state only: nothing here is
-- dated.
--
-- Grain: source + carer_id. ACCOUNT-WIDE: reads every care's staging at once
-- (macros/union_cares.sql), so every join carries the care.
--
-- Pay Cycle reads raw_access through union_cares_present(): cmCarerBank has not
-- reached every care yet, and a care without it gets a null pay_cycle with
-- is_pay_cycle_loaded = false (macros/union_cares_present.sql says why).

with carer_src as (
    {{ union_cares('carer', 'staging') }}
),

area_src as (
    {{ union_cares('area', 'staging') }}
),

status_src as (
    {{ union_cares('status', 'staging') }}
),

status_pick_src as (
    {{ union_cares('status_pick', 'staging') }}
),

future_status_src as (
    {{ union_cares('cm_future_status_change_carer', 'staging') }}
),

carer_bank_src as (
    {{ union_cares_present('cmcarerbank', 'raw_access', {
        'ID': 'number', 'CARERID': 'number', 'LOCATIONID': 'number', 'PAYCYCLE': 'varchar'
    }) }}
),

carer as (
    select
        source,
        id,
        carerid,
        carernum,
        fname,
        sname,
        sex,
        address1,
        town,
        county,
        postcode,
        phone,
        phone2,
        email,
        area,
        statusid,
        knownas,
        nationality,
        transporttype,
        privatenote,
        state,
        companyid,
        location
    from carer_src
    where
        -- 1 Active, 2 Pending, 3 Archived; 4 is deleted and never listed.
        -- carer.deleted is not read: Pending and Archived carers carry the stamp.
        state < 4
        -- carers only; office users (2, 3) live in the same table
        and permissionid = 4
        and wardflag is null
        -- the page lists one location's carers, so a carer with none is on no page
        and location is not null
),

area as (
    select
        source,
        id,
        name
    from area_src
),

status as (
    select
        source,
        id,
        type,
        colour
    from status_src
),

latest_status_pick as (
    -- the carer's latest status change by id, with no deleted or location check
    select
        source,
        carerid,
        datechange,
        note
    from status_pick_src
    where carerid is not null
    qualify row_number() over (
        partition by source, carerid
        order by id desc
    ) = 1
),

future_status as (
    -- a status change still waiting to run, in the carer's own location
    select distinct
        source,
        carerid,
        locationid
    from future_status_src
    where
        completed is null
        and deleted is null
),

carer_bank as (
    -- legacy takes whichever row MySQL returns; the newest row is the
    -- deterministic version of that
    select
        source,
        carerid,
        locationid,
        paycycle
    from carer_bank_src
    qualify row_number() over (
        partition by source, carerid, locationid
        order by id desc
    ) = 1
),

carer_tags as (
    select
        source,
        carer_id,
        listagg(tag_name, ', ') within group (
            order by tag_category_id, tag_name
        ) as tags
    from {{ ref('int__carer_tags') }}
    group by source, carer_id
),

final as (
    select
        c.source,
        c.id as carer_id,
        {{ source_key('c.source', 'c.id') }} as carer_key,
        -- No.: carerNum on the R3 servers, carerId everywhere else
        iff(c.source in ('alpha', 'alpha2'), c.carernum::varchar, c.carerid) as carer_no,
        coalesce(try_to_number(c.privatenote::varchar) = 1, false) as has_private_note,
        fs.carerid is not null as has_future_status_change,
        c.fname as first_name,
        c.sname as surname,
        trim(coalesce(c.fname, '') || ' ' || coalesce(c.sname, '')) as full_name,
        c.sex as gender,
        nullif(
            array_to_string(
                array_construct_compact(
                    nullif(trim(c.address1), ''),
                    nullif(trim(c.town), ''),
                    nullif(trim(c.county), ''),
                    nullif(trim(c.postcode), '')
                ),
                ', '
            ),
            ''
        ) as address,
        c.address1 as address_line_1,
        c.town,
        c.county,
        c.postcode as post_code,
        try_to_number(c.area::varchar) as area_id,              -- branch RLS key
        a.name as area_name,
        c.phone,
        c.phone2,
        c.email,
        t.tags,
        try_to_number(c.statusid::varchar) as status_id,
        s.type as status,
        s.colour as status_colour,
        sp.datechange::date as status_change_date,
        sp.note as status_comment,
        try_to_number(c.transporttype::varchar) as transport_type_id,
        case
            when try_to_number(c.transporttype::varchar) in (1, 6) then 'Driving'
            when try_to_number(c.transporttype::varchar) in (2, 39) then 'Walking'
            when try_to_number(c.transporttype::varchar) = 3 then 'Cycle'
            when try_to_number(c.transporttype::varchar) in (4, 33) then 'Bus / public'
            when try_to_number(c.transporttype::varchar) = 36 then 'Motorcycle'
        end as transport_type,
        c.knownas as known_as,
        case cb.paycycle
            when 'weekly' then 'Weekly payroll'
            when 'monthly' then 'Monthly payroll'
        end as pay_cycle,
        {{ cares_present_sql('cmcarerbank', 'raw_access', 'c.source') }} as is_pay_cycle_loaded,
        initcap(c.nationality, ' ') as nationality,
        c.state as state_id,
        case c.state
            when 1 then 'Active'
            when 2 then 'Pending'
            when 3 then 'Archived'
        end as state,
        {{ source_key('c.source', 'c.location') }} as location_key,
        c.companyid as company_id,                              -- RLS key (with location_id)
        c.location as location_id
    from carer as c
    -- numeric-FK joins wrapped in try_to_number: carer.area and carer.statusId
    -- are text in some cares, so a non-numeric value yields no match (null)
    -- instead of a cast error.
    left join area as a
        on
            c.source = a.source
            and try_to_number(c.area::varchar) = a.id
    left join status as s
        on
            c.source = s.source
            and try_to_number(c.statusid::varchar) = s.id
    left join latest_status_pick as sp
        on
            c.source = sp.source
            and c.id = sp.carerid
    left join future_status as fs
        on
            c.source = fs.source
            and c.id = fs.carerid
            and c.location = fs.locationid
    left join carer_bank as cb
        on
            c.source = cb.source
            and c.id = cb.carerid
            and c.location = cb.locationid
    left join carer_tags as t
        on
            c.source = t.source
            and c.id = t.carer_id
)

select * from final
