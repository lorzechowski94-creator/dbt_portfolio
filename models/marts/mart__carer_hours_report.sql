{{ config(
    materialized='incremental',
    unique_key='service_date',
    incremental_strategy='delete+insert',
    on_schema_change='sync_all_columns'
) }}

-- Mart (FACT): carer hours per carer per service date PER JOB TYPE — full history
-- plus a 60-day forward look (macros/report_horizon.sql). Ports carersHoursRpt.php.
-- Single fact serving BOTH the carer-level report and the jobtype slicer:
--   * carer-level totals -> Power BI sums over all job_type_id (job_type_id is
--     just ignored). Aggregating over the whole grain reconciles exactly to the
--     per-carer figures — this fact is a strict superset of a carer/date fact.
--   * jobtype filter -> slice on job_type_id (relate to mart__dim_jobtype on
--     job_type_key).
-- Demographics live in mart__dim_carer (relate on carer_key).
--
-- Grain: source + carer_id + service_date + job_type_id. carer.id and jobType.id
-- are allocated per care and collide across them, so source opens the grain and
-- rides in carer_key / job_type_key — the columns every Power BI relationship
-- uses, since a relationship there takes ONE column.
--   scheduled   job_type_id = recurr.jobType
--   confirmed   job_type_id = timesheet.jobType
--   worked      job_type_id = timesheet.jobType
--   contracted  job_type_id = NO_JOB_TYPE (-1) — cmContractsHours has no jobType,
--               so its hours land in a single "no job type" row per carer/date.
--               Any pillar row whose source jobType is NULL also collapses into
--               this bucket. This keeps the fact ADDITIVE: summing all rows for a
--               carer gives the correct carer total (contracted counted once, not
--               once per job type). NOTE: with a jobtype slicer active, contracted
--               drops out (it sits on -1). To still show carer-level contracted
--               alongside a jobtype filter, use a DAX measure that ignores the
--               jobtype filter (CALCULATE(..., ALL(dim_jobtype))).
--
--   job_type_id uses a non-null sentinel (-1) rather than NULL on purpose:
--   job_type_key is built from it and source_key() of a NULL id is NULL, so a NULL id
--   would leave the row with no key at all (failing its not_null test) instead of
--   one that names its care. dim_jobtype has no -1 row, so its name resolves to
--   NULL / "No job type".
--
-- ALL stored columns are ADDITIVE and UNROUNDED → any date-range SUM is exact.
-- Non-additive figures (Over/Under, HH:MM, Phone-vs-Admin %) are DAX measures:
--   Over/Under Contracted = SUM(contracted_hrs) - SUM(confirmed_payable_hrs)
--   Confirmed / Contracted / Scheduled (HH:MM)  -> minutes_to_hhmm on the sums
--   Confirmed Phone vs Admin (%) = SUM(carer_confirmed_count)
--                                  / SUM(phone_admin_total_count) * 100
--
-- Incremental: delete+insert on service_date. Each run rebuilds every date from 60
-- days before today up to the report horizon (today + 60) and replaces those dates
-- whole — see macros/report_horizon.sql for why a fact that looks forward cannot
-- be merged, and why the lookback anchors on least(max(service_date), today).
-- Older backfills need `dbt build --full-refresh`, and so does ADDING A COLUMN:
-- on_schema_change adds it to the existing table as NULL and only the window is
-- rebuilt, so without a full refresh the older history keeps a NULL. For a *_key
-- column that history silently drops out of every Power BI relationship and takes
-- its hours with it — no error anywhere.
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

with scheduled as (
    select
        source,
        carer_id,
        service_date,
        coalesce(job_type_id, {{ no_job_type }}) as job_type_id,
        sum(scheduled_hrs) as scheduled_hrs
    from {{ ref('int__carer_scheduled_hours') }}
    {% if is_incremental() %} where {{ incr_lookback }} {% endif %}
    group by 1, 2, 3, 4
),

confirmed as (
    select
        source,
        carer_id,
        service_date,
        coalesce(job_type_id, {{ no_job_type }}) as job_type_id,
        sum(confirmed_payable_hrs) as confirmed_payable_hrs,
        sum(worked_hrs) as worked_hrs,
        sum(phone_admin_total_count) as phone_admin_total_count,
        sum(carer_confirmed_count) as carer_confirmed_count
    from {{ ref('int__carer_confirmed_hours') }}
    where
        service_date <= {{ report_horizon() }}
        {% if is_incremental() %} and {{ incr_lookback }} {% endif %}
    group by 1, 2, 3, 4
),

-- Contracted has NO job type (cmContractsHours lacks the column), so it is
-- attributed to the single NO_JOB_TYPE bucket per carer/date.
contracted as (
    select
        source,
        carer_id,
        service_date,
        {{ no_job_type }} as job_type_id,
        sum(contracted_hrs) as contracted_hrs
    from {{ ref('int__carer_contracted_hours') }}
    {% if is_incremental() %} where {{ incr_lookback }} {% endif %}
    group by 1, 2, 3, 4
),

-- one row per (source, carer, service_date, job_type_id) where any pillar has activity
keys as (
    select
        source,
        carer_id,
        service_date,
        job_type_id
    from scheduled
    union distinct
    select
        source,
        carer_id,
        service_date,
        job_type_id
    from confirmed
    union distinct
    select
        source,
        carer_id,
        service_date,
        job_type_id
    from contracted
),

final as (
    select
        k.source,
        k.service_date,
        -- Power BI relationship keys (see the grain note above)
        {{ source_key('k.source', 'k.carer_id') }} as carer_key,
        {{ source_key('k.source', 'k.job_type_id') }} as job_type_key,
        coalesce(sch.scheduled_hrs, 0) as scheduled_hrs,
        coalesce(cf.confirmed_payable_hrs, 0) as confirmed_payable_hrs,
        coalesce(cf.worked_hrs, 0) as worked_hrs,
        -- contracted: only present on the NO_JOB_TYPE row for each carer/date.
        coalesce(ct.contracted_hrs, 0) as contracted_hrs,
        coalesce(ct.contracted_hrs, 0) - coalesce(cf.confirmed_payable_hrs, 0) as over_under_contracted_hrs,
        coalesce(cf.phone_admin_total_count, 0) as phone_admin_total_count,
        coalesce(cf.carer_confirmed_count, 0) as carer_confirmed_count
    -- every join carries `source`: carer_id and job_type_id repeat across cares,
    -- so without it a carer of care2 would pick up care3's hours.
    from keys as k
    left join scheduled as sch
        on
            k.source = sch.source
            and k.carer_id = sch.carer_id
            and k.service_date = sch.service_date
            and k.job_type_id = sch.job_type_id
    left join confirmed as cf
        on
            k.source = cf.source
            and k.carer_id = cf.carer_id
            and k.service_date = cf.service_date
            and k.job_type_id = cf.job_type_id
    left join contracted as ct
        on
            k.source = ct.source
            and k.carer_id = ct.carer_id
            and k.service_date = ct.service_date
            and k.job_type_id = ct.job_type_id
)

select * from final
