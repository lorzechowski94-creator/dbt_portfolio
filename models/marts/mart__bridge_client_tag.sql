-- Mart (BRIDGE): client <-> tag, one row per client of mart__all_clients_report
-- and each of their live tags. Serves the Tags slicer ("has any of the selected
-- tags"); the comma-joined Tags column is already on the client row.
--
-- Grain: source + client_id + tag_id. Restricted to the clients of the report
-- table (inner join), so every row finds its client in Power BI; the RLS keys
-- come from that client, who owns the row.

with client_tags as (
    select
        source,
        client_id,
        tag_id,
        tag_name,
        tag_color,
        tag_category_id,
        is_client_tag
    from {{ ref('int__client_tags') }}
),

clients as (
    select
        source,
        client_id,
        client_key,
        company_id,
        location_id
    from {{ ref('mart__all_clients_report') }}
),

final as (
    select
        ct.source,
        ct.client_id,
        c.client_key,
        ct.tag_id,
        {{ source_key('ct.source', 'ct.tag_id') }} as tag_key,
        ct.tag_name,
        ct.tag_color,
        ct.tag_category_id,
        ct.is_client_tag,
        c.company_id,
        c.location_id
    from client_tags as ct
    inner join clients as c
        on
            ct.source = c.source
            and ct.client_id = c.client_id
)

select * from final
