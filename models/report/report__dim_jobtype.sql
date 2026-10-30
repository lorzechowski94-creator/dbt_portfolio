-- Customer-facing secure view over mart__dim_jobtype.
-- RLS via customer_access_filter (source + company_id + location_id).
select s.*
from {{ ref('mart__dim_jobtype') }} as s
where {{ customer_access_filter(source_col='s.source', company_col='s.company_id', location_col='s.location_id') }}
