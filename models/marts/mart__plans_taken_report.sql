-- Mart (FACT/DETAIL): Plans Taken — one row per plan started for a client or a
-- carer. Flat list report (no aggregation, no totals row); all display columns
-- denormalised. RLS keys (source/company_id/location_id/area_id) travel on the
-- row for the report secure view and the TenantArea role. Full table rebuild
-- each run.
--
-- Grain: source + plan_taken_id (plan_taken_key).

select
    source,
    plan_taken_key,
    plan_taken_id,
    person_type,
    person_type_label,
    person_id,
    person_key,
    first_name,
    surname,
    full_name,
    person_state_id,
    person_state,
    area_id,
    area_name,
    workgroup_names,
    branch_names,
    plan_id,
    plan_template_name,
    plan_name,
    started_at,
    started_date,
    started_by_id,
    started_by,
    completed_at,
    completed_date,
    is_completed,
    completion_status,
    completed_by_id,
    completed_by,
    review_date,
    next_plan_taken_id,
    is_superseded,
    is_signed_off,
    location_key,
    company_id,
    location_id
from {{ ref('int__plans_taken') }}
