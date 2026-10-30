-- Customer-facing secure view over mart__anniversary_report.
-- RLS enforced here (secure view => customer_access_filter evaluated at query time
-- with the reader's role). Reader roles get SELECT on this schema only, never on
-- the underlying care_management mart table.
select s.*
from {{ ref('mart__anniversary_report') }} as s
where {{ customer_access_filter(source_col='s.source', company_col='s.company_id', location_col='s.location_id') }}
