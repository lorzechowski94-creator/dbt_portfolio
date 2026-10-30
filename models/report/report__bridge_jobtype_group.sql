-- Customer-facing secure view over mart__bridge_jobtype_group.
-- RLS via customer_access_filter (source + company_id + location_id, carried from the group).
select s.*
from {{ ref('mart__bridge_jobtype_group') }} as s
where {{ customer_access_filter(source_col='s.source', company_col='s.company_id', location_col='s.location_id') }}
