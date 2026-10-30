-- Customer-facing secure view over the incremental fact
-- mart__continuity_report. The fact carries no company/location, so RLS
-- keys are looked up from mart__dim_client (one row per source + client_id). LEFT
-- join keeps SYSADMIN's full view; reader roles see only rows whose client maps
-- to their care/company/location. Output schema is identical to the fact (f.*
-- only), so `source` reaches Power BI on the fact itself.
--
-- THE JOIN CARRIES `source`, and client_key is what carries it. client.id is
-- allocated per care and collides across them, so joining on client_id alone would
-- hand care2's client 8842 the RLS keys of care3's client 8842 — a cross-tenant
-- leak, silent and in the customer's favour. Joining on client_key (care and id in
-- one integer, macros/source_key.sql) makes that mistake unavailable: the tenant is
-- inside the value, so no future edit can drop it from the predicate and still
-- compile.
--
-- The RLS predicate still reads the FACT's source (f.source), not the dimension's: on
-- an unmatched left join r.source is null and would match no map row, which is the
-- safe direction, but f.source is never null and says what the row actually is.
select f.*
from {{ ref('mart__continuity_report') }} as f
left join {{ ref('mart__dim_client') }} as r
    on f.client_key = r.client_key
where {{ customer_access_filter(source_col='f.source', company_col='r.company_id', location_col='r.location_id') }}
