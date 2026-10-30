-- Mart (BRIDGE): area <-> workgroup <-> branch, one row per link, ids only. The
-- table behind the TenantArea role of the embedded Power BI models; why it exists
-- and how the role reads it is in _mart__models.yml.
--
-- Grain: source + area_id + workgroup_id + branch_id (branch_id is null when the
-- workgroup belongs to no branch). Reads every care's staging at once
-- (macros/union_cares.sql); area, workgroup and branch ids are allocated per care,
-- so the join carries the care.

with area_workgroup_src as (
    {{ union_cares('cm_level_area_workgroup', 'staging') }}
),

workgroup_branch_src as (
    {{ union_cares('cm_level_workgroup_branch', 'staging') }}
),

area_workgroup as (
    select
        source,
        companyid,
        locationid,
        areaid,
        workgroupid
    from area_workgroup_src
    where deleted is null
),

workgroup_branch as (
    select
        source,
        workgroupid,
        branchid
    from workgroup_branch_src
    where deleted is null
),

final as (
    select distinct
        aw.source,
        aw.companyid as company_id,
        aw.locationid as location_id,
        aw.areaid as area_id,
        aw.workgroupid as workgroup_id,
        wb.branchid as branch_id
    from area_workgroup as aw
    left join workgroup_branch as wb
        on
            aw.source = wb.source
            and aw.workgroupid = wb.workgroupid
)

select * from final
