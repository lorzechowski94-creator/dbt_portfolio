-- Mart (FACT/DETAIL): Birthday Report — one row per person (client or carer)
-- with a usable date of birth. Flat detail report (no aggregation, no totals
-- row); all display columns denormalised. RLS keys (source/company_id/location_id)
-- travel on the row for the report secure view. Direct-join report, so it is a
-- full table rebuild each run — no incremental config.
--
-- Grain: source + person_type + person_id (person_key). person_key carries all
-- three in one integer, so it is unique on its own.

select
    source,
    person_key,
    person_type,
    person_type_label,
    person_id,
    title,
    first_name,
    surname,
    full_name,
    date_of_birth,
    birth_month,
    birth_day,
    birthday_this_year,
    next_birthday_date,
    days_to_go,
    days_to_go_label,
    age_years,
    age_at_next_birthday,
    gender,
    email,
    area_id,
    area_name,
    workgroup,
    branch,
    state_id,
    state,
    company_id,
    location_id
from {{ ref('int__birthday_people') }}
