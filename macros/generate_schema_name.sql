{#
    Environment-aware schema naming. Databases are shared across environments
    (ANALYTICS_RAW_ACCESS, ANALYTICS_INTERMEDIATE, ANALYTICS_MART, ANALYTICS_STAGING);
    isolation happens at the schema level via a per-target prefix.

    The prefix is applied ONLY to the local terminal sandbox, identified by its
    target schema DBT_DEV -> DBT_DEV_care1, DBT_DEV_care_management, ...
    Every other target uses CLEAN schemas (care1, care_management, ...) — e.g. the
    scheduled build (schema DEV). So the DBT_DEV_ prefix only ever comes from a
    terminal run; the scheduled build writes clean schemas.

    Applies to models, seeds and snapshots (snapshot target_schema is passed
    here as custom_schema_name).
#}
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is none -%}
        {{ target.schema }}
    {%- elif target.schema == 'DBT_DEV' -%}
        {{ (target.schema ~ '_' ~ custom_schema_name) | trim }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
