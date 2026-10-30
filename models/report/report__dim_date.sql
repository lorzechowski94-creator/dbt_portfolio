-- Customer-facing secure view over mart__dim_date.
--
-- DELIBERATELY NO customer_access_filter — the only report model without one. A
-- calendar carries no customer data: it is generated from a date spine, not from
-- any source table, and holds no company_id / location_id to filter on. There is
-- nothing here one tenant could learn about another. Adding a filter would not
-- harden anything; it would BREAK the model, because every reader row would fail
-- the predicate and the date table would come back empty — which in Power BI means
-- every date slicer goes blank and every dated visual returns nothing, silently
-- and with no error.
--
-- Still a secure view (report models set +secure: true) so it grants like its
-- siblings and reader roles need no access to care_management.
select s.*
from {{ ref('mart__dim_date') }} as s
