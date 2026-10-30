-- Intermediate: All Clients — one row per client of the legacy All Clients page
-- (cm/in/clientsTotalAll.php, rows from ajax/tables/clientsTotalAllTableBc.php),
-- with every column the page can show. The current state only: nothing here is
-- dated.
--
-- Grain: source + client_id. ACCOUNT-WIDE: reads every care's staging at once
-- (macros/union_cares.sql), so every join carries the care.

with client_src as (
    {{ union_cares('client', 'staging') }}
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
    {{ union_cares('cm_future_status_change', 'staging') }}
),

client as (
    select
        source,
        id,
        residentid,
        fname,
        sname,
        sex,
        currentaddress1,
        currenttown,
        currentcounty,
        postcode,
        latitude,
        email,
        phonehome,
        phonemobile,
        dob,
        area,
        statusid,
        privatenote,
        admissiondate,
        inductiondate,
        councilid,
        state,
        companyid,
        location
    from client_src
    where
        -- 1 Active, 2 Pending, 3 Archived; 4 is deleted and never listed.
        -- client.deleted is not read: Pending and Archived clients carry the stamp.
        state < 4
        and wardflag is null
        -- the page lists one location's clients, so a client with none is on no page
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
    -- the client's latest status change by id, with no deleted or location check
    select
        source,
        clientid,
        created,
        note
    from status_pick_src
    where clientid is not null
    qualify row_number() over (
        partition by source, clientid
        order by id desc
    ) = 1
),

future_status as (
    -- a status change still waiting to run, in the client's own location
    select distinct
        source,
        clientid,
        locationid
    from future_status_src
    where
        completed is null
        and deleted is null
),

area_mappings as (
    -- the Branch / Workgroup columns, from the same links the slicer bridge uses:
    -- every live workgroup of the area, and the live branches of those workgroups.
    -- nullif: listagg returns '' when every name is null (no live branch)
    select
        source,
        area_id,
        nullif(
            listagg(distinct branch_name, ', ') within group (
                order by branch_name
            ),
            ''
        ) as branch_names,
        nullif(
            listagg(distinct workgroup_name, ', ') within group (
                order by workgroup_name
            ),
            ''
        ) as workgroup_names
    from {{ ref('int__area_workgroup_branch') }}
    group by source, area_id
),

client_tags as (
    select
        source,
        client_id,
        listagg(tag_name, ', ') within group (
            order by tag_category_id, tag_name
        ) as tags
    from {{ ref('int__client_tags') }}
    group by source, client_id
),

client_job_types as (
    select
        source,
        client_id,
        listagg(job_type_name, ', ') within group (
            order by list_position
        ) as job_types
    from {{ ref('int__client_job_types') }}
    group by source, client_id
),

final as (
    select
        c.source,
        c.id as client_id,
        {{ source_key('c.source', 'c.id') }} as client_key,
        c.residentid as client_no,
        coalesce(try_to_number(c.privatenote::varchar) = 1, false) as has_private_note,
        fs.clientid is not null as has_future_status_change,
        c.fname as first_name,
        c.sname as surname,
        trim(coalesce(c.fname, '') || ' ' || coalesce(c.sname, '')) as full_name,
        case
            when upper(trim(c.sex::varchar)) in ('F', '2', 'FEMALE') then 'Female'
            when upper(trim(c.sex::varchar)) in ('M', '1', 'MALE') then 'Male'
        end as gender,
        nullif(
            array_to_string(
                array_construct_compact(
                    nullif(trim(c.currentaddress1), ''),
                    nullif(trim(c.currenttown), ''),
                    nullif(trim(c.currentcounty), ''),
                    nullif(trim(c.postcode), '')
                ),
                ', '
            ),
            ''
        ) as address,
        c.currentaddress1 as address_line_1,
        c.currenttown as town,
        c.currentcounty as county,
        c.postcode as post_code,
        nullif(trim(c.latitude::varchar), '') is not null as is_location_confirmed,
        am.branch_names,
        am.workgroup_names,
        try_to_number(c.area::varchar) as area_id,              -- branch RLS key
        a.name as area_name,
        c.email,
        nullif(
            array_to_string(
                array_construct_compact(
                    nullif(trim(c.phonehome), ''),
                    nullif(trim(c.phonemobile), '')
                ),
                ', '
            ),
            ''
        ) as phone,
        c.phonehome as phone_home,
        c.phonemobile as phone_mobile,
        c.dob as date_of_birth,
        jt.job_types,
        t.tags,
        try_to_number(c.statusid::varchar) as status_id,
        s.type as status,
        s.colour as status_colour,
        sp.created::timestamp_ntz as status_change_at,
        sp.note as status_comment,
        c.admissiondate as first_contact_date,
        c.inductiondate as service_commenced_date,
        c.councilid as council_id,
        c.state as state_id,
        case c.state
            when 1 then 'Active'
            when 2 then 'Pending'
            when 3 then 'Archived'
        end as state,
        {{ source_key('c.source', 'c.location') }} as location_key,
        c.companyid as company_id,                              -- RLS key (with location_id)
        c.location as location_id
    from client as c
    -- numeric-FK joins wrapped in try_to_number: client.statusId is text, and
    -- client.area is text in some cares, so a non-numeric value yields no match
    -- (null) instead of a cast error.
    left join area_mappings as am
        on
            c.source = am.source
            and try_to_number(c.area::varchar) = am.area_id
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
            and c.id = sp.clientid
    left join future_status as fs
        on
            c.source = fs.source
            and c.id = fs.clientid
            and c.location = fs.locationid
    left join client_tags as t
        on
            c.source = t.source
            and c.id = t.client_id
    left join client_job_types as jt
        on
            c.source = jt.source
            and c.id = jt.client_id
)

select * from final
