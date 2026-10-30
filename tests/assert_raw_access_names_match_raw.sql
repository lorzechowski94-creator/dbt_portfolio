{#
    Every raw_access view must be named exactly like the raw table it passes
    through (models/raw_access/_raw_acc__models.yml says why). The name is set by
    hand — `config(alias=...)` at the top of each raw_acc__ model — because dbt
    fixes a model's alias while parsing models, before it has read sources.yml, so
    the alias cannot be looked up from the source's `identifier`. Two copies of one
    fact, and this test is what keeps them equal: one row per raw_access model
    whose alias differs from the physical table its source() resolves to.

    It reads the graph, which is only complete at execution time, so it checks
    nothing during `dbt parse` and renders an empty, passing query there.
    sqlfluff's jinja templater has no `graph` at all, hence the noqa below.
#}
-- noqa: disable=TMP
{%- set mismatches = [] -%}
{%- if execute -%}
    {%- for node in graph.nodes.values()
        if node.resource_type == 'model' and node.fqn[1] == 'raw_access' -%}
        {%- for s in node.sources -%}
            {%- set raw = graph.sources['source.' ~ project_name ~ '.' ~ s[0] ~ '.' ~ s[1]] -%}
            {%- if node.alias | lower != raw.identifier | lower -%}
                {%- do mismatches.append([node.name, node.alias, raw.identifier]) -%}
            {%- endif -%}
        {%- endfor -%}
    {%- endfor -%}
{%- endif -%}

{%- for m in mismatches %}
select
    '{{ m[0] }}' as model_name,
    '{{ m[1] }}' as view_name,
    '{{ m[2] }}' as raw_table
union all
{%- endfor %}
select
    null as model_name,
    null as view_name,
    null as raw_table
where false
