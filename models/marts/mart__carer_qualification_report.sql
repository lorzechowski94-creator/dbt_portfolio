-- Mart (FACT/DETAIL): Carer Qualification Export — one row per carer ×
-- qualification record. Flat detail report (not aggregated); all display columns
-- denormalised. RLS keys (source/company_id/location_id) travel on the row for the
-- report secure view. Direct-join report (no schedule/date expansion), so it is a
-- full table rebuild each run — no incremental config.
--
-- Grain: source + carer_id + qualification record (a carer with N qualifications ->
-- N rows; a carer with none -> 1 row with null qualification columns).
--
-- HR File filter: relate mart__dim_hrfile on hr_file_key and slice on its
-- hr_file_name / hr_file_type columns (the category label lives there, not here).
-- carer_key relates to mart__dim_carer; the export denormalises the carer columns
-- it displays, so that relationship is optional — it is here so every fact in the
-- account offers the same key, not because this report needs it.

select
    source,
    {{ source_key('source', 'carer_id') }} as carer_key,
    {{ source_key('source', 'qualification_type_id') }} as hr_file_key,
    -- Row key for mart__search_index, which needs a "one" side to relate to and this
    -- fact has no single unique column. Carers holding no qualification have a NULL
    -- record id, so they take their NEGATED carer key instead — one row each.
    coalesce(
        {{ source_key('source', 'qualification_record_id') }},
        -{{ source_key('source', 'carer_id') }}
    ) as qualification_key,
    carer_no,
    first_name,
    surname,
    position,
    address,
    town,
    county,
    post_code,
    phone,
    email,
    date_of_birth,
    qualification_record_id,
    qualification_name,
    is_type_deleted,
    awarded,
    expired,
    expire_status,
    days_to_expiry,
    is_expiring,
    is_renewal,
    start_date,
    state,
    state_id,
    area_id,
    area,
    branch,
    workgroup,
    modified_by,
    file_uploaded,
    comments,
    company_id,
    location_id
from {{ ref('int__carer_qualifications') }}
