{#
    The REPLACE clause that gives a raw_access view back the column types the source
    had in MySQL. exclude_internal() calls it with the columns it has already read,
    so it costs no extra `describe table`, and no model has to change:

        select s.* exclude (...) replace (cast("ID" as number(10,0)) as "ID", ...)

    WHY. Customers load these views into SQL Server with SSIS packages built against
    MySQL (care2's first). Airbyte lands every integer as NUMBER(38,0), every
    varchar(n) as VARCHAR (16 MB) and every decimal(p,s) as FLOAT, so the packages
    see DT_NUMERIC(38,0), DT_TEXT and DT_R8 and either fail validation or need a
    Data Conversion step per column. REPLACE casts in place: the column keeps its
    name AND its position.

    WHAT EACH CAST GIVES SSIS (through the Snowflake ODBC driver):
      varchar(n) / char(n) -> varchar(n)   DT_STR(n) instead of DT_TEXT.
      decimal(p,s)         -> number(p,s)  an exact decimal again. Lossless: none of
                                           these has more than 15 digits, which a
                                           double holds exactly.
      tinyint .. bigint    -> number(p,0)  DT_NUMERIC(p,0) — still NOT int. The
                                           driver reports every NUMBER as a decimal,
                                           so the customer maps it to int on their
                                           side.
    Left as Airbyte delivers them: timestamp (TIMESTAMP_TZ, which SSIS reads as a
    plain timestamp), tinyint(1) (Airbyte's BOOLEAN, read as DT_BOOL), text, blob,
    json, and TIME — a value of 24:00 or more is NULLed at load, and no cast here
    brings it back.

    EVERY SOURCE, ONE LIST. The type list (macros/mysql_column_types.sql) is care2's
    MySQL schema, applied to every source: they all run the same application. The
    rc* tables, preferredCarers, cmCompanyBillingPick and contactType, which care2
    does not have, are inferred instead (that file's header says how). The sources
    have drifted, though (macros/union_cares.sql). A column a source lacks, or gets
    from Airbyte as another class, is skipped (below), so that source keeps Airbyte's
    type for it. A column a source declares WIDER than care2 cannot be seen from
    here at all: its values fit today, and the first longer one fails the cast.

    A VALUE THAT DOES NOT FIT FAILS THE QUERY. Snowflake raises "String ... is too
    long and would be truncated" or "Numeric value out of range" rather than
    truncating, and staging selects * from these views — so it breaks our own build,
    not just the customer's package. MySQL enforces the same limits at source, so
    only a schema the list has not caught up with can cause it: a widened varchar or
    an int turned bigint in care2, or a source that declares the column wider than
    care2 does. Fix the list, never the cast: widen that column's type, or take the
    column out — macros/mysql_column_types.sql already does one and two of those.

    SKIPPED, NOT AN ERROR: a column the list does not name; a listed column the
    relation lacks (REPLACE, like EXCLUDE, fails the whole view on a missing name);
    one whose class is not what the list expects (a varchar target on a non-string,
    a number target on Airbyte's BOOLEAN); and one exclude_internal() drops — a
    column cannot be both excluded and replaced.

    TYPES ABOVE STAGING NARROW TOO. union_cares() leaves type differences between
    cares to Snowflake's coercion, and every pair here is compatible (varchar(n)
    with varchar, number(p,s) with NUMBER(38,0) or FLOAT), so a column narrows in
    intermediate and marts once every source of the account carries it narrow. For
    the incremental models (on_schema_change='sync_all_columns') a narrower varchar
    is no change, but NUMBER(10,0) against the table's NUMBER(38,0) is: dbt answers
    it with ALTER ... SET DATA TYPE. So the first deploy of this to an account runs
    with full_refresh=true (.gitlab-ci.yml), which rebuilds those tables instead.
#}

{% macro mysql_types_replace(table, columns, skip) -%}
{%- set casts = [] -%}
{%- set wanted = {} -%}
{%- for mysql_type, names in mysql_column_types().get(table | upper, {}).items() -%}
    {%- for name in names -%}
        {%- do wanted.update({name: mysql_type}) -%}
    {%- endfor -%}
{%- endfor -%}
{%- for column in columns -%}
    {%- set name = column.name | upper -%}
    {%- set mysql_type = wanted.get(name) -%}
    {%- if mysql_type and name not in skip
        and (column.is_string() if mysql_type.startswith('varchar') else column.is_number()) -%}
        {%- do casts.append([name, mysql_type]) -%}
    {%- endif -%}
{%- endfor -%}
{%- if casts %}
replace (
{%- for name, mysql_type in casts %}
    cast({{ adapter.quote(name) }} as {{ mysql_type }}) as {{ adapter.quote(name) }}{{ "," if not loop.last }}
{%- endfor %}
)
{%- endif -%}
{%- endmacro %}
