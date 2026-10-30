{#
    Format a minutes value as an "HH:MM" string, replicating the report's
    convertToHoursMins(): returns NULL when the value is under 1 minute.

    Example: 90 -> '01:30'
#}
{% macro minutes_to_hhmm(minutes) -%}
    case
        when {{ minutes }} >= 1
        then lpad(floor({{ minutes }} / 60)::string, 2, '0')
             || ':' ||
             lpad(mod(floor({{ minutes }}), 60)::string, 2, '0')
    end
{%- endmacro %}
