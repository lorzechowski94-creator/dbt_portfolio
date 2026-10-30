-- Intermediate: one row per care worker with the period they were in the active
-- workforce — the staff side of the workforce capacity headcount, and the window
-- every staff-hours pillar of that report is clipped to.
--
-- Grain: source + carer_id. ACCOUNT-WIDE: reads every care's staging at once
-- (macros/union_cares.sql).
--
-- The spell is [start_date, leave_date): active from start_date, gone on
-- leave_date, open while leave_date is null.
--   start_date  carer.startDate, or the day the record was created when startDate
--               is missing or implausible (before 1990, or more than a year out)
--   leave_date  carer.deleted, for a carer no longer Active

with carer_src as (
    {{ union_cares('carer', 'staging') }}
),

carer as (
    select
        source,
        id,
        state,
        startdate,
        created,
        deleted,
        location,
        area
    from carer_src
    where
        -- care workers only; 2 = top-level admin, 3 = local admin
        permissionid = 4
        -- 4 = Deleted: a removed record, not a leaver
        and state in (1, 2, 3)
        -- a non-Active carer with no deleted stamp never left Active, so never
        -- joined it either (created straight into Pending)
        and (state = 1 or deleted is not null)
        and location is not null
),

spells as (
    select
        source,
        id as carer_id,
        state as state_id,
        iff(
            startdate between '1990-01-01'::date and dateadd(year, 1, current_date()),
            startdate,
            created::date
        ) as start_date,
        iff(state = 1, null, deleted::date) as leave_date,
        location as location_id,
        try_to_number(area::varchar) as area_id
    from carer
)

select *
from spells
where
    start_date is not null
    -- a leave on or before the start is a record that never joined the workforce
    and (leave_date is null or leave_date > start_date)
