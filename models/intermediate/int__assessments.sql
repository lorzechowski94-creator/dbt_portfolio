-- Intermediate: Assessments — one row per live assessment of a client
-- (assessment), with every column of the Assessments tab of the legacy Plan &
-- Assessment Dates page (cm/in/plansAssesmentRpt.php). The page lists the
-- assessments whose next date falls in its window; this holds all of them, and
-- the window is a date range in Power BI.
--
-- Grain: source + assessment_id. ACCOUNT-WIDE: reads every care's staging at once
-- (macros/union_cares.sql), so every join carries the care.

with assessment_src as (
    {{ union_cares('assessment', 'staging') }}
),

assessment_type_src as (
    {{ union_cares('assessment_type', 'staging') }}
),

client_src as (
    {{ union_cares('client', 'staging') }}
),

area_src as (
    {{ union_cares('area', 'staging') }}
),

assessments as (
    select
        source,
        id,
        assessmentid,
        name,
        clientid,
        assessment::date as assessment_date,
        nextass::date as next_assessment_date,
        note,
        companyid,
        locationid
    from assessment_src
    where
        deleted is null
        -- the page lists one company's location, so a row without either is on no page
        and companyid is not null
        and locationid is not null
),

assessment_types as (
    select
        source,
        id,
        name,
        deleted
    from assessment_type_src
),

clients as (
    -- the client the assessment is for, unless deleted (state 4)
    select
        source,
        id,
        fname,
        sname,
        area,
        state
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
        a.source,
        a.id as assessment_id,
        {{ source_key('a.source', 'a.id') }} as assessment_key,
        a.assessmentid as assessment_type_id,
        t.name as assessment_type_name,
        t.deleted is not null as is_assessment_type_deleted,
        a.name as assessment_name,
        a.clientid as client_id,
        {{ source_key('a.source', 'a.clientid') }} as client_key,
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
        a.assessment_date,
        a.next_assessment_date,
        a.note,
        -- the client's newest assessment of this type: latest done date first, the
        -- higher id on a tie; one with no done date counts as the oldest
        row_number() over (
            partition by a.source, a.clientid, a.assessmentid
            order by a.assessment_date desc nulls last, a.id desc
        ) = 1 as is_latest_of_type,
        {{ source_key('a.source', 'a.locationid') }} as location_key,
        a.companyid as company_id,                              -- RLS key (with location_id)
        a.locationid as location_id
    from assessments as a
    -- the type and the client have to exist, as the page's joins require. A
    -- deleted type keeps its assessments (the page does not check it); a deleted
    -- client does not
    inner join assessment_types as t
        on
            a.source = t.source
            and a.assessmentid = t.id
    inner join clients as c
        on
            a.source = c.source
            and a.clientid = c.id
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
)

select * from final
