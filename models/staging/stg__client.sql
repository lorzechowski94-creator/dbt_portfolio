-- Staging: current (client) records, one row per id.
-- Reads the raw_access view and de-duplicates defensively on the unique key.
-- Explicit casts/renames belong here once the real source columns are confirmed
-- (currently a typed passthrough).

select *
from {{ ref('raw_acc__client') }}
qualify row_number() over (
    partition by id
    order by updated desc
) = 1
