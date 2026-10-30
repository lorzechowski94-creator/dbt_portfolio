-- Mart (DIMENSION): one row per job type — id -> name lookup for the JobType
-- column / slicer of the jobtype-grained facts. Relate on job_type_key in
-- Power BI, against mart__client_hours_report and mart__carer_hours_report (both
-- carry the care and the job type on their grain).
--
-- Grain: source + job_type_id. jobType.id is allocated per care and collides across
-- them, so the care is part of the key — job_type_key carries both.

-- Read straight from staging, across every care in the account: no intermediate
-- sits between this mart and jobtype (macros/union_cares.sql).
with jobtype_src as (
    {{ union_cares('jobtype', 'staging') }}
),

jobtype as (
    select
        source,
        id,
        name,
        companyid,
        locationid
    from jobtype_src
    where
        deleted is null
        -- RLS keys: a null companyid hides the dimension row from every reader,
        -- and a null locationid from every location reader, while facts still
        -- point at it — a blank member in Power BI. Dropped here; no intermediate
        -- model sits between this and staging. care2 has one such row, care1 none.
        and companyid is not null
        and locationid is not null
),

final as (
    select
        source,
        id as job_type_id,
        {{ source_key('source', 'id') }} as job_type_key,
        name as job_type_name,
        companyid as company_id,  -- RLS key (with location_id)
        locationid as location_id
    from jobtype
)

select * from final
