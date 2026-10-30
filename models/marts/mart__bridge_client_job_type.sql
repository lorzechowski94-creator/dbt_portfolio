-- Mart (BRIDGE): client <-> job type, one row per client of
-- mart__all_clients_report and each live job type in their client.jobTypes list.
-- Serves the Job Type slicer ("has any of the selected job types"); the
-- comma-joined Job Type column is already on the client row, and also names the
-- deleted job types this slicer does not offer.
--
-- Grain: source + client_id + job_type_id. Restricted to the clients of the
-- report table (inner join), so every row finds its client in Power BI; the RLS
-- keys come from that client, who owns the row.

with client_job_types as (
    select
        source,
        client_id,
        job_type_id,
        job_type_name
    from {{ ref('int__client_job_types') }}
    -- the page's Job Type search offers live job types only
    where is_live_job_type
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
        cj.source,
        cj.client_id,
        c.client_key,
        cj.job_type_id,
        {{ source_key('cj.source', 'cj.job_type_id') }} as job_type_key,
        cj.job_type_name,
        c.company_id,
        c.location_id
    from client_job_types as cj
    inner join clients as c
        on
            cj.source = c.source
            and cj.client_id = c.client_id
)

select * from final
