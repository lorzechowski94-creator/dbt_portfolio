-- Intermediate: confirmed visit counts per client per carer per service date —
-- the "who visited whom, how often" grain behind the Continuity of Care report.
-- Ports §3.2 / §3.3 of continuityReport.php: the year window and the
-- user-selected period window read the SAME timesheet rows and differ ONLY in
-- their date predicate, so one dated grain serves both and nothing about either
-- window has to be baked in here.
--
-- Grain: source + client_id + location_id + carer_id + service_date (logdate).
-- This model is ACCOUNT-WIDE: it reads every care's staging relations at once
-- (macros/union_cares.sql) and carries the care on the row, because client, carer
-- and location ids are allocated per care and collide across them.
--
-- timeType IS NULL is the report's only row filter — actual delivered visits;
-- cancelled, training and every other timeType are excluded (§7). Note this
-- report does NOT gate on timeConfirmed = 'Yes' the way the client/carer hours
-- pillars do: the legacy queries never mention that column, so neither does this
-- model. Do not "fix" that by adding it — it would silently drop visits the
-- legacy report counts.
--
-- One row PER CARER is the whole point. The report's headline metric divides
-- COUNT(DISTINCT carerId) by COUNT(id) over a user-picked range, and a distinct
-- count cannot be pre-aggregated and later summed. Keeping the carer on the row
-- pushes the distinct count downstream, where Power BI evaluates it against
-- whatever range the user actually selected.
--
-- visit_count is COUNT(timesheet.id) — the report's "Visits" figure and the
-- denominator of the continuity ratio. It stays additive.

with timesheet_src as (
    {{ union_cares('timesheet', 'staging') }}
),

timesheet as (
    select
        source,
        clientid,
        locationid,
        carerid,
        logdate
    from timesheet_src
    where
        timetype is null
        and locationid is not null
        and clientid is not null
),

final as (
    select
        source,
        clientid as client_id,
        locationid as location_id,
        carerid as carer_id,
        logdate as service_date,
        count(*) as visit_count
    from timesheet
    group by 1, 2, 3, 4, 5
)

select * from final
