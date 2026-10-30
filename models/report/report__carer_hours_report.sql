-- Customer-facing secure view over the incremental fact mart__carer_hours_report.
-- The fact carries no company/location, so RLS keys are looked up from
-- mart__dim_carer (one row per source + carer_id). LEFT join keeps SYSADMIN's full
-- view; reader roles see only rows whose carer maps to their
-- care/company/location. Output schema is identical to the fact (f.* only), so
-- `source` reaches Power BI on the fact itself.
--
-- THE JOIN CARRIES `source`, inside carer_key — see report__continuity_report.sql
-- for why joining on the bare id across cares is a cross-tenant leak, and why the
-- predicate reads f.source rather than r.source.
select f.*
from {{ ref('mart__carer_hours_report') }} as f
left join {{ ref('mart__dim_carer') }} as r
    on f.carer_key = r.carer_key
where {{ customer_access_filter(source_col='f.source', company_col='r.company_id', location_col='r.location_id') }}
