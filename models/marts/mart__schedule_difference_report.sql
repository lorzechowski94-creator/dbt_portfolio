{{ config(
    materialized='incremental',
    unique_key='occurrence_date',
    incremental_strategy='delete+insert',
    on_schema_change='sync_all_columns'
) }}

-- Mart (FACT/DETAIL): Schedule Difference Report — one row per individual
-- scheduled call occurrence, comparing scheduled template vs matched timesheet.
-- Full history plus a 60-day forward look (macros/report_horizon.sql); a future
-- call has no timesheet yet, so it carries the schedule and timesheet status
-- 'None'. Power BI filters by date (slicer) and job type. RLS keys
-- (source/company_id/location_id) travel on the row for the report secure view.
--
-- Grain: source + recurr_id + occurrence_date. recurr.id is allocated per care, so
-- the care is the first element of the key.
--
-- Power BI must relate ALL FOUR dimensions — the display names are no longer on
-- the row (they cost ~100M copies each). Every relationship except dim_date is on
-- a *_key column, because the ids repeat across cares and a Power BI relationship
-- takes ONE column:
--   client_key      -> mart__dim_client   (client_no, full_name, area_name,
--                                          workgroup, branch, council_id)
--   carer_key       -> mart__dim_carer    (full_name)
--   job_type_key    -> mart__dim_jobtype  (job_type_name); -1 = none at source
--   occurrence_date -> mart__dim_date     (iso_week, day_name, ...) — the
--                                          calendar is shared, no care on it
-- All three ids are non-null on every row (job_type_id via the -1 sentinel), so
-- the keys are too — no row can slip onto Power BI's blank member unnoticed.
-- client_id is the real client.id, NOT the residentId the column used to hold.
--
-- Star schema, column mapping and the legacy-fidelity notes:
-- docs/powerbi_schedule_difference_measures.md. Early / Late ships pre-formatted as
-- early_late ('On time' / '+15' / '- 10') alongside the numeric early_late_minutes
-- the measures aggregate; time_diff_minutes is the one column still needing a Power
-- BI format string.
-- Note in particular that scheduled_time / worked_time are display strings "HH:MM"
-- and therefore NOT summable — hours totals belong to mart__client_hours_report /
-- mart__carer_hours_report, which store them additive.
--
-- Incremental: delete+insert on occurrence_date — the same window as the hours
-- facts. Each run rebuilds every date from 60 days before today up to the report
-- horizon (today + 60) and replaces those dates whole, picking up new days, recent
-- template / timesheet edits, and calls that have since been removed from the
-- schedule. macros/report_horizon.sql has why a fact that looks forward cannot be
-- merged, and why the lookback anchors on least(max(occurrence_date), today).
-- Older backfills need `dbt build --full-refresh`, and so does ADDING A COLUMN:
-- on_schema_change adds it to the existing table as NULL and only the window is
-- rebuilt, so without a full refresh the older history keeps a NULL — for a *_key
-- column, silently dropping out of every Power BI relationship, no error anywhere.
-- CHANGING A COLUMN'S TYPE needs one too: the history cannot be converted in
-- place (the *_key columns went from strings to integers in 2026-09).
-- An empty table falls back to the FULL history: max() over zero rows is NULL,
-- which would filter every row out and leave the mart permanently empty, so the
-- lookback floors it at 2000-01-01. A build that produced no rows then self-heals
-- on the next run instead of needing a manual --full-refresh.

select
    source,
    recurr_id,
    occurrence_date,
    status_id,
    -- Row key for mart__search_index. This fact has no single unique column — its
    -- grain is source + recurr_id + occurrence_date — and the index needs a "one"
    -- side to relate to. The three parts are packed into ONE INTEGER; the layout
    -- and why it is not a string are in _mart__models.yml.
    (
        {{ source_code('source') }} * 1000000000000000
        + recurr_id::int * 100000
        + datediff(day, '1900-01-01'::date, occurrence_date)
    )::bigint as occurrence_key,
    -- Power BI relationship keys (see the dimension note above)
    {{ source_key('source', 'client_id') }} as client_key,
    {{ source_key('source', 'carer_id') }} as carer_key,
    {{ source_key('source', 'job_type_id') }} as job_type_key,
    schedule_start,
    schedule_finish,
    clocked_in,
    clocked_out,
    early_late_minutes,
    early_late,
    scheduled_time,
    worked_time,
    time_diff_minutes,
    cancellation_reason,
    cancellation_comment,
    timesheet_status,
    system_comments,
    company_id,
    location_id
from {{ ref('int__schedule_difference') }}
{% if is_incremental() %}
    where occurrence_date >= (
        select
            dateadd(
                day, -60, least(coalesce(max(this_tbl.occurrence_date), '2000-01-01'::date), current_date())
            )
        from {{ this }} as this_tbl
    )
{% endif %}
