-- Intermediate: Plans Taken — one row per plan started for a client or a carer
-- (cmFormsPlansTaken), with every column of the legacy All Plans Taken page
-- (cm/in/plansTakenReport.php). Both types and the full history: the page's
-- Type, date window and Search (which date the window reads) are left to Power BI.
--
-- Grain: source + plan_taken_id. ACCOUNT-WIDE: reads every care's staging at once
-- (macros/union_cares.sql), so every join carries the care.

with plans_taken_src as (
    {{ union_cares('cm_forms_plans_taken', 'staging') }}
),

plans_src as (
    {{ union_cares('cm_plans', 'staging') }}
),

sign_off_src as (
    {{ union_cares('cm_forms_signoff', 'staging') }}
),

client_src as (
    {{ union_cares('client', 'staging') }}
),

carer_src as (
    {{ union_cares('carer', 'staging') }}
),

area_src as (
    {{ union_cares('area', 'staging') }}
),

plans_taken as (
    select
        source,
        id,
        planid,
        appendedplanname,
        -- the page's Type: a client plan has no carer, a carer plan no client.
        -- A row with both, or with neither, is nobody's plan here
        case
            when carerid is null and clientid is not null then 'client'
            when clientid is null and carerid is not null then 'carer'
        end as person_type,
        coalesce(clientid, carerid) as person_id,
        created::timestamp_ntz as started_at,
        createdby,
        completed::timestamp_ntz as completed_at,
        completedby,
        reviewdate::date as review_date,
        nextplan,
        companyid,
        locationid
    from plans_taken_src
    where
        deleted is null
        -- the page lists one company's location, so a row without either is on no page
        and companyid is not null
        and locationid is not null
),

live_plan_ids as (
    -- a review starts the next version of a plan and links it from nextPlan;
    -- it counts only while that version is live
    select
        source,
        id
    from plans_taken_src
    where deleted is null
),

plans as (
    select
        source,
        id,
        name,
        deleted
    from plans_src
),

signed_off as (
    -- a live signature on the plan, in the plan's own company
    select distinct
        source,
        formtakenid,
        companyid
    from sign_off_src
    where deleted is null
),

people as (
    -- the person a plan is for, unless deleted (state 4)
    select
        source,
        'client' as person_type,
        id as person_id,
        fname,
        sname,
        area,
        state
    from client_src
    where coalesce(state, 0) != 4

    union all

    select
        source,
        'carer' as person_type,
        id as person_id,
        fname,
        sname,
        area,
        state
    from carer_src
    where
        coalesce(state, 0) != 4
        -- care workers only; admin profiles (2, 3) live in the same table
        and permissionid = 4
),

users as (
    -- Started By / Completed By: any carer row, office users included
    select
        source,
        id,
        companyid,
        trim(coalesce(fname, '') || ' ' || coalesce(sname, '')) as full_name
    from carer_src
),

area as (
    select
        source,
        id,
        name
    from area_src
),

area_mappings as (
    -- the Work Group / Branch columns, from the same links as All Carers and
    -- All Clients: every live workgroup of the area, and the live branches of
    -- those workgroups. nullif: listagg returns '' when every name is null
    -- (no live branch)
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
        pt.source,
        pt.id as plan_taken_id,
        {{ source_key('pt.source', 'pt.id') }} as plan_taken_key,
        pt.person_type,
        initcap(pt.person_type) as person_type_label,           -- Client / Carer
        pt.person_id,
        (
            {{ source_code('pt.source') }} * 10000000000000
            + case pt.person_type when 'client' then 1 when 'carer' then 2 end * 1000000000000
            + pt.person_id::int
        )::bigint as person_key,
        p.fname as first_name,
        p.sname as surname,
        trim(coalesce(p.fname, '') || ' ' || coalesce(p.sname, '')) as full_name,
        p.state as person_state_id,
        case p.state
            when 1 then 'Active'
            when 2 then 'Pending'
            when 3 then 'Archived'
        end as person_state,
        try_to_number(p.area::varchar) as area_id,              -- branch RLS key
        a.name as area_name,
        am.workgroup_names,
        am.branch_names,
        pt.planid as plan_id,
        pl.name as plan_template_name,
        coalesce(nullif(trim(pt.appendedplanname), ''), pl.name) as plan_name,
        pt.started_at,
        pt.started_at::date as started_date,
        pt.createdby as started_by_id,
        sb.full_name as started_by,
        pt.completed_at,
        pt.completed_at::date as completed_date,
        pt.completed_at is not null as is_completed,
        iff(pt.completed_at is null, 'Pending', 'Completed') as completion_status,
        pt.completedby as completed_by_id,
        cb.full_name as completed_by,
        pt.review_date,
        pt.nextplan as next_plan_taken_id,
        nx.id is not null as is_superseded,
        so.formtakenid is not null as is_signed_off,
        {{ source_key('pt.source', 'pt.locationid') }} as location_key,
        pt.companyid as company_id,                             -- RLS key (with location_id)
        pt.locationid as location_id
    from plans_taken as pt
    -- the person has to exist and not be deleted; a row with no person type
    -- matches nobody
    inner join people as p
        on
            pt.source = p.source
            and pt.person_type = p.person_type
            and pt.person_id = p.person_id
    left join plans as pl
        on
            pt.source = pl.source
            and pt.planid = pl.id
    -- numeric-FK joins wrapped in try_to_number: client.area and carer.area are
    -- text in some cares, so a non-numeric value yields no match (null) instead
    -- of a cast error.
    left join area as a
        on
            p.source = a.source
            and try_to_number(p.area::varchar) = a.id
    left join area_mappings as am
        on
            p.source = am.source
            and try_to_number(p.area::varchar) = am.area_id
    left join users as sb
        on
            pt.source = sb.source
            and pt.createdby = sb.id
            and pt.companyid = sb.companyid
    left join users as cb
        on
            pt.source = cb.source
            and pt.completedby = cb.id
            and pt.companyid = cb.companyid
    left join live_plan_ids as nx
        on
            pt.source = nx.source
            and pt.nextplan = nx.id
    left join signed_off as so
        on
            pt.source = so.source
            and pt.id = so.formtakenid
            and pt.companyid = so.companyid
    -- a deleted template drops its plans; a missing one does not (the page's
    -- left join with `pn.deleted is null` in the WHERE)
    where pl.deleted is null
)

select * from final
