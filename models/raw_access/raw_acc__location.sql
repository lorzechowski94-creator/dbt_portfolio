{{ config(alias='location') }}
select s.* {{ exclude_internal('location') }}
from {{ source('raw_app', 'location') }} as s
where {{ customer_access_filter(location_col='s.id') }}
