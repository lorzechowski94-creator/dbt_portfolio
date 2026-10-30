-- Mart (DIMENSION): one row per job type GROUP — the slicer table that lets the
-- jobtype-grained reports be filtered by group instead of by individual job type.
-- Put group_name on the Power BI slicer; the expansion of a group into its raw
-- job type ids lives in mart__bridge_jobtype_group (relate on group_key).
--
-- Grain: source + group_id. jobtypeGroupName.id is allocated per care and collides
-- across them, so the care is part of the key — group_key carries both.
--
-- Source jobtypeGroupName holds the group header; the membership is the
-- comma-separated jobTypeList column, exploded by the bridge.

-- Read straight from staging, across every care in the account: no intermediate
-- sits between this mart and jobtypeGroupName (macros/union_cares.sql).
with groups_src as (
    {{ union_cares('jobtype_group_name', 'staging') }}
),

groups as (
    select
        source,
        id,
        name,
        companyid,
        locationid
    from groups_src
),

final as (
    select
        source,
        id as group_id,
        {{ source_key('source', 'id') }} as group_key,
        name as group_name,
        companyid as company_id,  -- RLS key (with location_id)
        locationid as location_id
    from groups
)

select * from final
