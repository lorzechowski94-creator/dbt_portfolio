{{ config(
    materialized='incremental',
    unique_key=['client_key', 'service_date', 'carer_key'],
    incremental_strategy='merge',
    on_schema_change='sync_all_columns'
) }}

-- Mart (FACT): the Continuity of Care report — one row per client per service
-- date per carer, full history / all dates, every care in the account. Ports
-- continuityReport.php.
--
-- Grain: source + client_id + service_date + carer_id. client.id and carer.id are
-- allocated per care and collide across them, so source opens the grain and the
-- merge key, and rides in client_key / carer_key — the columns every Power BI
-- relationship uses, since a relationship there takes ONE column.
--
-- THE MERGE KEY IS SPELLED WITH THOSE SAME *_key COLUMNS. `source` is inside the
-- value, so it cannot be dropped from the predicate by a later edit — the failure
-- mode being guarded against is a merge that silently matches one care's row to
-- another's. Logically identical to ['source', 'client_id', 'service_date',
-- 'carer_id'] because source_key is injective, so existing rows re-keyed themselves
-- on a normal run: that spelling change needed no --full-refresh. (The hours and
-- schedule difference facts no longer merge at all: they look forward, so they
-- replace whole dates instead — macros/report_horizon.sql. This fact counts
-- delivered visits only and stops at today, so it has no forecast rows to go
-- stale and keeps its merge.)
--
-- Sole measure: visit_count (COUNT of delivered timesheets, timeType IS NULL).
--
-- WHY THE CARER IS ON THE GRAIN, AND WHY THE REPORT'S COLUMNS ARE NOT STORED
-- The report's core metric is 1 - COUNT(DISTINCT carerId) / COUNT(id): how few
-- different carers a client sees. A distinct count is NOT additive — you cannot
-- store "carers in January" and "carers in February" and add them to get carers
-- in Q1, because a carer working both months would count twice. So no continuity
-- figure and no carer count can be stored against a date range at all; storing
-- them would only fix the report to one window. Instead this fact keeps the carer
-- ON the row and Power BI takes DISTINCTCOUNT(carer_id) after the user's date
-- filter has been applied. Same rule as mart__client_hours_report: every stored
-- column is additive and unrounded, every non-additive figure is a DAX measure.
--
-- THAT ALSO COLLAPSES THE REPORT'S TWO WINDOWS INTO ONE FACT
-- Legacy runs two near-identical queries per client — a full-calendar-year window
-- (§3.2) and the user's selected range (§3.3) — and shows them side by side. Both
-- read the same rows with a different date predicate, so both sets of columns come
-- from this one fact: the Period measures read the current filter, the Year
-- measures re-apply it snapped out to whole calendar years (§4.3). No stored year
-- column, and changing the date slicer cannot desynchronise the two halves.
--
-- EVERY DISPLAYED COLUMN IS A DAX MEASURE over report__continuity_report.
-- Full definitions, star schema and legacy-fidelity notes:
--     docs/powerbi_continuity_report_measures.md
-- Four base measures (Visits, Carers, Continuity, Continuity %) plus a Year wrapper
-- each; no separate totals measure. Three traps documented there that are easy to
-- "simplify" away and must not be:
--   * Carers is a SUMX over clients, not a bare DISTINCTCOUNT — legacy's totals row
--     sums PER-CLIENT distinct counts (§4.4), so a carer serving two clients counts
--     twice. A global distinct reports a HIGHER continuity % than the old report.
--     Whether legacy's double-counting total is the one to keep is an OPEN business
--     decision; this fact supports either.
--   * Continuity % keeps an explicit "carers = 1 -> 100%" branch (legacy §4.1). The
--     general formula would read 90% for one carer over 10 visits.
--   * Continuity is NOT [Continuity %] / 100 — legacy rounds the ratio and the
--     percentage to 2dp independently.
--
-- CLIENT SCOPE comes for free. Legacy §3.1 lists only clients with at least one
-- visit in the calendar year; this fact only holds rows where a visit exists, so a
-- client with none simply has no rows in the window and drops out of the visual.
--
-- NO JOB TYPE dimension: the report covers all visit types equally (§7), so
-- job_type_id is deliberately absent from the grain.
--
-- NO location_id: dropped when rolling up from int__client_carer_visits, matching
-- mart__client_hours_report. Legacy scopes each run to one locationId; here the
-- reader's care/company/location is enforced by report__continuity_report via
-- mart__dim_client, and a client's visits across locations aggregate together.
-- `source` is NOT the same kind of column and is not dropped: it completes the
-- otherwise-colliding ids, and the RLS predicate matches on it.
--
-- Display columns (Client Name, Social Services Ref = client_no, Area, Branch)
-- all live in mart__dim_client — relate on source + client_id. Carer names, if the
-- report ever drills into them, are in mart__dim_carer — relate on source +
-- carer_id.
--
-- Colour coding (§4.2) is Power BI conditional formatting on the % measures:
-- > 90 green, > 70 and <= 90 orange, <= 70 red.
--
-- carer_id uses a non-null sentinel (-1) rather than NULL because it is part of
-- the incremental merge key, and a NULL merge key never matches (NULL = NULL is
-- false) — those rows would re-insert on every run. It also keeps the DISTINCT
-- count honest: MySQL's COUNT(DISTINCT carerId) skips NULLs, so the Carers measure
-- above excludes -1 to match. dim_carer has no -1 row, so a name resolves to NULL.
--
-- Incremental: rolling 60-day window re-merged each run (new days + recent edits
-- to already-loaded days). Older backfills need `dbt build --full-refresh`, and
-- so does the first build after `source` joined the merge key — pre-existing rows
-- carry the old key and will not re-key themselves. client_key / carer_key NEED
-- ONE TOO, for a different reason: on_schema_change adds a new column to the
-- existing table as NULL and only the rows inside the 60-day window are re-merged,
-- so without a full refresh the older history keeps a NULL key, silently drops out
-- of every Power BI relationship and takes its visits with it — no error anywhere.
-- An empty table falls back to the FULL history: max() over zero rows is NULL,
-- which would filter every row out and leave the mart permanently empty, so the
-- lookback floors it at 2000-01-01. A build that produced no rows then self-heals
-- on the next run instead of needing a manual --full-refresh.
{% set no_carer = -1 %}

{% set incr_lookback %}
    service_date >= (select dateadd(day, -60, coalesce(max(service_date), '2000-01-01'::date)) from {{ this }})
{% endset %}

with aggregated as (
    select
        source,
        client_id,
        service_date,
        coalesce(carer_id, {{ no_carer }}) as carer_id,
        sum(visit_count) as visit_count
    from {{ ref('int__client_carer_visits') }}
    where
        service_date <= current_date()
        {% if is_incremental() %} and {{ incr_lookback }} {% endif %}
    group by 1, 2, 3, 4
),

final as (
    select
        source,
        service_date,
        visit_count,
        -- Power BI relationship keys (see the grain note above)
        {{ source_key('source', 'client_id') }} as client_key,
        {{ source_key('source', 'carer_id') }} as carer_key
    from aggregated
)

select * from final
