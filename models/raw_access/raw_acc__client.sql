{{ config(alias='client') }}
select s.* {{ exclude_internal('client') }}
from {{ source('raw_app', 'client') }} as s
where {{ customer_access_filter(location_col='s.location') }}
