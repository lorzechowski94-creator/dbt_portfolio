-- Intermediate: Skin Assessments — one row per live entry of a client's skin or
-- wound record (cmSkinAssessments), for the Wound / Skin tab of the legacy Plan &
-- Assessment Dates page (cm/in/plansAssesmentRpt.php). An entry is the first
-- assessment of a wound or one of its reviews. The page shows a wound by its
-- latest entry, so every entry also carries that entry's values (wound_*).
--
-- Grain: source + skin_assessment_id. ACCOUNT-WIDE: reads every care at once, so
-- every join carries the care. cmSkinAssessments is read from raw_access through
-- union_cares_present(): it has not reached every care yet, and a care without it
-- has no rows here (macros/union_cares_present.sql says why).

with skin_assessment_src as (
    {{ union_cares_present('cmskinassessments', 'raw_access', {
        'ID': 'number', 'PARENTID': 'number', 'CLIENTID': 'number', 'NAME': 'varchar',
        'DATE': 'date', 'REVIEWDATE': 'date', 'HEALED': 'number',
        'DELETED': 'timestamp_ntz', 'COMPANYID': 'number', 'LOCATIONID': 'number'
    }) }}
),

client_src as (
    {{ union_cares('client', 'staging') }}
),

area_src as (
    {{ union_cares('area', 'staging') }}
),

entries as (
    select
        source,
        id,
        -- a wound is its first entry plus the reviews whose parentId points at it
        coalesce(nullif(parentid, 0), id) as wound_id,
        clientid,
        name,
        date::date as assessment_date,
        reviewdate::date as review_date,
        coalesce(healed, 0) != 0 as is_healed,
        companyid,
        locationid
    from skin_assessment_src
    where
        deleted is null
        and companyid is not null
),

latest_entries as (
    -- the page shows a wound by its latest live entry, the one with the highest id
    select
        source,
        wound_id,
        id,
        name,
        assessment_date,
        review_date,
        is_healed
    from entries
    qualify row_number() over (
        partition by source, wound_id
        order by id desc
    ) = 1
),

clients as (
    -- the client the wound is on, unless deleted (state 4)
    select
        source,
        id,
        fname,
        sname,
        area,
        state,
        location
    from client_src
    where coalesce(state, 0) != 4
),

area as (
    select
        source,
        id,
        name
    from area_src
),

area_mappings as (
    -- the Work Group / Branch columns, from the same links as Plans Taken: every
    -- live workgroup of the area, and the live branches of those workgroups.
    -- nullif: listagg returns '' when every name is null (no live branch)
    select
        source,
        area_id,
        nullif(
            listagg(distinct workgroup_name, ', ') within group (
                order by workgroup_name
            ),
            ''
        ) as workgroup_names,
        nullif(
            listagg(distinct branch_name, ', ') within group (
                order by branch_name
            ),
            ''
        ) as branch_names
    from {{ ref('int__area_workgroup_branch') }}
    group by source, area_id
),

final as (
    select
        e.source,
        e.id as skin_assessment_id,
        {{ source_key('e.source', 'e.id') }} as skin_assessment_key,
        e.wound_id,
        {{ source_key('e.source', 'e.wound_id') }} as wound_key,
        e.id = lw.id as is_latest_entry,
        e.clientid as client_id,
        {{ source_key('e.source', 'e.clientid') }} as client_key,
        c.fname as first_name,
        c.sname as surname,
        trim(coalesce(c.fname, '') || ' ' || coalesce(c.sname, '')) as full_name,
        c.state as client_state_id,
        case c.state
            when 1 then 'Active'
            when 2 then 'Pending'
            when 3 then 'Archived'
        end as client_state,
        try_to_number(c.area::varchar) as area_id,              -- branch RLS key
        ar.name as area_name,
        am.workgroup_names,
        am.branch_names,
        e.name as assessment_name,
        e.assessment_date,
        e.review_date,
        e.is_healed,
        lw.name as wound_name,
        lw.assessment_date as wound_assessment_date,
        lw.review_date as wound_review_date,
        lw.is_healed as is_wound_healed,
        {{ source_key('e.source', 'coalesce(e.locationid, c.location)') }} as location_key,
        e.companyid as company_id,                              -- RLS key (with location_id)
        -- an entry with no location is the client's (the page shows it in every
        -- location of the company)
        coalesce(e.locationid, c.location) as location_id
    from entries as e
    inner join latest_entries as lw
        on
            e.source = lw.source
            and e.wound_id = lw.wound_id
    -- the client has to exist and not be deleted: the page keeps a wound only when
    -- the client's state is the one picked
    inner join clients as c
        on
            e.source = c.source
            and e.clientid = c.id
    -- numeric-FK joins wrapped in try_to_number: client.area is text in some
    -- cares, so a non-numeric value yields no match (null) instead of a cast error.
    left join area as ar
        on
            c.source = ar.source
            and try_to_number(c.area::varchar) = ar.id
    left join area_mappings as am
        on
            c.source = am.source
            and try_to_number(c.area::varchar) = am.area_id
    where coalesce(e.locationid, c.location) is not null
)

select * from final
