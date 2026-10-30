-- Mart (DIMENSION): one row per location — the branch a carer, client or visit
-- belongs to. The Branch slicer of the Workforce Capacity report and the tenant
-- boundary of its facts: relate on location_key.
--
-- Grain: source + location_id. location.id is allocated per care and collides
-- across them (id 24 is a different branch in care2 and care3), so location_key
-- carries both.
--
-- Read straight from staging, across every care in the account: no intermediate
-- sits between this mart and the location table, so the union happens here
-- (macros/union_cares.sql).

with location_src as (
    {{ union_cares('location', 'staging') }}
),

final as (
    select
        source,
        id as location_id,
        {{ source_key('source', 'id') }} as location_key,
        name as location_name,
        companyid as company_id,                        -- RLS key (with location_id)
        address1 as address,
        town,
        county,
        postcode as post_code,
        country,
        created::date as created_date,
        deleted::date as deleted_date,
        deleted is not null as is_deleted
    from location_src
)

select * from final
