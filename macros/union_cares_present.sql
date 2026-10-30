{#
    union_cares() for a table that has NOT reached every care yet: a UNION ALL over
    only the cares whose relation exists, with the columns the caller names.

        with carer_pay as (
            {{ union_cares_present('cmcarerpay', 'raw_access', {
                'ID': 'number', 'NO': 'number', 'START': 'time', 'END': 'time',
                'SAME_RATE_OVERNIGHT': 'number'
            }, optional=['SAME_RATE_OVERNIGHT']) }}
        )

    WHY IT EXISTS. The pay and billing rate cards (cmCarerPay, cmClientBilling and
    their pick / scale / cancelled tables) are being ingested care by care. A
    union_cares() over them fails the whole model in every account where one care
    still lacks the table — and staging over them would be worse: the per-care
    staging build GATES the shared phase (.gitlab-ci.yml), so one missing table
    would hold back every mart in the account. This macro reads raw_access directly
    (no staging model, so nothing in the gating step changes) and leaves a care
    without the table out of the union.

    THAT IS EXACTLY WHAT union_cares() REFUSES TO DO, and the refusal still stands
    for every other table: a care silently missing from a union is a tenant
    silently missing from a report. It is acceptable here only because the caller
    makes the gap visible on the row — cares_present_sql() below turns the same
    existence check into a predicate, and int__forecast_finance uses it to return
    NULL pay / billing naming the table that is not loaded, never a figure computed
    without it. A new caller has to do the same, or use union_cares().

    THE COLUMNS ARE NAMED, NOT DISCOVERED: {NAME: snowflake type}, in output order,
    names as Snowflake spells them (upper case). The types are used only to fill a
    column with a typed NULL: an `optional` column a care's relation lacks, or every
    column when NO care has the table yet — then the macro emits an empty, correctly
    typed relation (`limit 0`), so the models above compile and build in every
    account from day one and return rows the day the first care's view appears.
    A care whose relation exists but lacks a column NOT listed as optional fails
    compilation, naming both: union_cares() fills a drifted column with NULL, but
    these columns are the calculation's inputs, and a NULL rate would not fail — it
    would quietly price a visit at nothing. List as optional only what the PHP reads
    off a `SELECT *` row (a missing key is NULL to it as well), never a column it
    filters on.

    Identifiers are quoted, as in union_cares(): START, END, DAY and NO are column
    names on these tables, and START is reserved in Snowflake.

    WHAT IT DOES NOT SEE. The existence check runs when the model compiles. In the
    PROD deploys every care's raw_access views are built before the shared phase, so
    a view created by the same deploy is seen; the DEV refresh builds them after its
    shared phase, so there a new view joins at the next run. During parsing there is
    no connection, so the macro emits the empty relation, enough for `dbt parse` to
    stay offline.

    IT COSTS ONE `show objects` PER CARE PER CALL (cares_present() below), issued
    while dbt compiles: dbt caches only the schemas the run builds into, and these
    are other cares' raw_access schemas.
#}
{% macro union_cares_present(bare, layer, columns, optional=[]) %}
    {%- set optional_names = optional | map('upper') | list -%}
    {%- set branches = cares_present(bare, layer) -%}
    {%- set present = {} -%}
    {%- for b in branches -%}
        {%- set have = adapter.get_columns_in_relation(b['relation']) | map(attribute='name') | map('upper') | list -%}
        {%- do present.update({b['care']: have}) -%}
        {%- for name in columns if name | upper not in have and name | upper not in optional_names -%}
            {%- do exceptions.raise_compiler_error(
                "union_cares_present('" ~ bare ~ "', '" ~ layer ~ "'): " ~ b['relation']
                ~ " has no column " ~ name ~ ". It is not listed as optional: a NULL in its"
                ~ " place would not fail, it would quietly change the result."
            ) -%}
        {%- endfor -%}
    {%- endfor -%}
    {%- if branches -%}
        {%- for b in branches %}
select
    '{{ b['care'] }}' as source,
    {%- for name, type in columns.items() %}
    {% if name | upper in present[b['care']] %}s."{{ name | upper }}"{% else %}cast(null as {{ type }}){% endif %} as "{{ name | upper }}"{{ "," if not loop.last }}
    {%- endfor %}
from {{ b['relation'] }} as s
{% if not loop.last %}union all
{% endif %}
        {%- endfor -%}
    {%- else %}
select
    cast(null as varchar) as source,
    {%- for name, type in columns.items() %}
    cast(null as {{ type }}) as "{{ name | upper }}"{{ "," if not loop.last }}
    {%- endfor %}
limit 0
    {%- endif -%}
{% endmacro %}


{#
    The same existence check as a SQL predicate on a `source` column:
    `source in ('care2', 'care3')`, or `false` when no care has the relation.
    The caller's way of saying "this tenant's figures are missing, not zero".
#}
{% macro cares_present_sql(bare, layer, source_col='source') %}
    {%- set cares = cares_present(bare, layer) | map(attribute='care') | list -%}
    {%- if cares -%}
        {{ source_col }} in ('{{ cares | join("', '") }}')
    {%- else -%}
        false
    {%- endif -%}
{% endmacro %}


{#
    The cares in the current account whose `bare` relation exists in `layer`, as
    [{care, relation}], in sources_in_account() order. Empty while parsing.
    Only the per-care layers dbt builds: raw itself is read through union_cares().
#}
{% macro cares_present(bare, layer) %}
    {%- set databases = {
        'raw_access': 'ANALYTICS_RAW_ACCESS',
        'staging': 'ANALYTICS_STAGING'
    } -%}
    {%- if layer not in databases -%}
        {%- do exceptions.raise_compiler_error(
            "cares_present('" ~ bare ~ "', '" ~ layer ~ "'): only the per-care layers dbt"
            ~ " builds (" ~ databases.keys() | join(' / ') ~ ")."
        ) -%}
    {%- endif -%}
    {%- set found = [] -%}
    {%- if execute -%}
        {%- for care in sources_in_account() -%}
            {%- set relation = adapter.get_relation(
                database=databases[layer],
                schema=generate_schema_name(care, none),
                identifier=bare
            ) -%}
            {%- if relation is not none -%}
                {%- do found.append({'care': care, 'relation': relation}) -%}
            {%- endif -%}
        {%- endfor -%}
    {%- endif -%}
    {{ return(found) }}
{% endmacro %}
