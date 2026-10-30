-- Mart (DIMENSION): the shared Power BI date table — one row per calendar date
-- from 2000-01-01 through 31 Dec of the year the projection horizon (the end of the
-- third whole month from today, macros/projection_horizon.sql) falls in. Relate every dated fact to
-- it on its date column (mart__continuity_report.service_date,
-- mart__client_hours_report.service_date, ...) and mark it as the model's Date
-- table in Power BI. All date slicers should filter this, never a fact.
--
-- Grain: calendar_date.
--
-- SCOPE — deliberately wider than any one report needs. The continuity report
-- requires exactly two columns: calendar_date (the from/to slicer) and year (its
-- Year columns snap the selection out to whole calendar years, §4.3). Everything
-- else is here because this is a SHARED dimension: the alternative is that the
-- next report wanting a week number or a day name either amends this model or
-- denormalises the value onto its own fact, which is what
-- mart__schedule_difference_report already did (it stores week and day_of_call
-- itself). Building the calendar out once is cheap — it is a generated spine, not
-- a join — and keeps those columns defined in one place instead of per fact.
-- Relate any dated fact here; do not trim this to one report's needs.
--
-- WHY IT RUNS TO YEAR END AND NOT TO THE HORIZON — and why it does NOT reuse
-- int__report_calendar, which has the same 2000-01-01 anchor and generator idiom.
-- That model stops at the horizon on purpose: it is a mechanism for expanding
-- recurrences by cross join, and every date on it becomes fact rows. A BI date
-- dimension has the opposite requirement — Power BI needs contiguous dates
-- covering COMPLETE years or time intelligence silently misbehaves, and the
-- continuity report's Year measures snap the user's selection out to whole
-- calendar years (§4.3), which cannot be represented if a year stops mid-flight.
-- The two contracts genuinely conflict, so they stay separate rather than one
-- growing an argument that would break the other's caller.
--
-- The year is the HORIZON's, not today's: the furthest-looking fact
-- (mart__workforce_capacity) carries dates up to the projection horizon, and from
-- 1 October that is next year. Stopping at the current year would leave those
-- rows with no date to relate to. It stops at that
-- year's end rather than at the generator's limit so the slicer holds no years of
-- empty future dates. This is a full table rebuild on every run, so the range
-- rolls forward on its own — the first build once the horizon crosses 1 Jan picks
-- up the new year with no intervention.
--
-- NO company_id / location_id, and therefore NO row-level filter on
-- report__dim_date: a calendar is not customer data. See the note there.
--
-- NO relative-date flags (is_current_year / is_today / ...) on purpose. They would
-- be frozen as of the last build and read as live, so a stale table would quietly
-- mislabel "today". Compute anything relative in DAX, where it evaluates at query
-- time.
--
-- Sort columns matter in Power BI: set month_name to sort by month_number,
-- month_year_label by year_month, iso_week_label by iso_year_week, and day_name by
-- day_of_week_number, otherwise they order alphabetically ("April, August,
-- December, ...").

with spine as (
    select dateadd(day, seq4(), '2000-01-01'::date) as calendar_date
    from table(generator(rowcount => 20000))  -- ~year 2054; capped at year end below
),

bounded as (
    select calendar_date
    from spine
    where calendar_date <= date_from_parts(year({{ projection_horizon() }}), 12, 31)
),

final as (
    select
        calendar_date,
        year(calendar_date) as year,
        quarter(calendar_date) as quarter_number,
        'Q' || quarter(calendar_date)::varchar as quarter_name,
        month(calendar_date) as month_number,
        -- monthname() gives the 3-letter form; 'MMMM' the full name.
        to_varchar(calendar_date, 'MMMM') as month_name,
        monthname(calendar_date) as month_short,
        -- Integer YYYYMM: the sort key behind month_year_label.
        year(calendar_date) * 100 + month(calendar_date) as year_month,
        monthname(calendar_date) || ' ' || year(calendar_date)::varchar as month_year_label,
        day(calendar_date) as day_of_month,
        dayofyear(calendar_date) as day_of_year,
        -- ISO week numbering: 1 = Monday, and iso_year is the year the ISO week
        -- belongs to, which differs from `year` in the last/first days of a year.
        -- Pair iso_week with iso_year, never with `year`, or week 1 of January
        -- can land in the previous year's bucket.
        weekiso(calendar_date) as iso_week,
        yearofweekiso(calendar_date) as iso_year,
        -- Integer YYYYWW plus its label — the week equivalent of year_month /
        -- month_year_label, and the reason both exist: without the integer key a
        -- week label sorts as text, putting 2027-W01 before 2026-W52.
        yearofweekiso(calendar_date) * 100 + weekiso(calendar_date) as iso_year_week,
        yearofweekiso(calendar_date)::varchar
        || '-W' || lpad(weekiso(calendar_date)::varchar, 2, '0') as iso_week_label,
        dayofweekiso(calendar_date) as day_of_week_number,
        case dayofweekiso(calendar_date)
            when 1 then 'Monday'
            when 2 then 'Tuesday'
            when 3 then 'Wednesday'
            when 4 then 'Thursday'
            when 5 then 'Friday'
            when 6 then 'Saturday'
            else 'Sunday'
        end as day_name,
        dayname(calendar_date) as day_short,
        dayofweekiso(calendar_date) >= 6 as is_weekend,
        date_trunc('month', calendar_date)::date as start_of_month,
        last_day(calendar_date) as end_of_month,
        date_trunc('year', calendar_date)::date as start_of_year,
        last_day(calendar_date, 'year') as end_of_year
    from bounded
)

select * from final
