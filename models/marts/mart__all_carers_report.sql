-- Mart (FACT/DETAIL): All Carers — one row per carer of the legacy All Carers
-- list. Flat list report (no aggregation, no dates); all display columns
-- denormalised. RLS keys (source/company_id/location_id/area_id) travel on the
-- row for the report secure view and the TenantArea role. Full table rebuild
-- each run.
--
-- Grain: source + carer_id (carer_key).

select
    source,
    carer_key,
    carer_id,
    carer_no,
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
    area_id,
    area_name,
    phone,
    phone2,
    email,
    tags,
    status_id,
    status,
    status_colour,
    status_change_date,
    status_comment,
    transport_type_id,
    transport_type,
    known_as,
    pay_cycle,
    is_pay_cycle_loaded,
    nationality,
    state_id,
    state,
    location_key,
    company_id,
    location_id
from {{ ref('int__all_carers') }}
