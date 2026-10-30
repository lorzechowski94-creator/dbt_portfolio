-- Mart (FACT): workforce headcount and movement per location and area per day —
-- the staff and customers active on the date, and the joiners and leavers dated on
-- it, from each location area's first recorded start up to today. Behind the Staff
-- & Customer Movement cards, the headcount trend and the joiners-vs-leavers chart;
-- the hours are in mart__workforce_capacity.
--
-- Grain: source + location_id + area_id + calendar_date, built from the two spell
-- models. A person counts at their location and area from start_date up to, not
-- including, leave_date. Active is a running sum of joins minus leaves, so
-- active(d) - active(d - 1) = joined(d) - left(d) on every row. Starts before
-- 2000-01-01, where the calendar begins, open the balance on that date without
-- counting as joiners. Days with nobody active and no movement are left out.

{% set calendar_start = "'2000-01-01'::date" %}

with carers as (
    select
        source,
        location_id,
        area_id,
        start_date,
        leave_date
    from {{ ref('int__carer_employment_spell') }}
),

clients as (
    select
        source,
        location_id,
        area_id,
        start_date,
        leave_date
    from {{ ref('int__client_service_spell') }}
),

events as (
    select
        source,
        location_id,
        area_id,
        start_date as event_date,
        1 as staff_delta,
        0 as customer_delta
    from carers
    union all
    select
        source,
        location_id,
        area_id,
        leave_date as event_date,
        -1 as staff_delta,
        0 as customer_delta
    from carers
    where leave_date is not null
    union all
    select
        source,
        location_id,
        area_id,
        start_date as event_date,
        0 as staff_delta,
        1 as customer_delta
    from clients
    union all
    select
        source,
        location_id,
        area_id,
        leave_date as event_date,
        0 as staff_delta,
        -1 as customer_delta
    from clients
    where leave_date is not null
),

daily_events as (
    select
        source,
        location_id,
        area_id,
        greatest(event_date, {{ calendar_start }}) as calendar_date,
        sum(staff_delta) as staff_delta,
        sum(customer_delta) as customer_delta,
        count_if(staff_delta = 1 and event_date >= {{ calendar_start }}) as staff_joined,
        count_if(staff_delta = -1 and event_date >= {{ calendar_start }}) as staff_left,
        count_if(customer_delta = 1 and event_date >= {{ calendar_start }}) as customers_joined,
        count_if(customer_delta = -1 and event_date >= {{ calendar_start }}) as customers_left
    from events
    -- a start still to come has not happened yet
    where event_date <= current_date()
    group by 1, 2, 3, 4
),

-- every date from the location area's first event to today, so the running sums
-- have a row to land on for days without movement
grid as (
    select
        f.source,
        f.location_id,
        f.area_id,
        cal.calendar_date
    from (
        select
            source,
            location_id,
            area_id,
            min(calendar_date) as first_date
        from daily_events
        group by 1, 2, 3
    ) as f
    inner join {{ ref('int__report_calendar') }} as cal
        on cal.calendar_date between f.first_date and current_date()
),

running as (
    select
        g.source,
        g.location_id,
        g.area_id,
        g.calendar_date,
        sum(coalesce(e.staff_delta, 0)) over (
            partition by g.source, g.location_id, g.area_id
            order by g.calendar_date
            rows between unbounded preceding and current row
        ) as active_staff,
        coalesce(e.staff_joined, 0) as staff_joined,
        coalesce(e.staff_left, 0) as staff_left,
        sum(coalesce(e.customer_delta, 0)) over (
            partition by g.source, g.location_id, g.area_id
            order by g.calendar_date
            rows between unbounded preceding and current row
        ) as active_customers,
        coalesce(e.customers_joined, 0) as customers_joined,
        coalesce(e.customers_left, 0) as customers_left
    from grid as g
    left join daily_events as e
        on
            g.source = e.source
            and g.location_id = e.location_id
            -- a null area (free text, or none) is a bucket of its own
            and equal_null(g.area_id, e.area_id)
            and g.calendar_date = e.calendar_date
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
        r.source,
        r.calendar_date,
        l.company_id,
        r.location_id,
        r.area_id,
        {{ source_key('r.source', 'r.location_id') }} as location_key,
        r.active_staff,
        r.staff_joined,
        r.staff_left,
        r.active_customers,
        r.customers_joined,
        r.customers_left
    from running as r
    -- the join carries `source`: location ids repeat across cares
    left join locations as l
        on
            r.source = l.source
            and r.location_id = l.location_id
    where
        r.active_staff > 0
        or r.active_customers > 0
        or r.staff_joined + r.staff_left + r.customers_joined + r.customers_left > 0
)

select * from final
