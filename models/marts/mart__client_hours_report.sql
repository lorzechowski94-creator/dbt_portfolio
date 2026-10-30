{{ config(
    materialized='incremental',
    unique_key='service_date',
    incremental_strategy='delete+insert',
    on_schema_change='sync_all_columns'
) }}

-- Mart (FACT): client hours per client per service date PER JOB TYPE — the single
-- fact behind BOTH client hours reports. Power BI aggregates it to one row per
-- client (Client Hours) or one row per client × job type (Client Hours by Job
-- Type) for the selected date range; leaving job type off a visual sums the job
-- type rows back to the exact client total, so no client-level sibling fact is
-- needed. Thin numeric fact — demographics live in mart__dim_client
-- (relate on client_key), the JobType name in mart__dim_jobtype (relate on
-- job_type_key), group filtering via mart__bridge_jobtype_group.
--
-- Grain: source + client_id + service_date + job_type_id. client.id and jobType.id
-- are allocated per care and collide across them, so source opens the grain and
-- rides in client_key / job_type_key — the columns every Power BI relationship
-- uses, since a relationship there takes ONE column.
--   delivered  service_date = timesheet.logDate
--   scheduled  service_date = recurr occurrence date
--   allocated  service_date = cmAssignedHours occurrence date
--   non-deliv. service_date = statusChangeEventsRemoved.recurrDate
--
--   scheduled  job_type_id = recurr.jobType
--   delivered  job_type_id = timesheet.jobType
--   allocated  job_type_id = cmAssignedHours.jobType
--   non-deliv. job_type_id = statusChangeEventsRemoved.jobType
--
--   ALL FOUR pillars carry a real job type; a row whose source jobType is NULL
--   collapses into the NO_JOB_TYPE (-1) bucket. So -1 means exactly one thing —
--   "job type missing at source" — and every pillar reaches it the same way.
--
--   Non-delivered is a DEVIATION FROM LEGACY: the PHP never selected the jobType
--   column (it exists in the table) and repeated one client-level non-delivered
--   total on every job type row. Here each removed event lands on the job type it
--   was scheduled under, so no DAX filter-removal is needed for it any more.
--
--   The fact stays ADDITIVE throughout: every source row contributes to exactly
--   one (client, date, job type) cell, so summing all job type rows for a client
--   reproduces the client total exactly.
--
--   job_type_id uses a non-null sentinel (-1) rather than NULL on purpose:
--   job_type_key is built from it and source_key() of a NULL id is NULL, so a NULL id
--   would leave the row with no key at all (failing its not_null test) instead of
--   one that names its care. dim_jobtype has no -1 row, so its name resolves to
--   NULL / "No job type".
--
-- ALL stored columns are ADDITIVE and UNROUNDED → any date-range SUM is exact.
-- The non-additive report figures are DAX measures over these columns (they use a
-- per-client "has recurrence" gate / a floor / HH:MM format, so they must be
-- computed after the date filter aggregates). See the DAX reference for:
--   Non-Delivered (excl), A v S, Billable Schedule, Billable v Confirmed,
--   Total Deliverable, Total Scheduled (HH:MM), Total Confirmed (HH:MM).
--
-- Incremental: delete+insert on service_date. Each run rebuilds every date from 60
-- days before today up to the report horizon (today + 60) and replaces those dates
-- whole — see macros/report_horizon.sql for why a fact that looks forward cannot
-- be merged, and why the lookback anchors on least(max(service_date), today).
-- Older backfills need `dbt build --full-refresh`, and so does ADDING A COLUMN:
-- on_schema_change adds it to the existing table as NULL and only the window is
-- rebuilt, so without a full refresh the older history keeps a NULL. For a *_key
-- column that history silently drops out of every Power BI relationship and takes
-- its hours with it — no error anywhere, just a shrinking report.
-- An empty table falls back to the FULL history: max() over zero rows is NULL,
-- which would filter every row out and leave the mart permanently empty, so the
-- lookback floors it at 2000-01-01. A build that produced no rows then self-heals
-- on the next run instead of needing a manual --full-refresh.
{% set no_job_type = -1 %}

{% set incr_lookback %}
    service_date >= (
        select dateadd(day, -60, least(coalesce(max(service_date), '2000-01-01'::date), current_date()))
        from {{ this }}
    )
{% endset %}

with allocated as (
    select
        source,
        client_id,
        service_date,
        coalesce(job_type_id, {{ no_job_type }}) as job_type_id,
        sum(allocated_hrs) as allocated_hrs
    from {{ ref('int__client_allocated_hours') }}
    -- allocated runs on to the capacity outlook's projection horizon; this report
    -- stops at its own
    where
        service_date <= {{ report_horizon() }}
        {% if is_incremental() %} and {{ incr_lookback }} {% endif %}
    group by 1, 2, 3, 4
),

scheduled as (
    select
        source,
        client_id,
        service_date,
        coalesce(job_type_id, {{ no_job_type }}) as job_type_id,
        sum(scheduled_event_hrs_all) as scheduled_event_hrs_all,
        sum(scheduled_unpaid_break_hrs_all) as scheduled_unpaid_break_hrs_all,
        sum(scheduled_paid_break_hrs_all) as scheduled_paid_break_hrs_all,
        sum(scheduled_event_hrs_unassigned) as scheduled_event_hrs_unassigned,
        sum(scheduled_unpaid_break_hrs_unassigned) as scheduled_unpaid_break_hrs_unassigned,
        sum(scheduled_paid_break_hrs_unassigned) as scheduled_paid_break_hrs_unassigned
    from {{ ref('int__client_scheduled_hours') }}
    {% if is_incremental() %} where {{ incr_lookback }} {% endif %}
    group by 1, 2, 3, 4
),

delivered as (
    select
        source,
        client_id,
        service_date,
        coalesce(job_type_id, {{ no_job_type }}) as job_type_id,
        sum(confirmed_payable_hrs) as confirmed_payable_hrs,
        sum(cancelled_timesheet_billed_hrs) as cancelled_billed_hrs,
        sum(cancelled_timesheet_not_billed_hrs) as cancelled_not_billed_hrs,
        sum(total_actual_time_hrs) as total_actual_time_hrs,
        sum(confirmed_breaks_paid_hrs) as confirmed_breaks_paid_hrs,
        sum(confirmed_breaks_unpaid_hrs) as confirmed_breaks_unpaid_hrs
    from {{ ref('int__client_delivered_hours') }}
    where
        service_date <= {{ report_horizon() }}
        {% if is_incremental() %} and {{ incr_lookback }} {% endif %}
    group by 1, 2, 3, 4
),

-- Non-delivered carries statusChangeEventsRemoved.jobType like every other
-- pillar; NULLs fall back to the NO_JOB_TYPE bucket.
non_delivered as (
    select
        source,
        client_id,
        service_date,
        coalesce(job_type_id, {{ no_job_type }}) as job_type_id,
        sum(non_delivered_incl_cancelled_hrs) as non_delivered_incl_cancelled_hrs
    from {{ ref('int__client_non_delivered_hours') }}
    {% if is_incremental() %} where {{ incr_lookback }} {% endif %}
    group by 1, 2, 3, 4
),

-- one row per (source, client, service_date, job_type_id) where any pillar has activity
keys as (
    select
        source,
        client_id,
        service_date,
        job_type_id
    from allocated
    union distinct
    select
        source,
        client_id,
        service_date,
        job_type_id
    from scheduled
    union distinct
    select
        source,
        client_id,
        service_date,
        job_type_id
    from delivered
    union distinct
    select
        source,
        client_id,
        service_date,
        job_type_id
    from non_delivered
),

final as (
    select
        k.source,
        k.service_date,

        -- Power BI relationship keys (see the grain note above)
        {{ source_key('k.source', 'k.client_id') }} as client_key,
        {{ source_key('k.source', 'k.job_type_id') }} as job_type_key,

        -- contracted / scheduled
        coalesce(a.allocated_hrs, 0) as allocated_hrs,
        coalesce(s.scheduled_event_hrs_all - s.scheduled_unpaid_break_hrs_all, 0) as total_scheduled_hrs,
        coalesce(s.scheduled_event_hrs_unassigned - s.scheduled_unpaid_break_hrs_unassigned, 0)
            as scheduled_unassigned_hrs,
        coalesce(s.scheduled_event_hrs_all, 0) as scheduled_event_hrs_all,  -- for HH:MM measure

        -- non-delivered (incl); excl is a DAX measure. Split per job type, so it
        -- sits on the job type row it was scheduled under (-1 only when NULL).
        coalesce(nd.non_delivered_incl_cancelled_hrs, 0) as non_delivered_incl_cancelled_hrs,

        -- delivered / timesheet
        coalesce(d.cancelled_billed_hrs, 0) as cancelled_timesheet_billed_hrs,
        coalesce(d.cancelled_not_billed_hrs, 0) as cancelled_timesheet_not_billed_hrs,
        coalesce(d.confirmed_payable_hrs, 0) as confirmed_payable_hrs,  -- for HH:MM + Total Confirmed
        coalesce(d.confirmed_payable_hrs, 0) - coalesce(d.cancelled_not_billed_hrs, 0) as total_confirmed_billed_hrs,
        coalesce(d.total_actual_time_hrs, 0) as total_actual_time_hrs,
        coalesce(a.allocated_hrs, 0)
        - (coalesce(d.confirmed_payable_hrs, 0) - coalesce(d.cancelled_not_billed_hrs, 0)) as schedule_difference_hrs,

        -- breaks
        coalesce(s.scheduled_paid_break_hrs_all - s.scheduled_paid_break_hrs_unassigned, 0)
            as breaks_paid_scheduled_hrs,
        coalesce(s.scheduled_unpaid_break_hrs_all - s.scheduled_unpaid_break_hrs_unassigned, 0)
            as breaks_unpaid_scheduled_hrs,
        coalesce(s.scheduled_paid_break_hrs_unassigned, 0) as breaks_paid_scheduled_unassigned_hrs,
        coalesce(s.scheduled_unpaid_break_hrs_unassigned, 0) as breaks_unpaid_scheduled_unassigned_hrs,
        coalesce(d.confirmed_breaks_paid_hrs, 0) as breaks_paid_confirmed_hrs,
        coalesce(d.confirmed_breaks_unpaid_hrs, 0) as breaks_unpaid_confirmed_hrs

    -- every join carries `source`: client_id and job_type_id repeat across cares,
    -- so without it a client of care2 would pick up care3's hours.
    from keys as k
    left join allocated as a
        on
            k.source = a.source
            and k.client_id = a.client_id
            and k.service_date = a.service_date
            and k.job_type_id = a.job_type_id
    left join scheduled as s
        on
            k.source = s.source
            and k.client_id = s.client_id
            and k.service_date = s.service_date
            and k.job_type_id = s.job_type_id
    left join delivered as d
        on
            k.source = d.source
            and k.client_id = d.client_id
            and k.service_date = d.service_date
            and k.job_type_id = d.job_type_id
    left join non_delivered as nd
        on
            k.source = nd.source
            and k.client_id = nd.client_id
            and k.service_date = nd.service_date
            and k.job_type_id = nd.job_type_id
)

select * from final
