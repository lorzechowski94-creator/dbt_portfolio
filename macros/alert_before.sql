{#
    cmQualificationsType.alertBefore — the alert window of an HR file type — is free
    text typed in the app: a count and a unit, '4 week', '1 month', '3 month', and
    sometimes no space ('1month'). It is NOT a number of days. Until 2026-10-09 it was
    read with try_to_number(), which returns null for every one of those values, so
    no file of a type with a window ever flagged as expiring.

    alert_before_value / alert_before_unit split it into 4 and 'week'. A value of any
    other shape gives null for both, which reads as "no alert window" downstream; the
    test assert_alert_before_parsed warns on such values, so a new spelling surfaces
    instead of silently switching the alert off for that type.

    alert_window_start turns the pair into the date the alert opens: the expiry date
    minus the interval, in calendar units, the way PHP's strtotime() reads the same
    text — one month before 15-03 is 15-02, not 30 days earlier. At a month end the
    two differ: Snowflake clamps (31-03 minus one month is 28-02), strtotime
    overflows to 03-03, so a month-based window can open up to three days earlier
    here.

        {{ alert_before_value('t.alertbefore') }} as alert_before_value,
        {{ alert_before_unit('t.alertbefore') }} as alert_before_unit,
        ...
        {{ alert_window_start('q.expiredate', 't.alert_before_value', 't.alert_before_unit') }}
#}
{% macro alert_before_pattern() -%}
    '^([0-9]+) *(day|week|month|year)s?$'
{%- endmacro %}

{% macro alert_before_value(column) -%}
    try_to_number(
        regexp_substr(trim({{ column }}::varchar), {{ alert_before_pattern() }}, 1, 1, 'ie', 1)
    )
{%- endmacro %}

{% macro alert_before_unit(column) -%}
    lower(regexp_substr(trim({{ column }}::varchar), {{ alert_before_pattern() }}, 1, 1, 'ie', 2))
{%- endmacro %}

{% macro alert_window_start(date_col, value_col, unit_col) -%}
    case {{ unit_col }}
        when 'day' then dateadd(day, -{{ value_col }}, {{ date_col }})
        when 'week' then dateadd(week, -{{ value_col }}, {{ date_col }})
        when 'month' then dateadd(month, -{{ value_col }}, {{ date_col }})
        when 'year' then dateadd(year, -{{ value_col }}, {{ date_col }})
    end
{%- endmacro %}
