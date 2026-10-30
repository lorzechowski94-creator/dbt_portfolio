{#
    The last date the schedule expansion reaches: the last day of the third whole
    month after the current one (run in July -> 31 October).

    TWO HORIZONS, because two kinds of report look forward. The hours reports
    (Client Hours, Carer Hours, Schedule Difference) show the agreed 60 days,
    macros/report_horizon.sql. The Workforce Capacity outlook shows the next three
    calendar months, so it needs the roster rules, contracts and assigned hours
    expanded to the end of the third month: between 92 and 122 days ahead,
    depending on the day of the month the build runs.

    The SHARED expansion models run to this horizon: int__report_calendar,
    int__recurr_occurrences and int__client_allocated_hours. Every hours-report
    model that reads them caps itself at report_horizon() — the three scheduled
    pillars (int__carer_scheduled_hours, int__client_scheduled_hours,
    int__schedule_difference) and the allocated pillar of mart__client_hours_report
    — so those reports keep their 60 days. A new consumer of the expansion models
    has to pick one of the two bounds on purpose: read unbounded, it gets this one.

    It is always the later of the two (three whole months is at least 92 days), so
    a cap at report_horizon() never asks for a date the expansion does not have.

    Everything macros/report_horizon.sql says about forecast rows applies here
    unchanged: a forward row projects the rules as they stand at build time, so the
    incremental models on this path replace their window rather than merge it, and
    shrinking this horizon needs a --full-refresh of them.
#}
{% macro projection_horizon() -%}
    last_day(dateadd(month, 3, current_date()))
{%- endmacro %}
