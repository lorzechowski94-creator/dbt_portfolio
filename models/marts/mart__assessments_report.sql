-- Mart (FACT/DETAIL): Assessments — one row per live assessment of a client, the
-- Assessments tab of Plan & Assessment Dates. Flat list report (no aggregation, no
-- totals row); all display columns denormalised. RLS keys
-- (source/company_id/location_id/area_id) travel on the row for the report secure
-- view and the TenantArea role. Full table rebuild each run.
--
-- Grain: source + assessment_id (assessment_key).

select
    source,
    assessment_key,
    assessment_id,
    assessment_type_id,
    assessment_type_name,
    is_assessment_type_deleted,
    assessment_name,
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
    assessment_date,
    next_assessment_date,
    note,
    is_latest_of_type,
    location_key,
    company_id,
    location_id
from {{ ref('int__assessments') }}
