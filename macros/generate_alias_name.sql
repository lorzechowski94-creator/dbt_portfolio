{#
    Physical relation name. The care token is no longer part of ANY model name:
    raw_access / staging are built once per care and separated by SCHEMA, and the
    role map (access) / intermediate / marts / report are one relation per account
    with the care as a COLUMN on the row (macros/union_cares.sql). So every model
    keeps its bare name in every account:
        meta_customer_role_map  -> ANALYTICS_INTERMEDIATE.care_management.meta_customer_role_map
        int__client_information -> ANALYTICS_INTERMEDIATE.care_management.client_information
        mart__dim_carer         -> ANALYTICS_MART.care_management.dim_carer

    RAW_ACCESS DOES NOT USE THIS RULE: every raw_acc__ model sets an explicit alias,
    the raw table's own name (raw_acc__tag_pick -> ANALYTICS_RAW_ACCESS.care2.tagpick),
    which takes the custom_alias_name branch below. models/raw_access/_raw_acc__models.yml
    says why.

    TESTS ARE THE ONE EXCEPTION, and stay care-prefixed. They materialise nothing
    today (store_failures is off), but were store_failures ever enabled their audit
    tables would land in a shared schema, where one care's run would overwrite the
    previous care's failures.

    THIS USED TO PREFIX THE INTERMEDIATE LAYER (care2_client_information), with a
    carve-out that left care1 bare outside R1 prod. Both are gone: the layer is no
    longer built per care, so there is nothing to keep apart. The one-off cost is on
    the R1 prod account, where the care1_* and care4_* relations in care_management
    and report are replaced by a single bare-named one. dbt drops only what it
    manages, so the old prefixed relations stay behind, frozen at their last refresh
    and still readable by whatever is connected to them. Repoint Power BI at the
    bare names first, then drop the old ones by hand — leaving them is how someone
    ends up reporting on a table that stopped refreshing without ever erroring.
#}
{% macro generate_alias_name(custom_alias_name=none, node=none) -%}
    {%- if custom_alias_name -%}
        {{ custom_alias_name | trim }}
    {%- elif node.version -%}
        {{ return(node.name ~ "_v" ~ (node.version | replace(".", "_"))) }}
    {%- else -%}
        {%- set bare = node.name.split('__') | reject('equalto', '') | list | last -%}
        {%- if node.resource_type == 'model' -%}
            {{ bare }}
        {%- else -%}
            {{ env_var('DBT_CARE', 'care1') }}_{{ bare }}
        {%- endif -%}
    {%- endif -%}
{%- endmacro %}
