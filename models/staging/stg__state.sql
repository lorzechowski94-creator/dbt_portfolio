-- Staging: state reference data. Passthrough over the raw_access view.
-- Lookup of carer state id -> name (state 3 is displayed as "Archived" downstream).

select *
from {{ ref('raw_acc__state') }}
