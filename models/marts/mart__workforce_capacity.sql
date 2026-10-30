{{ config(
    materialized='incremental',
    unique_key='calendar_date',
    incremental_strategy='delete+insert',
    on_schema_change='sync_all_columns'
) }}

-- Mart (FACT): the hours behind the Workforce Capacity report — supply per carer
-- per day and demand per location per day, full history plus the three-month
-- outlook up to the projection horizon (macros/projection_horizon.sql). Headcount
-- and movement are in mart__workforce_movement.
--
-- Grain: source + location_id + area_id + carer_id + calendar_date.
--   supply rows   one per carer, at the carer's location and area: contracted,
--                 available, scheduled
--   demand rows   one per location and client area, carer_id = NO_CARER (-1):
--                 customer contracted, unassigned, inactive-carer hours
-- The -1 row keeps every column additive, the same device as NO_JOB_TYPE in
-- mart__carer_hours_report; the carer_key it gets (source_key of -1) matches no dim_carer row.
-- company_id comes from the location, like the role map it is matched against.
--
-- Incremental: delete+insert on calendar_date, rebuilding every date from 60 days
-- before today up to the projection horizon — see macros/report_horizon.sql for
-- why a fact that looks forward is replaced rather than merged, and why the
-- lookback anchors on least(max(calendar_date), today). Older backfills and new
-- columns need `dbt build --full-refresh`. An empty table falls back to the full
-- history (the lookback floors max() at 2000-01-01).

{% set no_carer = -1 %}

{% set lookback_start %}
    (
        select dateadd(day, -60, least(coalesce(max(calendar_date), '2000-01-01'::date), current_date()))
        from {{ this }}
    )
{% endset %}

with contracted as (
    select
        source,
        location_id,
        area_id,
        carer_id,
        calendar_date,
        contracted_hrs
    from {{ ref('int__workforce_contracted_hours') }}
    {% if is_incremental() %} where calendar_date >= {{ lookback_start }} {% endif %}
),

available as (
    select
        source,
        location_id,
        area_id,
        carer_id,
        calendar_date,
        available_hrs
    from {{ ref('int__workforce_available_hours') }}
    {% if is_incremental() %} where calendar_date >= {{ lookback_start }} {% endif %}
),

scheduled as (
    select
        source,
        location_id,
        area_id,
        coalesce(carer_id, {{ no_carer }}) as carer_id,
        calendar_date,
        scheduled_hrs,
        unassigned_hrs,
        inactive_carer_hrs
    from {{ ref('int__workforce_scheduled_hours') }}
    {% if is_incremental() %} where calendar_date >= {{ lookback_start }} {% endif %}
),

-- Customer contracted hours (cmAssignedHours), at the client's location and area,
-- clipped to the client's service spell: many clients who have left still hold
-- open-ended assigned hours.
customer_contracted as (
    select
        a.source,
        c.location_id,
        c.area_id,
        {{ no_carer }} as carer_id,
        a.service_date as calendar_date,
        a.allocated_hrs as customer_contracted_hrs
    from {{ ref('int__client_allocated_hours') }} as a
    inner join {{ ref('int__client_service_spell') }} as c
        on
            a.source = c.source
            and a.client_id = c.client_id
    where
        (c.leave_date is null or a.service_date < c.leave_date)
        {% if is_incremental() %} and a.service_date >= {{ lookback_start }} {% endif %}
),

pillars as (
    select
        source,
        location_id,
        area_id,
        carer_id,
        calendar_date,
        contracted_hrs,
        0 as available_hrs,
        0 as scheduled_hrs,
        0 as unassigned_hrs,
        0 as inactive_carer_hrs,
        0 as customer_contracted_hrs
    from contracted
    union all
    select
        source,
        location_id,
        area_id,
        carer_id,
        calendar_date,
        0 as contracted_hrs,
        available_hrs,
        0 as scheduled_hrs,
        0 as unassigned_hrs,
        0 as inactive_carer_hrs,
        0 as customer_contracted_hrs
    from available
    union all
    select
        source,
        location_id,
        area_id,
        carer_id,
        calendar_date,
        0 as contracted_hrs,
        0 as available_hrs,
        scheduled_hrs,
        unassigned_hrs,
        inactive_carer_hrs,
        0 as customer_contracted_hrs
    from scheduled
    union all
    select
        source,
        location_id,
        area_id,
        carer_id,
        calendar_date,
        0 as contracted_hrs,
        0 as available_hrs,
        0 as scheduled_hrs,
        0 as unassigned_hrs,
        0 as inactive_carer_hrs,
        customer_contracted_hrs
    from customer_contracted
),

locations as (
    select
        source,
        location_id,
        company_id
    from {{ ref('mart__dim_location') }}
),

final as (
    select
        p.source,
        p.calendar_date,
        l.company_id,
        p.location_id,
        -- TenantArea key: the carer's area on supply rows, the client's on demand rows
        p.area_id,
        -- Power BI relationship keys: ids repeat across cares
        {{ source_key('p.source', 'p.location_id') }} as location_key,
        {{ source_key('p.source', 'p.carer_id') }} as carer_key,
        sum(p.contracted_hrs) as contracted_hrs,
        sum(p.available_hrs) as available_hrs,
        sum(p.scheduled_hrs) as scheduled_hrs,
        sum(p.unassigned_hrs) as unassigned_hrs,
        sum(p.inactive_carer_hrs) as inactive_carer_hrs,
        sum(p.customer_contracted_hrs) as customer_contracted_hrs
    from pillars as p
    -- the join carries `source`: location ids repeat across cares
    left join locations as l
        on
            p.source = l.source
            and p.location_id = l.location_id
    group by 1, 2, 3, 4, 5, 6, 7
)

select * from final
