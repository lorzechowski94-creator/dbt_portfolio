-- Intermediate: one row per client with the period they were an active customer —
-- the customer side of the workforce capacity headcount, and the window the
-- demand pillars of that report are clipped to.
--
-- Grain: source + client_id. ACCOUNT-WIDE: reads every care's staging at once
-- (macros/union_cares.sql).
--
-- The spell is [start_date, leave_date), exactly as int__carer_employment_spell:
--   start_date  the first plausible of inductionDate (service commencement),
--               admissionDate and the day the record was created — plausible
--               meaning from 1990 to a year ahead
--   leave_date  client.deleted, for a client no longer Active

{% set plausible_from = "'1990-01-01'::date" %}
{% set plausible_to = "dateadd(year, 1, current_date())" %}

with client_src as (
    {{ union_cares('client', 'staging') }}
),

client as (
    select
        source,
        id,
        state,
        inductiondate,
        admissiondate,
        created,
        deleted,
        location,
        area
    from client_src
    where
        -- 4 = Deleted: a removed record, not a leaver
        state in (1, 2, 3)
        -- a non-Active client with no deleted stamp never left Active, so never
        -- joined it either (created straight into Pending)
        and (state = 1 or deleted is not null)
        and location is not null
),

spells as (
    select
        source,
        id as client_id,
        state as state_id,
        case
            when inductiondate between {{ plausible_from }} and {{ plausible_to }} then inductiondate
            when admissiondate between {{ plausible_from }} and {{ plausible_to }} then admissiondate
            else created::date
        end as start_date,
        iff(state = 1, null, deleted::date) as leave_date,
        location as location_id,
        try_to_number(area::varchar) as area_id
    from client
)

select *
from spells
where
    start_date is not null
    -- a leave on or before the start is a record that never became a customer
    and (leave_date is null or leave_date > start_date)
