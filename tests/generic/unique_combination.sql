{#
    Generic test: the listed columns are unique TOGETHER. The model-grain test for
    every relation above the union layer.

    WHY IT EXISTS. Every mart's grain now opens with `source`, because client ids,
    carer ids, job type ids and group ids are allocated per care (separate MySQL
    databases) and collide across them. A plain `unique` on the bare id was correct
    while each care had its own relation and is FALSE now that the marts are
    account-wide — it would fail on the second care for a dimension, and on a fact
    it would never have been there to catch anything.

    WHAT IT ACTUALLY GUARDS. Not the source data — the JOINS. A join above the
    union that forgets `and a.source = b.source` fans every row out against the other
    cares' matching ids: no error, no failed build, just silently multiplied
    hours, visits and counts. Duplicated grain rows are the first place that
    shows, which is why this sits on every mart grain and not only on the
    dimensions.

    This is dbt_utils.unique_combination_of_columns in miniature. The project
    carries no packages.yml and this is the only borrowed test it needs, so it is
    defined here rather than pulling in a dependency (and its `dbt deps` step in
    CI) for one macro.

    Usage — model level, not column level:
        tests:
          - unique_combination:
              combination_of_columns: [source, client_id, service_date, job_type_id]
#}
{% test unique_combination(model, combination_of_columns) %}

{%- set columns = combination_of_columns | join(', ') -%}
{#- group by ordinal: the columns may be expressions, and ordinals cannot drift
    out of sync with the select list above them. -#}
{%- set ordinals = range(1, combination_of_columns | length + 1) | join(', ') -%}

select
    {{ columns }},
    count(*) as rows_at_this_grain
from {{ model }}
group by {{ ordinals }}
having count(*) > 1

{% endtest %}
