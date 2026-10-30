-- Intermediate: "delivered" pillar of the client hours report (timesheet).
-- Aggregates confirmed timesheet measures per client per service date, so the
-- mart can apply the selected date range and roll up to one row per client.
-- Only confirmed timesheets count (timeConfirmed = 'Yes'), matching the report.
--
-- Grain: source + client_id + location_id + job_type_id + service_date (logdate).
-- ACCOUNT-WIDE: reads every care's staging at once (macros/union_cares.sql). The
-- stray-location filter below counts and joins PER CARE — client and location ids
-- collide across cares, so a global count would pool two tenants' timesheets and
-- silently keep or drop the wrong locations.
-- job_type_id (timesheet.jobType) lets the jobtype mart split per job type; the
-- client-level mart re-aggregates over it (group by client + date), unchanged.
--
-- Snowflake note: payableTime and duration are TIME columns here, so we convert
-- them to decimal hours via time_to_hours(). tea is break minutes (integer).
--
-- Raw components only — the mart derives the combined figures:
--   total_confirmed_billed = confirmed_payable_hrs - cancelled_not_billed_hrs

with timesheet_src as (
    {{ union_cares('timesheet', 'staging') }}
),

all_timesheet as (
    select
        source,
        clientid,
        locationid,
        jobtype,
        logdate,
        payabletime,
        timetype,
        dontbill,
        duration,
        teapay,
        tea,
        timeconfirmed
    from timesheet_src
    where locationid is not null
),

-- Skip (client, location) combos with only 1 timesheet — treated as a stray
-- mis-entry — UNLESS it is the client's only location (keep low-activity clients).
loc_counts as (
    select
        source,
        clientid,
        locationid,
        count(*) as ts_count
    from all_timesheet
    group by 1, 2, 3
),

client_loc_n as (
    select
        source,
        clientid,
        count(*) as n_locs
    from loc_counts
    group by 1, 2
),

valid_locs as (
    select
        lc.source,
        lc.clientid,
        lc.locationid
    from loc_counts as lc
    inner join client_loc_n as cn
        on
            lc.source = cn.source
            and lc.clientid = cn.clientid
    where cn.n_locs = 1 or lc.ts_count > 1
),

timesheet as (
    select
        t.source,
        t.clientid,
        t.locationid,
        t.jobtype,
        t.logdate,
        t.payabletime,
        t.timetype,
        t.dontbill,
        t.duration,
        t.teapay,
        t.tea
    from all_timesheet as t
    inner join valid_locs as v
        on
            t.source = v.source
            and t.clientid = v.clientid
            and t.locationid = v.locationid
    where t.timeconfirmed = 'Yes'
),

final as (
    select
        source,
        clientid as client_id,
        locationid as location_id,
        jobtype as job_type_id,
        logdate as service_date,
        -- All confirmed payable time (any type); mart subtracts not-billed cancels.
        sum({{ time_to_hours('payabletime') }}) as confirmed_payable_hrs,
        -- Cancelled Timesheet (hrs) Billed: timeType = 'Cancelled' and dontBill = 0
        -- (dontBill is NULL for billed rows, so coalesce to 0 before the test)
        sum(case
            when timetype = 'Cancelled' and coalesce(dontbill, 0) = 0
                then {{ time_to_hours('payabletime') }}
        end) as cancelled_timesheet_billed_hrs,
        -- Cancelled Timesheet (hrs) Not Billed: timeType = 'Cancelled' and dontBill = 1
        sum(case
            when timetype = 'Cancelled' and coalesce(dontbill, 0) = 1
                then {{ time_to_hours('payabletime') }}
        end) as cancelled_timesheet_not_billed_hrs,
        -- Total Actual Time: physical clock duration where timeType IS NULL
        sum(case
            when timetype is null
                then {{ time_to_hours('duration') }}
        end) as total_actual_time_hrs,
        -- Confirmed breaks (tea minutes): teaPay = 1 paid, else unpaid. teaPay is
        -- NULL or 1 in the data, so coalesce to 0 before the test (same style as
        -- COALESCE(dontBill, 0)).
        sum(case when coalesce(teapay, 0) = 1 then coalesce(tea, 0) else 0 end) / 60.0 as confirmed_breaks_paid_hrs,
        sum(case when coalesce(teapay, 0) != 1 then coalesce(tea, 0) else 0 end) / 60.0 as confirmed_breaks_unpaid_hrs

    from timesheet
    group by 1, 2, 3, 4, 5
)

select * from final
