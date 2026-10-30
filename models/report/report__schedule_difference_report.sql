-- Customer-facing secure view over the fact mart__schedule_difference_report.
-- RLS enforced here (secure view => customer_access_filter evaluated at query time
-- with the reader's role). The fact carries company_id/location_id per row, so the
-- filter applies directly (no dim lookup). Output schema identical to the fact.
select s.*
from {{ ref('mart__schedule_difference_report') }} as s
where {{ customer_access_filter(source_col='s.source', company_col='s.company_id', location_col='s.location_id') }}
