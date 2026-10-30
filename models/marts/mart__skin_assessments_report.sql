-- Mart (FACT/DETAIL): Skin Assessments — one row per live entry of a client's
-- wound record (a wound's first assessment or one of its reviews), the Wound / Skin
-- tab of Plan & Assessment Dates. Flat list report; all display columns
-- denormalised, the wound's latest-entry values (wound_*) on every entry. RLS keys
-- (source/company_id/location_id/area_id) travel on the row for the report secure
-- view and the TenantArea role. Full table rebuild each run.
--
-- Grain: source + skin_assessment_id (skin_assessment_key).

select
    source,
    skin_assessment_key,
    skin_assessment_id,
    wound_key,
    wound_id,
    is_latest_entry,
    client_id,
    client_key,
    first_name,
    surname,
    full_name,
    client_state_id,
    client_state,
    area_id,
    area_name,
    workgroup_names,
    branch_names,
    assessment_name,
    assessment_date,
    review_date,
    is_healed,
    wound_name,
    wound_assessment_date,
    wound_review_date,
    is_wound_healed,
    location_key,
    company_id,
    location_id
from {{ ref('int__skin_assessments') }}
