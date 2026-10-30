-- Mart (FACT/DETAIL): All Clients — one row per client of the legacy All Clients
-- list. Flat list report (no aggregation, no dates); all display columns
-- denormalised. RLS keys (source/company_id/location_id/area_id) travel on the
-- row for the report secure view and the TenantArea role. Full table rebuild
-- each run.
--
-- Grain: source + client_id (client_key).

select
    source,
    client_key,
    client_id,
    client_no,
    has_private_note,
    has_future_status_change,
    first_name,
    surname,
    full_name,
    gender,
    address,
    address_line_1,
    town,
    county,
    post_code,
    is_location_confirmed,
    branch_names,
    workgroup_names,
    area_id,
    area_name,
    email,
    phone,
    phone_home,
    phone_mobile,
    date_of_birth,
    job_types,
    tags,
    status_id,
    status,
    status_colour,
    status_change_at,
    status_comment,
    first_contact_date,
    service_commenced_date,
    council_id,
    state_id,
    state,
    location_key,
    company_id,
    location_id
from {{ ref('int__all_clients') }}
