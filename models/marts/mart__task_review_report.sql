{{ config(
    materialized='incremental',
    unique_key='scheduled_date',
    incremental_strategy='delete+insert',
    on_schema_change='sync_all_columns'
) }}

-- Mart (FACT/DETAIL): Task Review — one row per scheduled task slot per day per
-- result recorded on it, full history plus a 60-day forward look
-- (macros/report_horizon.sql). A slot with nothing recorded is one blank row; a
-- future slot has nothing recorded unless it was entered ahead (a cancellation).
-- Ports companyTaskRpt.php (Digital Task Review); the row rules are documented on
-- int__task_review. RLS keys (source/company_id/location_id, and area_id for the
-- TenantArea role) travel on the row for the report secure view.
--
-- Grain: source + task_assign_id + task_assign_times_id + scheduled_date +
-- result_number.
--
-- Names are not on the row except the few that belong to the result (status, sub
-- status, who recorded it): relate client_key to mart__dim_client and
-- task_schedule_key to mart__dim_task_schedule.
--
-- Incremental: delete+insert on scheduled_date, the same window as the hours
-- facts. Each run rebuilds every date from 60 days before today up to the horizon
-- and replaces those dates whole, picking up late and corrected results, the app's
-- own Due / Missed rewrites of the last days, and schedule edits; a forward row is
-- a forecast of the schedule as it stands at build time, so it is replaced, never
-- merged (macros/report_horizon.sql says why). Older edits need
-- `dbt build --full-refresh`, and so does ADDING A COLUMN: on_schema_change adds
-- it to the existing table as NULL and only the window is rebuilt. An empty table
-- falls back to the full history (the 2000-01-01 floor), as in
-- mart__schedule_difference_report.

select
    source,
    scheduled_date,
    task_assign_id,
    task_schedule_key,
    task_assign_times_id,
    assigned_time,
    assigned_time_minutes,
    time_period_id,
    result_id,
    result_number,
    is_latest_for_slot,
    is_recorded,
    status_id,
    status_name,
    sub_status_id,
    sub_status_name,
    recorded_by_id,
    recorded_by,
    time_recorded,
    comment,
    result_created_at,
    client_id,
    client_key,
    area_id,
    location_key,
    company_id,
    location_id
from {{ ref('int__task_review') }}
{% if is_incremental() %}
    where scheduled_date >= (
        select
            dateadd(
                day, -60, least(coalesce(max(this_tbl.scheduled_date), '2000-01-01'::date), current_date())
            )
        from {{ this }} as this_tbl
    )
{% endif %}
