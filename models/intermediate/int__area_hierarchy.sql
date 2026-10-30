-- Intermediate: area -> workgroup(s) -> branch(es) hierarchy, one row per area.
-- Ports query #7 of the client hours report. One area can map to several
-- workgroups/branches, so names are de-duplicated and comma-joined (the PHP does
-- the same in memory).
--
-- Grain: source + area_id. ACCOUNT-WIDE: reads every care's staging at once
-- (macros/union_cares.sql). Area, workgroup and branch ids are all allocated per
-- care and collide across them, so every join below carries the care — without it
-- an area would pick up another care's workgroups and the listagg would silently
-- merge two tenants' names into one string.

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
),

branch as (
    select
        source,
        id,
        name
    from branch_src
),

final as (
    select
        aw.source,
        aw.areaid as area_id,
        listagg(distinct wg.name, ', ') within group (
            order by wg.name
        ) as workgroup_names,
        listagg(distinct br.name, ', ') within group (
            order by br.name
        ) as branch_names
    from area_workgroup as aw
    left join workgroup_branch as wb
        on
            aw.source = wb.source
            and aw.workgroupid = wb.workgroupid
    left join workgroup as wg
        on
            aw.source = wg.source
            and aw.workgroupid = wg.id
    left join branch as br
        on
            wb.source = br.source
            and wb.branchid = br.id
    group by aw.source, aw.areaid
)

select * from final
