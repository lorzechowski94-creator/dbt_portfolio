{#
    Convert a TIME value (interpreted as a duration, e.g. call length) into
    decimal hours. Snowflake TIME cannot be summed directly, so metrics that
    aggregate durations must go through this first.

    Example: 01:30:00 -> 1.5
#}
{% macro time_to_hours(column) -%}
    (
        date_part('hour', {{ column }})
        + date_part('minute', {{ column }}) / 60.0
        + date_part('second', {{ column }}) / 3600.0
    )
{%- endmacro %}
