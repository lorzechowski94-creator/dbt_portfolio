-- Intermediate: "scheduled" pillar of the workforce capacity report — roster
-- occurrences per day, split by who they are booked to, up to the projection
-- horizon (int__recurr_occurrences, macros/projection_horizon.sql).
--
-- Grain: source + location_id + area_id + carer_id + calendar_date. carer_id is NULL
-- on the rows booked to no active care worker; the mart files those under NO_CARER.
--
-- Filters as the Carer Hours scheduled pillar: statusId = 1, no-show dates out,
-- confirmSch enforced upstream, event minutes with no break deduction — so
-- scheduled_hrs reconciles with Carer Hours' Scheduled. Only visits to a customer
-- inside their service spell count: a visit on or after the client left is not
-- demand. Each visit then lands in one of three columns:
--   scheduled_hrs       booked to a care worker inside their employment spell,
--                       at the carer's location and area
--   unassigned_hrs      booked to no one (carerId = 0), at the client's location
--                       and area
--   inactive_carer_hrs  booked to a carer who is not an active care worker on the
--                       date (left, pending, deleted, or not a care worker), at the
--                       client's location and area

with occurrences as (
    select
        source,
        client_id,
        carerid,
        occurrence_date,
        event_minutes
    from {{ ref('int__recurr_occurrences') }}
    where
        not is_no_show
        and statusid = 1
),

clients as (
    select
        source,
        client_id,
        leave_date,
        location_id,
        area_id
    from {{ ref('int__client_service_spell') }}
),

carers as (
    select
        source,
        carer_id,
        leave_date,
        location_id,
        area_id
    from {{ ref('int__carer_employment_spell') }}
),

classified as (
    select
        o.source,
        o.occurrence_date as calendar_date,
        o.event_minutes,
        cl.location_id as client_location_id,
        cl.area_id as client_area_id,
        cr.carer_id,
        cr.location_id as carer_location_id,
        cr.area_id as carer_area_id,
        case
            when o.carerid = 0 then 'unassigned'
            when
                cr.carer_id is not null
                and (cr.leave_date is null or o.occurrence_date < cr.leave_date)
                then 'scheduled'
            else 'inactive_carer'
        end as booking
    from occurrences as o
    inner join clients as cl
        on
            o.source = cl.source
            and o.client_id = cl.client_id
    left join carers as cr
        on
            o.source = cr.source
            and o.carerid = cr.carer_id
    where cl.leave_date is null or o.occurrence_date < cl.leave_date
),

final as (
    select
        source,
        iff(booking = 'scheduled', carer_location_id, client_location_id) as location_id,
        iff(booking = 'scheduled', carer_area_id, client_area_id) as area_id,
        iff(booking = 'scheduled', carer_id, null) as carer_id,
        calendar_date,
        sum(iff(booking = 'scheduled', event_minutes, 0)) / 60.0 as scheduled_hrs,
        sum(iff(booking = 'unassigned', event_minutes, 0)) / 60.0 as unassigned_hrs,
        sum(iff(booking = 'inactive_carer', event_minutes, 0)) / 60.0 as inactive_carer_hrs
    from classified
    group by 1, 2, 3, 4, 5
)

select * from final
