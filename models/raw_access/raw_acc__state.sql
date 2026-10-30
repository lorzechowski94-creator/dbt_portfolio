{{ config(alias='state') }}
-- Raw access over the global `state` lookup (carer state id -> name). Unlike the
-- tenant tables this reference table has no company/location columns (the source
-- query resolves it by id only), so no customer_access_filter is applied — it
-- exposes only non-sensitive state-name reference data.
select * {{ exclude_internal('state') }}
from {{ source('raw_app', 'state') }}
