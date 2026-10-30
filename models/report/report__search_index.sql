-- Customer-facing secure view over mart__search_index.
-- Every row carries the company_id/location_id of the entity it indexes — copied
-- from the dimension or fact it came from — so one predicate covers all six
-- entities: a reader can only search the rows they can already see.
select s.*
from {{ ref('mart__search_index') }} as s
where {{ customer_access_filter(source_col='s.source', company_col='s.company_id', location_col='s.location_id') }}
