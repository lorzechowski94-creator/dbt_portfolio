-- Customer-facing secure view over mart__dim_location.
-- RLS enforced here (secure view => customer_access_filter evaluated at query time
-- with the reader's role). The location row is its own RLS key. Output schema
-- identical to the mart.
select s.*
from {{ ref('mart__dim_location') }} as s
where {{ customer_access_filter(source_col='s.source', company_col='s.company_id', location_col='s.location_id') }}
