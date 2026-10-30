-- Customer-facing secure view over mart__carer_qualification_report.
-- RLS enforced here (secure view => customer_access_filter evaluated at query time
-- with the reader's role). The mart carries company_id/location_id per row, so the
-- filter applies directly. Output schema identical to the mart.
select s.*
from {{ ref('mart__carer_qualification_report') }} as s
where {{ customer_access_filter(source_col='s.source', company_col='s.company_id', location_col='s.location_id') }}
