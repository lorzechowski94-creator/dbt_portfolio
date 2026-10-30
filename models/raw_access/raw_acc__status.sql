{{ config(alias='status') }}
select s.* {{ exclude_internal('status') }}
from {{ source('raw_app', 'status') }} as s
where {{ customer_access_filter(shared_company_id=0) }}
