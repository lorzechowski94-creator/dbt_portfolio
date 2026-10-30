{#
    Guard: refuse to BUILD a care into an account that does not hold it.

    Wired as an on-run-start hook (dbt_project.yml). Hooks are rendered during
    parsing, so this raises before the adapter does any work — a wrong-account
    run dies before a single relation is created.

    Only BUILDING commands raise. Read-only commands (parse, ls, compile, docs,
    source freshness) are deliberately let through: they touch no warehouse and
    cannot create an orphan tree, and inspecting another care's rendering —
    `DBT_CARE=care5 dbt ls` — is exactly how this project is reviewed. Gating on
    flags.WHICH keeps that workflow usable without weakening the real protection,
    because a `dbt build` parses under WHICH='build' and is still caught.

    WHICH CARES EXIST, AND WHICH ACCOUNT HOLDS THEM, live in
    macros/source_topology.sql — all_sources() and account_sources(). They moved there
    because models/intermediate/union/ needs the same two facts. Add a care or an account
    THERE; this macro only enforces them.


    ==========================================================================
    THE BUILD HAS TWO PHASES, AND THIS GUARD ONLY CONSTRAINS THE FIRST
    ==========================================================================
    Phase 1, ONCE PER CARE: access + raw_access + staging + intermediate.
        DBT_CARE=care4 dbt build --exclude tag:shared
    Phase 2, ONCE PER ACCOUNT: the union layer, the marts and the report views,
    which are account-wide and carry the care as a COLUMN:
        dbt build --select tag:shared

    Phase 2 reads every care's intermediate relations by name (see
    macros/union_cares.sql) and builds one set of marts for the whole account, so
    its $DBT_CARE is IRRELEVANT — it only has to be a care the account holds, so
    that this guard passes. .gitlab-ci.yml runs phase 2 after the phase-1 loop
    completes, in the same job; running it earlier is not an error, it just
    unions whatever each care last left behind.


    ==========================================================================
    ADDING A NEW CARE (an extra tenant schema inside an account that already
    deploys). CARE4 alongside CARE1 in the R1 account is the worked example, and
    the CARE4 references below are that real case rather than a placeholder.
    ==========================================================================
    The models are NOT copied — one set already serves every care. There is also
    no new database: ANALYTICS_RAW / _RAW_ACCESS / _STAGING / _INTERMEDIATE / _MART
    are per LAYER, not per care, and carry the same names in every account. Only
    the schema inside them changes, and it is already parametrised.

    In Snowflake, before the first deploy:
      1. ANALYTICS_RAW.CARE4 exists and is loaded, with the SAME table layout as
         the other cares (models/sources.yml is one definition for all of them —
         a missing or differently-named table breaks that care only).
      2. DBT_TRANSFORMER can read it, and can create in ANALYTICS_RAW_ACCESS.CARE4
         and ANALYTICS_STAGING.CARE4 — see ci/bootstrap-wif.sql.
      3. Its customers' reader roles exist, named exactly as
         models/access/meta_customer_role_map.sql derives them
         (ANALYTICS__CARE4_<company>_READER — the care is in the name, so a company
         that already has roles in another care still needs new ones here), and
         hold SELECT on the report schema. The map itself needs no edit — it is
         built from every care's `location` — but a role whose name does not
         match the derived one is granted nothing, and that shows up as an empty
         report rather than an error.

    In this repo, all in ONE merge request:
      4. macros/source_topology.sql: add 'care4' to all_sources() AND to its
         account's account_sources() entry. Miss this and every build for it is
         refused (loudly — the point), and the union layer never reads it. Give it
         the next free number in source_codes() too; nothing compiles until you do.
      5. .gitlab-ci.yml: add it to the deploy job's phase-1 `for CARE in ...`
         loop AND to the dbt_validate loop, so its rendering is checked on every
         MR. Phase 2 needs no edit — it follows account_sources().

    Nothing to change in models/, dbt_project.yml or sources.yml: +schema, the
    source schema and the alias prefix all follow $DBT_CARE on their own. Verify
    with `DBT_CARE=care4 dbt ls --target <target>` — read-only, so it renders even
    before step 4 is merged.

    A NEW CARE CHANGES EXISTING MART ROWS. The union layer stacks it into the
    account's shared marts, so the first phase-2 run after step 4 adds its rows to
    every report view. The incremental facts merge on a key that starts with
    `source`, so nothing collides — but a full-history care arriving through a
    60-day incremental window only brings its recent rows. Run phase 2 once with
    --full-refresh after adding a care.


    ==========================================================================
    ADDING A NEW ACCOUNT / REGION
    ==========================================================================
    R3 (MYORG-PROD_R3, schemas ALPHA and ALPHA2) is the worked example — grep
    `prod_r3` across the repo to see every touch point at once.
      1. ci/bootstrap-wif.sql, run ONCE in the new account as ACCOUNTADMIN: it
         creates SVC_DBT_CI and its WORKLOAD_IDENTITY. The SQL is identical
         everywhere; only the account it is run in differs.
      2. The four ANALYTICS_* databases must exist there, with the same names.
      3. ci/profiles.yml: a new target (e.g. prod_r3) with the account PINNED, not
         env_var-driven, so it can never silently fall back to another account.
      4. .gitlab-ci.yml: add the target to the `deploy` input's `options:`, add it
         to dbt_validate's parse loop, then copy the dbt_deploy_prod_r2 job — its
         rules, `environment: production_r3`, id_tokens and artifacts — and put
         that account's cares in its phase-1 loop.
      5. macros/source_topology.sql: a new account_sources() entry keyed on the
         ACCOUNT IDENTIFIER (e.g. 'MYORG-PROD_R3'), not on the target name,
         listing its cares, and each of those cares added to all_sources() and
         numbered in source_codes().
      6. Steps 1, 2 and 3 of ADDING A NEW CARE, for each care it holds.

    The tenant token need not look like careN — R3's schemas are ALPHA / ALPHA2 and
    nothing in the repo parses the name. It is the SCHEMA each per-care layer is
    built into, and a value of the `source` column from `intermediate` upwards; no
    relation name carries it (macros/generate_alias_name.sql).
#}
{% macro assert_care_target() %}
    {%- set care = env_var('DBT_CARE', 'care1') -%}
    {%- set all = all_sources() -%}
    {#- Commands that write to the warehouse. Everything else only reads.
        'run-operation' is on the list because create_semantic_views issues DDL
        through it — and because on-run-start does NOT fire for run-operation, that
        macro has to call this one itself. -#}
    {%- set building = ['run', 'build', 'seed', 'snapshot', 'test', 'clone', 'retry', 'run-operation'] -%}

    {%- if care not in all -%}
        {%- do exceptions.raise_compiler_error(
            "DBT_CARE='" ~ care ~ "' is not a known care. Expected one of: "
            ~ all | join(', ') ~ "."
        ) -%}
    {%- endif -%}

    {%- if flags.WHICH in building -%}
        {#- sources_in_account() raises on its own for an account nobody has declared,
            with the message that names where to add it. Calling it here rather than
            repeating the lookup is what keeps this guard and union_cares agreeing on
            which cares an account holds — the whole point of source_topology. -#}
        {%- set expected = sources_in_account() -%}
        {%- if care not in expected -%}
            {%- do exceptions.raise_compiler_error(
                "Account '" ~ normalise_account(target.account) ~ "' (target '" ~ target.name
                ~ "') holds " ~ expected | join(' / ') ~ ", but DBT_CARE='" ~ care ~ "'. It has no"
                ~ " such source data, so this build would create an orphan tree."
                ~ " Set DBT_CARE to a care this account holds (or unset it for care1)."
            ) -%}
        {%- endif -%}
    {%- endif -%}
    {#- Renders to whitespace on the success path. dbt skips whitespace-only
        hooks (get_execution_status returns Success without touching the adapter),
        so this costs no warehouse round-trip. -#}
{% endmacro %}
