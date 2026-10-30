-- Intermediate: every live area -> workgroup link, with the workgroup's live
-- branches, names included. A workgroup with no live branch keeps one row with a
-- blank branch. One definition for the All Carers, All Clients, Plans Taken and
-- Plan & Assessment Dates reports, which all take every link
-- (mart__bridge_carer_workgroup, int__all_clients, mart__bridge_client_workgroup,
-- int__plans_taken, int__assessments, int__skin_assessments).
--
-- Grain: source + area_id + workgroup_id + branch_id (branch_id may be null).
-- ACCOUNT-WIDE: reads every care's staging at once (macros/union_cares.sql); area,
-- workgroup and branch ids are allocated per care, so every join carries the care.

with area_workgroup_src as (
    {{ union_cares('cm_level_area_workgroup', 'staging') }}
),

workgroup_branch_src as (
    {{ union_cares('cm_level_workgroup_branch', 'staging') }}
),

workgroup_src as (
    {{ union_cares('cm_level_workgroup', 'staging') }}
),

branch_src as (
    {{ union_cares('cm_level_branch', 'staging') }}
),

area_workgroup as (
    select
        source,
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

workgroup as (
    select
        source,
        id,
        name
    from workgroup_src
    where deleted is null
),

branch as (
    select
        source,
        id,
        name
    from branch_src
    where deleted is null
),

live_branches as (
    -- a workgroup's branches: link and branch both undeleted
    select
        wb.source,
        wb.workgroupid,
        br.id as branch_id,
        br.name as branch_name
    from workgroup_branch as wb
    inner join branch as br
        on
            wb.source = br.source
            and wb.branchid = br.id
),

final as (
    -- the workgroup has to be live; its branch is optional
    select distinct
        aw.source,
        aw.areaid as area_id,
        aw.workgroupid as workgroup_id,
        wg.name as workgroup_name,
        lb.branch_id,
        lb.branch_name
    from area_workgroup as aw
    inner join workgroup as wg
        on
            aw.source = wg.source
            and aw.workgroupid = wg.id
    left join live_branches as lb
        on
            aw.source = lb.source
            and aw.workgroupid = lb.workgroupid
)

select * from final
