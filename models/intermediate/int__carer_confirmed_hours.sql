-- Intermediate: "confirmed / worked" pillar of the carer hours report (timesheet).
-- Aggregates confirmed timesheet measures per carer per service date, so the mart
-- can apply the selected date range and roll up to one row per carer.
-- Only confirmed timesheets count (timeConfirmed = 'Yes'), matching the report.
--
-- Grain: source + carer_id + location_id + job_type_id + service_date (logdate).
-- ACCOUNT-WIDE: reads every care's staging at once (macros/union_cares.sql) and
-- carries the care, because the ids are allocated per care and collide.
-- job_type_id (timesheet.jobType) is preserved so a per-jobtype mart could reuse
-- this; the carer-level mart re-aggregates over it (group by carer + date).
--
-- Snowflake note: `time` (payable time) and `duration` (actual elapsed time) are
-- TIME columns, converted to decimal hours via time_to_hours(). They are queried
-- separately in the PHP and map to different report columns (§3.2 / §3.3).
--
-- Phone-vs-Admin classification (§3.6 / §4.4) runs on a different subset than the
-- hours totals: it only counts rows with dontPay IS NULL. So both count columns
-- are gated on dontPay IS NULL, kept additive; the % is a downstream measure:
--     carer_confirmed_count / phone_admin_total_count * 100
-- carer-confirmed = comment empty / 'Auto Clock Out' / 'Auto Clock In';
-- admin-confirmed = any other non-empty comment.

with timesheet_src as (
    {{ union_cares('timesheet', 'staging') }}
),

timesheet as (
    select
        source,
        carerid,
        locationid,
        jobtype,
        logdate,
        time,
        duration,
        comment,
        dontpay
    from timesheet_src
    where
        timeconfirmed = 'Yes'
        and locationid is not null
),

final as (
    select
        source,
        carerid as carer_id,
        locationid as location_id,
        jobtype as job_type_id,
        logdate as service_date,
        -- Confirmed (HH:MM): payable time across all confirmed timesheets.
        sum({{ time_to_hours('time') }}) as confirmed_payable_hrs,
        -- Hrs Worked: actual elapsed clock duration.
        sum({{ time_to_hours('duration') }}) as worked_hrs,
        -- Phone-vs-Admin counts (dontPay IS NULL subset only).
        count_if(dontpay is null) as phone_admin_total_count,
        count_if(
            dontpay is null
            and (
                comment is null
                or comment = ''
                or comment in ('Auto Clock Out', 'Auto Clock In')
            )
        ) as carer_confirmed_count
    from timesheet
    group by 1, 2, 3, 4, 5
)

select * from final
