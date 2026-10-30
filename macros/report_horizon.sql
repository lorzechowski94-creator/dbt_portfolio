{#
    The last date the hours and schedule reports cover: today + 60 days.

    Client Hours, Carer Hours and Schedule Difference look forward as well as back.
    The PHP versions take any future date range and expand the schedule templates
    on demand; these facts are materialised, so they need a fixed end, and 60 days
    is the agreed forward look. Every bound on their path that used to be
    current_date() calls this instead, which makes this the one place to move it.

    The expansion models UNDER these reports run further, to projection_horizon()
    (macros/projection_horizon.sql), because the Workforce Capacity outlook needs
    three whole months. Each hours-report model that reads them caps itself back to
    this date, so the three reports still end at today + 60.

    A FORWARD ROW IS A FORECAST, SO THE WINDOW IS REPLACED, NOT MERGED.
    A row dated after today projects the templates as they stand at build time, and
    they keep changing: a template is deleted, shortened, cancelled, or moved to
    another carer or job type. A merge only inserts and updates, so the superseded
    projection would stay under its old key and, once its date passed, sit in the
    history as hours nobody scheduled. Every incremental model on this path
    therefore uses delete+insert keyed on its DATE column: dbt deletes every date
    present in the batch and inserts the batch, in one transaction, so each date in
    the window comes out exactly as a full refresh would build it. The one gap: a
    date for which the new batch holds no rows at all keeps its old ones, which
    needs every care's activity on that date to vanish.

    THE LOOKBACK ANCHORS ON least(max(date), today), NOT max(date). With forward
    rows loaded, max(date) is the horizon, and "N days before max" would stop
    re-reading the past altogether. least() keeps the backward window at N days
    before today, and after a gap in the runs it still reaches back from the last
    loaded date.

    Shrinking the horizon needs a --full-refresh of those models: dates past the
    new horizon are in no batch, so nothing deletes them.

    Task Review looks forward too: int__task_review expands the task schedules
    over the same calendar and caps them at this date, and mart__task_review_report
    replaces its window by date as above.
#}
{% macro report_horizon() -%}
    dateadd(day, 60, current_date())
{%- endmacro %}
