{{ config(alias='company') }}
-- COMPANY has no location column; filter by company id only.
select s.* {{ exclude_internal('company') }}
from {{ source('raw_app', 'company') }} as s
where {{ customer_access_filter(company_col='s.id', location_col=none) }}
