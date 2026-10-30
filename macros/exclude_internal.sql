{#
    The EXCLUDE clause that keeps sync metadata and credentials out of a raw_access
    passthrough. Takes the SOURCE NAME as models/sources.yml spells it, not the
    physical table:

        select s.* {{ exclude_internal('carer') }}
        from {{ source('raw_app', 'carer') }} as s

    TWO CLASSES OF COLUMN ARE DROPPED, for two different reasons.

    1. AIRBYTE SYNC METADATA — _AIRBYTE_RAW_ID, _AIRBYTE_EXTRACTED_AT,
       _AIRBYTE_META, _AIRBYTE_GENERATION_ID. Written by the destination connector
       on top of whatever the MySQL source had. They describe the SYNC, not the
       care's data, nothing under models/ reads them, and plain `select s.*` carried
       all four into every raw_access view, into staging, and on into anything above
       that selected `*`.

    2. CREDENTIALS — argon2id (and older MD5) password hashes, plus the app's PIN
       fields. They sit on six tables: carer (PASSWORD, PASSWORDEXPIRES, PINCODE),
       client (PASSWORD), company (PASSWORD, ADMINPIN, PRIVATENOTEPIN,
       PRIVATENOTEPINCARERAPP, SCHEDULEPASTPASSWORD), location (PASSWORDASSIGNHRS,
       PASSWORDDELETETIMESHEET, PASSWORDEDITJOBTYPE, PINCODE, PRIVATENOTEPIN),
       cm_tab_carer (PIN) and cm_tab_client (PIN). raw_access is a SECURE view that
       a customer reader role can be granted, so a hash reaching it is a hash one
       `select *` away from leaving the warehouse.

    THIS DOES NOT REMOVE THEM FROM ANALYTICS_RAW. The hashes are still ingested and
    still sit in the raw database — this closes the dbt-shaped path to them, nothing
    more. Anyone holding SELECT on ANALYTICS_RAW still reads them. Stopping the
    ingestion (Airbyte column selection) or a Snowflake masking policy on the raw
    tables is the actual fix; this is the half that lives in the repo.

    THE LIST IS RESOLVED AGAINST THE WAREHOUSE, unlike an `exclude` written by hand,
    and that is not defensive dressing — it is the only form that works. Snowflake's
    EXCLUDE takes column NAMES and fails the whole view with `invalid identifier` if
    one is absent, while these columns exist on only SIX of the source tables and
    the CARES HAVE DRIFTED besides (macros/union_cares.sql's header has the receipts:
    carer is 93 columns in one care and 94 in another). A single hard-coded list
    would therefore break every other model outright, and a per-model list would
    break the moment a care differs. Reading the real columns and intersecting makes
    a table that lacks the column a no-op instead of an error, and makes a care that
    HAS one its siblings lack still get it dropped.

    MATCHED BY PREFIX, SUBSTRING AND EXACT NAME, in that order of looseness:
      _AIRBYTE_*   prefix    — catches a fifth metadata column from a future
                               connector version without an edit here.
      *PASSWORD*   substring — catches PASSWORDEXPIRES, SCHEDULEPASTPASSWORD and any
                               new PASSWORD* setting. No false positive is plausible.
      PIN_NAMES    exact     — `pin` as a SUBSTRING would eat SHIPPING, MAPPING,
                               PINNED and anything else with those three letters, so
                               the PIN family is enumerated. A new one has to be
                               added by hand; a warehouse-wide sweep for
                               password/pin/secret/credential names is the way to
                               find it.

    TWO OF THESE ARE PROBABLY SETTINGS, NOT SECRETS — PASSWORDEXPIRES is a DATE and
    SCHEDULEPASTPASSWORD a NUMBER, i.e. an expiry date and a feature flag rather than
    a credential. They are dropped anyway because *PASSWORD* is deliberately blunt.
    If either is ever wanted in a report, exempt it here rather than narrowing the
    pattern.

    AFTER THE EXCLUDE IT EMITS THE REPLACE that gives the views their MySQL column
    types back — macros/mysql_types.sql, which has the why. It lives here
    only because this macro already holds the column list and sits in every
    raw_access model; it adds no query and no model edit.

    IT COSTS ONE `describe table` PER MODEL PER RUN — one per raw_access model in
    every care, issued while dbt compiles, so the thread pool absorbs most of it.
    dbt caches relations but not their columns (same constraint union_cares works
    around), so there is no way to resolve this once for the whole run.

    THE FALLBACK IS AN EMPTY CLAUSE. During parsing there is no connection (CI's
    dbt_validate has no warehouse and no token), so `if execute` is false and the
    macro emits nothing at all, neither EXCLUDE nor REPLACE — `select s.*`,
    structurally valid, never executed, enough for `dbt parse` to stay offline. sqlfluff never reaches this code: .sqlfluff
    stubs the macro, because its jinja templater cannot give a file macro `adapter`,
    `execute` or `source()`.
#}
{% macro exclude_internal(bare) -%}
{%- set pin_names = [
    'ADMINPIN',
    'PIN',
    'PINCODE',
    'PRIVATENOTEPIN',
    'PRIVATENOTEPINCARERAPP'
] -%}
{%- set drop = [] -%}
{%- set columns = [] -%}
{%- if execute -%}
    {%- set columns = adapter.get_columns_in_relation(source('raw_app', bare)) -%}
    {%- for column in columns -%}
        {%- set name = column.name | upper -%}
        {%- if name.startswith('_AIRBYTE_') or 'PASSWORD' in name or name in pin_names -%}
            {%- do drop.append(name) -%}
        {%- endif -%}
    {%- endfor -%}
{%- endif -%}
{%- if drop -%}
exclude (
{%- for column in drop %}
    {{ adapter.quote(column) }}{{ "," if not loop.last }}
{%- endfor %}
)
{%- endif -%}
{{ mysql_types_replace(source('raw_app', bare).identifier, columns, drop) }}
{%- endmacro %}
