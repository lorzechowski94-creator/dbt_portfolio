-- Staging: status reference data. Passthrough over the raw_access view.
-- Lookup of client state id -> label (type). Explicit casts/renames belong here.

select *
from {{ ref('raw_acc__status') }}
