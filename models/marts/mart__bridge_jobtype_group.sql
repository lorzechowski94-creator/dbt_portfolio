-- Mart (BRIDGE): one row per (job type group, job type) pair — resolves the
-- comma-separated jobtypeGroupName.jobTypeList into a real many-to-many table,
-- the SQL equivalent of the PHP group -> raw-ids explode.
--
-- Grain: source + group_id + job_type_id. Both ids are allocated per care and
-- collide across them, so the care is part of the key and of every relationship.
--
-- Power BI: relate mart__dim_jobtype_group[group_key] 1:* to bridge[group_key],
-- and bridge[job_type_key] *:1 to mart__dim_jobtype[job_type_key] with
-- cross-filter BOTH. A group_name selection then propagates
-- group -> bridge -> dim_jobtype -> fact. HIDE every bridge column: job_type_id
-- here is the identical raw id already on the fact (1932, 1933, ...), so it is a
-- join key, not a user-facing slicer value.
--
-- SPLIT_TO_TABLE does the explode natively — no string parsing. Tokens are
-- try_cast so a stray non-numeric entry is dropped instead of failing the build,
-- and the join to dim_jobtype drops ids pointing at deleted / non-existent job
-- types (in Power BI those would otherwise land on a blank dimension row).
-- distinct because a list may repeat the same id.
--
-- NOTE: the fact's NO_JOB_TYPE (-1) bucket belongs to no group, so ANY group
-- selection hides the client-level non-delivered hours parked there — same
-- caveat as the job type slicer. To keep them visible, use a DAX measure that
-- drops the group filter:
--   CALCULATE([Non-Delivered], ALL(dim_jobtype_group), ALL(bridge_jobtype_group))

-- Read straight from staging, across every care in the account: no intermediate
-- sits between this mart and jobtypeGroupName (macros/union_cares.sql).
with groups_src as (
    {{ union_cares('jobtype_group_name', 'staging') }}
),

groups as (
    select
        source,
        id,
        jobtypelist,
        companyid,
        locationid
    from groups_src
    where
        jobtypelist is not null
        and trim(jobtypelist) != ''
),

exploded as (
    select distinct
        g.source,
        g.id as group_id,
        try_cast(trim(t.value) as number) as job_type_id,
        g.companyid as company_id,  -- RLS key (with location_id), from the group
        g.locationid as location_id
    from groups as g,
        lateral split_to_table(g.jobtypelist, ',') as t
),

final as (
    select
        e.source,
        e.group_id,
        e.job_type_id,
        {{ source_key('e.source', 'e.group_id') }} as group_key,
        {{ source_key('e.source', 'e.job_type_id') }} as job_type_key,
        e.company_id,
        e.location_id
    from exploded as e
    inner join {{ ref('mart__dim_jobtype') }} as j
        on
            e.source = j.source
            and e.job_type_id = j.job_type_id
)

select * from final
