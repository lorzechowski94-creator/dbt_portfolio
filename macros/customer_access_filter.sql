{#
    Customer row-level filter for secure raw_access / report views (Standard
    Edition — no Row Access Policy). A reader role only sees rows whose
    (source, company, location) is mapped to it in the role map — plus, for a
    company-wide or company-group role, its companies' rows that have no location.

    A ROW WITH NO LOCATION STILL BELONGS TO ITS COMPANY. Matching the location
    with a plain `=` hid it from every role, because a null never equals
    anything: in care4, 3,313 statusPick rows of company 224 have no locationId,
    and ANALYTICS__CARE4_224_READER saw none of them (raised 2026-10-19). So a
    null location matches the map rows flagged is_company_wide, which only the
    company-wide family (ANALYTICS__CARE4_224_READER) and the company groups
    carry. A location reader (ANALYTICS__CARE4_224_L1368_READER) still does not
    see the row, because nothing ties the row to its location. A null company matches nothing, because a row
    without a company has no owner to show it to.

    THE MAP'S is_active IS NOT READ HERE, deliberately. It is `location.deleted is
    null`, and soft-deleting a location is a lifecycle action in the source app,
    not a revocation of the customer's access to their own history: the rows still
    belong to the same company and the same location. Filtering on it hid every
    past row of a closed location the moment it closed — silently, as an empty
    report — and a customer whose locations were ALL closed saw nothing at all
    while still holding a working role and grant. Access is "whose data is this",
    which soft-deleting does not change. The column stays in the map as a lifecycle
    marker; nothing reads it today.

    The map is a MODEL, one table per account derived from every care's `location`
    table (models/access/) — its yml carries the why, including the role names,
    which carry the care: ANALYTICS__CARE1_02_READER.

    THE SOURCE IS PART OF EVERY MATCH, AND MUST BE. Location ids are allocated per
    care (separate MySQL databases) and collide — id 24 exists in both care2 and
    care3. The role name carries its care, but the map's rows are matched on
    (company, location), and without the source term a reader of care3's location
    24 would also match the rows of care2's location 24. So:
      - report views over the shared marts pass source_col, the relation's own
        `source` column (every mart carries one);
      - per-care raw_access views leave it none, and the filter matches the care
        their run builds ($DBT_CARE) — such a view holds that care's rows only, by
        construction, so the literal is exact.

    BUILD_ROLES below are exempt (full access): SYSADMIN is the local developer,
    DBT_TRANSFORMER is the CI service role every target authenticates as (see
    ci/profiles.yml). A build role MUST be listed here — it is not a reader and
    has no row in the map, so without the exemption both branches of the
    predicate are false and every raw_access view returns ZERO rows. That fails
    silently: downstream models build green and empty, and incremental marts
    quietly stop growing while still holding their old rows.

    KEEP IN SYNC: this list must cover every `role:` in ci/profiles.yml. Exempting
    a build role costs nothing security-wise — it already holds SELECT on the raw
    tables (ci/bootstrap-wif.sql), so the filter never protected anything from it.

    Because raw_access and report models are secure (+secure: true), readers
    cannot see or bypass this predicate. Pass the source's real column names (they
    vary: most tables use locationid; client/carer use location; company/location
    use id).

    Usage in a raw_access model (there is ONE source for all cares; $DBT_CARE
    picks which care's schema it resolves to, see dbt_project.yml):
        select s.*
        from {{ source('raw_app', 'timesheet') }} as s
        where {{ customer_access_filter() }}

    Usage in a report model over a shared mart:
        select s.*
        from {{ ref('mart__dim_client') }} as s
        where {{ customer_access_filter(
            source_col='s.source', company_col='s.company_id', location_col='s.location_id') }}

    For company-only tables (no location column) pass location_col=none to
    filter on source + company_id alone.

    For lookup tables whose app-wide rows sit under a placeholder company (the
    source app's company 0), pass shared_company_id=0. Those rows are not one
    customer's data, so every reader of the source sees them, both role families,
    next to its own company's rows. "Every reader of the source" means any role
    with at least one map row in that source. A role from another care, or a role
    nobody mapped, still sees nothing. Opt in per model, and only where company 0
    really means "shared". Without the parameter such rows are shown to no reader.
#}
{% macro customer_access_filter(company_col='s.companyid', location_col='s.locationid', source_col=none, shared_company_id=none) %}
    {%- set build_roles = ['SYSADMIN', 'DBT_TRANSFORMER'] -%}
    {%- set source_expr = source_col if source_col is not none else "'" ~ env_var('DBT_CARE', 'care1') ~ "'" -%}
    current_role() in ({{ "'" ~ build_roles | join("', '") ~ "'" }})
    or exists (
        select 1
        from {{ ref('meta_customer_role_map') }} as m
        where m.role_name = current_role()
          and m.source = {{ source_expr }}
          and m.company_id = {{ company_col }}
          {% if location_col is not none %}
          and (
              m.location_id = {{ location_col }}
              or ({{ location_col }} is null and m.is_company_wide)
          )
          {% endif %}
    )
    {%- if shared_company_id is not none %}
    or (
        {{ company_col }} = {{ shared_company_id }}
        and exists (
            select 1
            from {{ ref('meta_customer_role_map') }} as m
            where m.role_name = current_role()
              and m.source = {{ source_expr }}
        )
    )
    {%- endif %}
{% endmacro %}
