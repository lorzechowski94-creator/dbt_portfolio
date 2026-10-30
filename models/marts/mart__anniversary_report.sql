-- Mart (FACT/DETAIL): Anniversary Report — one row per carer with a usable
-- employment start date. Flat detail report (no aggregation, no totals row); all
-- display columns denormalised. RLS keys (source/company_id/location_id) travel on
-- the row for the report secure view. Direct-join report, so it is a full table
-- rebuild each run — no incremental config.
--
-- Grain: source + carer_id (carer_key).

select
    source,
    carer_key,
    carer_id,
    title,
    first_name,
    surname,
    full_name,
    start_date,
    start_month,
    start_day,
    anniversary_this_year,
    next_anniversary_date,
    days_to_go,
    years_active,
    years_at_next_anniversary,
    gender,
    email,
    area_id,
    area_name,
    workgroup,
    branch,
    state_id,
    state,
    person_type_label,
    company_id,
    location_id
from {{ ref('int__carer_anniversaries') }}
