-- Mart (BRIDGE): client <-> workgroup <-> branch, one row per client of
-- mart__all_clients_report and each live workgroup of their area, with the
-- workgroup's live branch where it has one (int__area_workgroup_branch). The
-- Branch and Workgroup slicers of the All Clients report, and the table
-- all_clients_sv counts clients per branch on.
--
-- Grain: source + client_id + workgroup_id + branch_id (branch_id null for a
-- workgroup with no live branch). A client whose area has no live workgroup has
-- no row. The RLS keys come from the client, who owns the row.

with clients as (
    select
        source,
        client_id,
        client_key,
        area_id,
        company_id,
        location_id
    from {{ ref('mart__all_clients_report') }}
),

paths as (
    select
        source,
        area_id,
        workgroup_id,
        workgroup_name,
        branch_id,
        branch_name
    from {{ ref('int__area_workgroup_branch') }}
),

final as (
    select
        c.source,
        c.client_id,
        c.client_key,
        p.workgroup_id,
        p.workgroup_name,
        p.branch_id,
        p.branch_name,
        c.company_id,
        c.location_id
    from clients as c
    inner join paths as p
        on
            c.source = p.source
            and c.area_id = p.area_id
)

select * from final
