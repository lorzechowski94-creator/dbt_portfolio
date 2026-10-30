{{ config(
    materialized='incremental',
    unique_key='occurrence_date',
    incremental_strategy='delete+insert',
    on_schema_change='sync_all_columns'
) }}

-- Intermediate: expand each recurr template into individual occurrence dates
-- within the report window — full history up to the projection horizon (the end
-- of the third whole month from today, macros/projection_horizon.sql), which the
-- Workforce Capacity outlook needs. The hours reports' scheduled pillars cap it
-- back to their own today + 60 (macros/report_horizon.sql). Set-based port of
-- returnDates().
--
-- Grain: source + recurr_id + occurrence_date. ACCOUNT-WIDE: reads every care's
-- staging at once (macros/union_cares.sql). recurr.id is allocated per care and
-- collides across them, so source opens the grain and the bank-holiday join
-- carries it. The calendar join does NOT — int__report_calendar is a generated
-- date spine with no tenant in it.
--
-- Incremental: delete+insert on occurrence_date. A normal run re-expands every
-- date from 7 days before today up to the horizon and replaces those dates whole,
-- so an occurrence whose template has since been deleted, shortened or reassigned
-- drops out instead of lingering — see macros/report_horizon.sql. Template edits
-- older than the lookback need `dbt build --full-refresh`.
--
-- Pattern rules (faithful to the PHP):
--   * week < 100  -> weekly/fortnightly.
--       - `days`  (week-1 list): weekly cadence — every matching weekday.
--       - `days2` (week-2 list): every N weeks, anchored to the Monday of the
--         week containing dateStart. Interval = 14 days for week<=2, else 7*week.
--   * week >= 100 -> monthly.
--       - 100  : same day-of-month each month (clamped to month length).
--       - 1NY  : tens digit N = 1-4 (nth) / 5 (last); units digit Y = weekday
--                (1=Mon..7=Sun). e.g. 121 = second Monday, 151 = last Monday.
--   * dateStart = dateFinish -> single once-off occurrence.
--   * dateNoShow dates are flagged is_no_show and excluded from Total Scheduled
--     downstream (matches returnDates step 5). NOTE: dateNoShow does NOT feed the
--     Non-Delivered pillar — that comes from statusChangeEventsRemoved.
--   * Bank-holiday occurrences are removed when offBankHolidays = 1 (returnBH,
--     global holidays only — see bank_holidays CTE below).
--
-- Day names: Snowflake dayname() returns Mon..Sun, matching PHP date('D').

with calendar as (
    select calendar_date from {{ ref('int__report_calendar') }}
),

recurr_src as (
    {{ union_cares('recurr', 'staging') }}
),

recurr as (
    select
        source,
        id,
        clientid,
        locationid,
        carerid,
        statusid,
        jobtype,
        hours,
        tea,
        teapay,
        offbankholidays,
        datenoshow,
        datestart,
        datefinish,
        week,
        days,
        days2
    from recurr_src
    where
        deleted is null
        and (confirmsch = 'Yes' or (confirmsch = 'No' and carerid = 0))
        and datestart <= {{ projection_horizon() }}
),

candidates as (
    select
        r.source,
        r.id as recurr_id,
        r.clientid as client_id,
        r.locationid as location_id,
        r.carerid,
        r.statusid,
        r.jobtype,
        r.hours,
        r.tea,
        r.teapay,
        r.offbankholidays,
        r.datenoshow,
        cal.calendar_date as occurrence_date
    from recurr as r
    inner join calendar as cal
        on
            cal.calendar_date
            between r.datestart
            and least(r.datefinish, {{ projection_horizon() }})
            {% if is_incremental() %}
                and cal.calendar_date >= (
                    select dateadd(day, -7, least(coalesce(max(occurrence_date), '2000-01-01'::date), current_date()))
                    from {{ this }}
                )
            {% endif %}
    where
        -- once-off (single-day) recurr
        (r.datestart = r.datefinish and cal.calendar_date = r.datestart)
        -- weekly / fortnightly (week < 100)
        or (
            r.week < 100 and r.datestart <> r.datefinish and (
                -- week-1 days: weekly
                array_contains(
                    dayname(cal.calendar_date)::variant,
                    split(replace(r.days, ' ', ''), ',')
                )
                -- week-2 days: every N weeks, anchored to Monday of dateStart
                or (
                    r.days2 is not null and r.days2 <> ''
                    and array_contains(
                        dayname(cal.calendar_date)::variant,
                        split(replace(r.days2, ' ', ''), ',')
                    )
                    and mod(
                        floor(
                            datediff(
                                day,
                                dateadd(day, -(dayofweekiso(r.datestart) - 1), r.datestart),
                                cal.calendar_date
                            ) / 7
                        ),
                        iff(r.week > 2, r.week, 2)
                    ) = 0
                )
            )
        )

        -- monthly (week >= 100)
        or (
            r.week >= 100 and r.datestart <> r.datefinish and (
                -- code 100: same day-of-month, clamped to the month length
                (
                    r.week = 100
                    and day(cal.calendar_date) = least(day(r.datestart), day(last_day(cal.calendar_date)))
                )
                -- codes 1NY: N = tens digit (1-4 nth, 5 last), Y = units digit (weekday)
                -- e.g. 121 = second Monday, 151 = last Monday
                or (
                    r.week between 111 and 157
                    and dayofweekiso(cal.calendar_date) = mod(r.week, 10)
                    and (
                        (
                            floor(mod(r.week, 100) / 10) between 1 and 4
                            and ceil(day(cal.calendar_date) / 7.0) = floor(mod(r.week, 100) / 10)
                        )
                        or
                        (
                            floor(mod(r.week, 100) / 10) = 5
                            and month(dateadd(day, 7, cal.calendar_date)) <> month(cal.calendar_date)
                        )
                    )
                )
            )
        )
),

-- Flag no-show occurrences (comma-separated YYYY-MM-DD in dateNoShow) instead of
-- dropping them, so downstream can exclude them from Total Scheduled
-- (WHERE not is_no_show), matching returnDates() step 5 which removes them.
-- (Non-Delivered is a separate pillar sourced from statusChangeEventsRemoved.)

-- Bank holidays (returnBH default branch): global holidays only — the data has
-- no area-specific rows, so bankHolidayPersonalisedArea is not needed.
bank_holidays_src as (
    {{ union_cares('bank_holiday_personalised', 'staging') }}
),

bank_holidays as (
    select
        source,
        locationid,
        date as holiday_date
    from bank_holidays_src
    where
        deleted is null
        and scheduledisplay = 1
        and areaid is null
),

final as (
    select
        o.source,
        o.recurr_id,
        o.client_id,
        o.location_id,
        o.carerid,
        o.statusid,
        o.jobtype as job_type_id,
        o.occurrence_date,
        {{ time_to_hours('o.hours') }} * 60 as event_minutes,
        -- teaPay = 1 -> paid break; teaPay 0/NULL -> unpaid (PHP: null = 0).
        -- coalesce(tea, 0): NULL tea must not propagate (else event - NULL = NULL
        -- collapses Total Scheduled to 0 downstream).
        case when coalesce(o.teapay, 0) = 1 then coalesce(o.tea, 0) else 0 end as paid_break_minutes,
        case when coalesce(o.teapay, 0) = 1 then 0 else coalesce(o.tea, 0) end as unpaid_break_minutes,
        (o.carerid = 0 and o.statusid = 1) as is_unassigned,
        coalesce(
            o.datenoshow is not null
            and array_contains(
                to_char(o.occurrence_date, 'YYYY-MM-DD')::variant,
                split(replace(o.datenoshow, ' ', ''), ',')
            ),
            false
        ) as is_no_show
    from candidates as o
    -- remove occurrences that fall on a bank holiday when offBankHolidays = 1
    left join bank_holidays as bh
        on
            o.source = bh.source
            and o.location_id = bh.locationid
            and o.occurrence_date = bh.holiday_date
            and o.offbankholidays = 1
    where bh.holiday_date is null
)

select * from final
