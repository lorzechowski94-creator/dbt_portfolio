{#
    Emits a UNION ALL over every care in the CURRENT target's account, each branch
    stamped with its care token in a column named `source` — the source schema the
    row came from. This is how an `intermediate` model reads the whole account
    instead of one care.

        with client as (
            {{ union_cares('client', 'staging') }}
        )

    WHERE THE SEAM IS. raw_access and staging are built ONCE PER CARE, each into
    that care's own schema. intermediate, marts and report are built ONCE PER
    ACCOUNT, and the care rides along as a COLUMN. This macro is the join between
    the two halves, so it only accepts the per-care layers — asking it to union an
    intermediate is a category error and raises.

    RAW IS ACCEPTED TOO, for the row-access map: models/access/meta_customer_role_map
    is one table per account built from every care's `location`, and it sits UNDER
    raw_access and staging — their customer_access_filter reads it — so unioning
    either would be a cycle. ANALYTICS_RAW is loaded outside dbt and is the only
    per-care layer below the map. For raw, `bare` is the PHYSICAL table name (a
    source's `identifier`, e.g. CLIENTDETAILS), not the snake_case source name.

    COLUMNS ARE ALIGNED BY NAME, NOT BY POSITION, and that is not defensive
    programming — it is a correction. The first version selected `s.*`, on the
    assumption models/sources.yml states: every care is the same MySQL layout
    ingested the same way. THE CARES HAVE DRIFTED. The first real run against R2
    prod failed with

        invalid number of result columns for set operator input branches,
        expected 93, got 94 in branch 2                       (carer)
        expected 119, got 118 in branch 2                     (client)
        inconsistent data type ... expected NUMBER(38,0), got TIMESTAMP_NTZ(9)
                                                              (jobtype)

    — a column count that differs between care2/3/5, and a column ORDER that puts a
    number under a timestamp. `s.*` makes both fatal, and would make a subtler
    version WORSE than fatal: two tables with the same column count but a different
    order union cleanly and silently interleave the values.

    So each branch is emitted as an explicit list, in one order, keyed on the column
    NAME. A column missing from a care becomes a typed NULL for that care, which is
    the honest answer — that care genuinely does not record it. Nothing is cast
    otherwise: where the same name carries different types, Snowflake's own
    coercion rules apply, and a genuinely incompatible pair now fails naming the
    column instead of a positional accident.

    THE COLUMN LIST IS READ FROM THE WAREHOUSE, which is why the whole thing is
    inside `if execute`. During parsing there is no connection (CI's dbt_validate
    has no warehouse and no token), so the fallback emits `s.*` — structurally
    valid, never executed, enough for ref() extraction and `dbt parse` to stay
    offline. The real list is built when the model runs.

    IT COSTS ONE `describe table` PER CALL SITE PER CARE, not one per relation: dbt
    caches relations but not their columns, and this macro is called 42 times
    across models/ — `timesheet` five times, `carer` and `area` four each. A 3-care
    R2 run therefore issues ~126 serial metadata round-trips, a few seconds in
    total. Acceptable for a daily build; if it ever stops being so, the fix is to
    resolve the column list once per (relation, run) rather than to go back to
    `s.*`.

    WHY RAW RELATION NAMES AND NOT ref(). One dbt run is ONE care ($DBT_CARE), so
    inside a care1 run `ref('stg__client')` resolves to care1's relation and
    nothing else — there is no expression for "the same model, built by another
    care's run". The other cares' relations therefore have to be addressed by name.

    WHAT THAT COSTS, and how it is paid for. dbt does not see these as
    dependencies, so it cannot order an intermediate after the per-care runs that
    fill it. .gitlab-ci.yml does that instead, in two phases: every care builds
    access + raw_access + staging (`--exclude tag:shared`), then ONE run builds
    intermediate and everything above it (`--select tag:shared`). Getting that
    order wrong does not error, it just reads a care that has not refreshed yet —
    so the phases live in one job, not two, and the shared phase runs only after
    the per-care loop completes.

    WHAT IT DOES NOT COST. `ref()` still works from intermediate upwards, so the
    intermediate -> mart -> report half of the DAG is fully known to dbt and
    ordered by it. Only the staging -> intermediate edge is invisible.

    AFTER THIS MACRO, EVERY JOIN NEEDS THE CARE. Client, carer, job type, area and
    location ids are all allocated per care and collide across them, so
    `a.id = b.id` alone silently fans each row out against the other cares' rows.
    Nothing errors; the numbers just come out multiplied. Every join downstream of
    a union_cares() call carries `and a.source = b.source`.

    WHY `source` AND NOT `care`. Until 2026-10 the column was called `care`. It
    was renamed when the reader roles and the Power BI roles started scoping by it
    (models/access/_access__models.yml): the reports already labelled it "Source",
    and the token IS the source schema's name. The key and topology macros
    followed (care_key -> source_key, care_topology -> source_topology); this
    macro, $DBT_CARE and the care tokens themselves keep their names.

    A MISSING RELATION STILL FAILS, BUT NOT WHERE YOU WOULD EXPECT. Reading its
    columns does NOT raise: dbt-snowflake's get_columns_in_relation catches
    "does not exist or not authorized" and returns an empty list. So that care
    contributes no names, its branch is emitted as nothing but typed NULLs, and the
    build only falls over on the FROM clause underneath it. The error names the
    missing object either way, which is what matters — but do not read the empty
    column list as proof a relation exists, and do not make the FROM tolerant
    without replacing that check: an all-NULL branch would then be a care silently
    missing from every report, which is the failure this layer is built to avoid.
#}
{% macro union_cares(bare, layer) %}
    {%- set databases = {
        'raw': 'ANALYTICS_RAW',
        'raw_access': 'ANALYTICS_RAW_ACCESS',
        'staging': 'ANALYTICS_STAGING'
    } -%}
    {%- if layer not in databases -%}
        {%- do exceptions.raise_compiler_error(
            "union_cares('" ~ bare ~ "', '" ~ layer ~ "'): unions are only defined over the"
            ~ " per-care layers (" ~ databases.keys() | join(' / ') ~ "). Everything above"
            ~ " them is already account-wide and carries the care as a column, `source`."
        ) -%}
    {%- endif -%}

    {#- The SCHEMA goes through generate_schema_name, exactly as it would for a
        ref(): the local sandbox target prefixes every schema (DBT_DEV_care1), and a
        hard-coded `care1` here would silently read the SHARED relation from a
        developer's run instead of their own. The NAME needs no such treatment —
        these layers get one schema per care, so the relation keeps its bare
        model name in every care (macros/generate_alias_name.sql).
        RAW IS THE EXCEPTION: dbt does not build it, so there is no prefix to
        apply — its schema is the care token upper-cased, exactly as
        models/sources.yml resolves it, and every target reads the same raw. -#}
    {%- set branches = [] -%}
    {%- for care in sources_in_account() -%}
        {%- do branches.append({
            'care': care,
            'relation': api.Relation.create(
                database=databases[layer],
                schema=(care | upper) if layer == 'raw' else generate_schema_name(care, none),
                identifier=bare
            )
        }) -%}
    {%- endfor -%}

    {#- Superset of column names across the cares, in first-seen order, with the
        type of the care that introduced each one (used only to type the NULLs). -#}
    {%- set names = [] -%}
    {%- set types = {} -%}
    {%- set present = {} -%}
    {%- if execute -%}
        {%- for b in branches -%}
            {%- set cols = adapter.get_columns_in_relation(b['relation']) -%}
            {%- do present.update({b['care']: cols | map(attribute='name') | map('upper') | list}) -%}
            {%- for c in cols -%}
                {%- if c.name | upper not in types -%}
                    {%- do names.append(c.name | upper) -%}
                    {%- do types.update({c.name | upper: c.data_type}) -%}
                {%- endif -%}
            {%- endfor -%}
            {#- The tenant column is added under a fixed name, so a relation that
                already has one of that name would put two SOURCE columns in the
                branch, and every reference downstream would fail as "ambiguous".
                No relation had one when the column was named (checked on DEV); the
                cares drift, so say so plainly if one ever does. -#}
            {%- if 'SOURCE' in present[b['care']] -%}
                {%- do exceptions.raise_compiler_error(
                    "union_cares('" ~ bare ~ "', '" ~ layer ~ "'): " ~ b['relation']
                    ~ " has its own SOURCE column, which collides with the tenant column"
                    ~ " this macro adds. Rename or exclude it in that layer first."
                ) -%}
            {%- endif -%}
        {%- endfor -%}
    {%- endif -%}

    {#- Identifiers are QUOTED. The source columns are whatever the MySQL app
        called them, and this is a scheduling system — `order`, `start`, `set`,
        `values` and `row` are all reserved in Snowflake and all plausible column
        names. `s.*` never had to name them, an explicit list does. The names come
        back upper-case from the warehouse, so quoting them changes nothing for
        callers: a downstream `clientid` still resolves to "CLIENTID". -#}
    {%- for b in branches %}
select
    '{{ b['care'] }}' as source,
    {%- if names %}
    {%- for col in names %}
    {% if col in present[b['care']] %}s.{{ adapter.quote(col) }}{% else %}cast(null as {{ types[col] }}){% endif %} as {{ adapter.quote(col) }}{{ "," if not loop.last }}
    {%- endfor %}
    {%- else %}
    s.*
    {%- endif %}
from {{ b['relation'] }} as s
{% if not loop.last %}union all
{% endif %}
    {%- endfor -%}
{% endmacro %}
