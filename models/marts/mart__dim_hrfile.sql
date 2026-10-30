-- Mart (DIMENSION): one row per HR file type (cmQualificationsType) — the "HR
-- File" filter of carerQualificationExport.php. Relate on hr_file_key to
-- mart__carer_qualification_report and slice on
-- hr_file_name; hr_file_type is the category label (report §4.3), defined here
-- only.
--
-- Grain: source + qualification_type_id. cmQualificationsType.id is allocated per
-- care and collides across them, so the care is part of the key — hr_file_key
-- carries both.
--
-- Notes:
--  * Slice on hr_file_name, NOT the id: cmQualificationsType is per tenant, so
--    one name (e.g. 'Care Cert') exists once per company/location. A slicer on
--    the name lists it once and selects every id behind it — which is what the
--    PHP checkbox list does within a single location.
--  * Retired types are KEPT (mart__dim_jobtype filters its deleted rows out; this
--    one must not) and MARKED, never hidden. Two reasons: qualification records
--    legitimately reference a type the company has since dropped, so removing the
--    row would push those facts into Power BI's blank member and out of the
--    report; and an audit can look back years, when the type was still in use.
--    is_deleted (true/false, never null) is the marker — expose it as a column /
--    conditional format, do NOT filter the dimension on it at page or report
--    level, since dimension filters propagate down the relationship and would
--    silently drop those history rows from the export.
--  * No row for the fact's -1 ("carer holds no qualification record") — those
--    rows land in Power BI's blank member and drop out as soon as an HR file is
--    selected, matching the PHP filter.

-- Read straight from staging, across every care in the account: no intermediate
-- sits between this mart and cmQualificationsType (macros/union_cares.sql).
with qualification_type_src as (
    {{ union_cares('cm_qualifications_type', 'staging') }}
),

qualification_type as (
    select
        source,
        id,
        name,
        category,
        alertbefore,
        deleted,
        companyid,
        locationid
    from qualification_type_src
),

final as (
    select
        source,
        id as qualification_type_id,
        {{ source_key('source', 'id') }} as hr_file_key,
        name as hr_file_name,
        category,
        case category
            when 1 then 'Additional Requirement'
            when 2 then 'Registrational Requirement'
            when 3 then 'Company Requirement'
            when 4 then 'Legal Requirement'
            when 5 then 'Training Requirement'
            when 100 then 'Private Requirement'
            when 101 then 'Confidential Requirement'
            else ''
        end as hr_file_type,
        -- alert window as typed in the app ('4 week'), and split for filtering
        -- (macros/alert_before.sql)
        nullif(trim(alertbefore::varchar), '') as alert_before,
        {{ alert_before_value('alertbefore') }} as alert_before_value,
        {{ alert_before_unit('alertbefore') }} as alert_before_unit,
        -- true => retired from the company's HR file list; false => still in use.
        -- Boolean, never null (deleted is a nullable timestamp in the source).
        deleted is not null as is_deleted,
        -- when it was retired (audit trail); date, not the raw timestamp — the
        -- clock time carries no meaning for an HR file list
        deleted::date as retired_date,
        companyid as company_id,            -- RLS key (with location_id)
        locationid as location_id
    from qualification_type
)

select * from final
