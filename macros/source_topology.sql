{#
    SOURCE TOPOLOGY — which tenants (cares, i.e. source schemas) exist, and which
    ACCOUNT holds each of them:

        all_sources()          every tenant token the repo knows
        source_codes()         tenant token -> its permanent number
        source_code()          that number as SQL, for a `source` column
        account_sources()      account identifier -> the cares it holds
        sources_in_account()   the cares the CURRENT target's account holds
        normalise_account()    the comparison form of an account identifier

    Named care_topology / care_key / all_cares ... until 2026-10, when the tenant
    column became `source` (macros/union_cares.sql says why).

    WHY THIS IS ITS OWN FILE. Three callers need the same answer for different
    reasons, and they must not drift:
        assert_care_target   refuses a build whose care the target's account does
                             not hold;
        union_cares          decides WHICH relations go into the union that every
                             intermediate model is built on;
        create_semantic_views  reports what one account-wide run covered.
    A second copy of the list would let the guard pass a build while the union
    reads a care nobody is writing, or quietly leaves one out — a mart missing a
    whole tenant, with no error anywhere. That is the failure mode this file
    exists to make impossible.

    NOT HERE: how a relation is NAMED. That rule collapsed to "bare, unless it is
    a test" when intermediate, marts and report stopped being built per care, and
    lives back in macros/generate_alias_name.sql with its only real caller.

    KEEP IN SYNC with the `account:` lines in ci/profiles.yml (and the root
    profiles.yml). The onboarding checklists — ADDING A NEW CARE, ADDING A NEW
    ACCOUNT / REGION — are in macros/assert_care_target.sql and both start here.
#}

{% macro all_sources() %}
    {#- The TENANT TOKEN is whatever that tenant's schema is called in
        ANALYTICS_RAW; it is not a naming convention. R1/R2 mostly use careN, but
        the R2 account also holds BETA, and the R3 account's schemas are simply ALPHA
        and ALPHA2. Nothing here parses the name. -#}
    {{ return(['care1', 'care2', 'care3', 'care4', 'care5', 'alpha', 'alpha2', 'beta']) }}
{% endmacro %}


{% macro source_codes() %}
    {#- A NUMBER per tenant, for keys that have to be integers — today only
        mart__schedule_difference_report.occurrence_key, whose layout is in
        models/marts/_mart__models.yml. The token cannot supply it: nothing parses
        tenant names (see all_sources()).

        PERMANENT. The numbers are stored inside keys an incremental mart keeps for
        years, so never renumber or reuse one. A new care takes the next free
        number; source_code() refuses to compile while a care in all_sources() has
        none. -#}
    {{ return({'care1': 1, 'care2': 2, 'care3': 3, 'care4': 4, 'care5': 5, 'alpha': 6, 'alpha2': 7, 'beta': 8}) }}
{% endmacro %}


{% macro source_code(source_col) %}
    {#- source_codes() as a CASE over the `source` column. A care the map does not know
        yields NULL, which the not_null test on the key reports. -#}
    {%- set codes = source_codes() -%}
    {%- for care in all_sources() if care not in codes -%}
        {%- do exceptions.raise_compiler_error(
            "Care '" ~ care ~ "' is in all_sources() but has no number in source_codes()"
            ~ " (macros/source_topology.sql). Give it the next free one."
        ) -%}
    {%- endfor -%}
    {%- if codes.values() | unique | list | length != codes | length -%}
        {%- do exceptions.raise_compiler_error("source_codes() gives two cares the same number.") -%}
    {%- endif -%}
    case {{ source_col }}{% for care, code in codes.items() %} when '{{ care }}' then {{ code }}{% endfor %} end
{%- endmacro %}


{% macro account_sources() %}
    {#- Which cares each ACCOUNT's ANALYTICS_RAW actually holds. Keyed on the
        account, not the target name, because the account is what the constraint
        is really about: ci/profiles.yml `dev` and the root profiles.yml `dev`,
        `ci` and `prod` are four different target NAMES that all connect to the
        same DEV account, and listing each of them separately would only invite
        them to drift apart. Any new target pointing at a known account is
        covered automatically.

        Write the keys EXACTLY as the `account:` lines in profiles.yml. Both
        sides are normalised before comparing (upper-case, and '_' -> '-')
        because dbt-snowflake rewrites the identifier: profiles.yml says
        MYORG-PROD_R2, target.account reports MYORG-PROD-R2.

        Reading order (do NOT put these labels inline: a Jinja comment inside the
        dict literal breaks the expression and every build is then refused):
            MYORG-DEV     = DEV     <- ci/profiles.yml `dev`,
                                       root profiles.yml `dev` / `ci` / `prod`
            MYORG-PROD_R1 = R1 PROD <- `prod_r1`
            MYORG-PROD_R2 = R2 PROD <- `prod_r2`
            MYORG-PROD_R3 = R3 PROD <- `prod_r3` -#}
    {{ return({
        'MYORG-DEV': ['care1'],
        'MYORG-PROD_R1': ['care1', 'care4'],
        'MYORG-PROD_R2': ['care2', 'care3', 'care5', 'beta'],
        'MYORG-PROD_R3': ['alpha', 'alpha2']
    }) }}
{% endmacro %}


{% macro normalise_account(account) %}
    {{ return((account | default('', true)) | upper | replace('_', '-')) }}
{% endmacro %}


{% macro sources_in_account(account=none) %}
    {#- The cares the current target's account holds, in a STABLE order — it is
        the order of the union branches, so keeping it fixed keeps a rebuilt view
        textually identical when nothing changed. -#}
    {%- set wanted = normalise_account(account if account is not none else target.account) -%}
    {%- set by_account = {} -%}
    {%- for known, cares in account_sources().items() -%}
        {%- do by_account.update({normalise_account(known): cares}) -%}
    {%- endfor -%}
    {%- set found = by_account.get(wanted) -%}
    {%- if found is none -%}
        {%- do exceptions.raise_compiler_error(
            "Account '" ~ wanted ~ "' (target '" ~ target.name ~ "') is not in"
            ~ " account_sources(), so which cares it holds is unknown. Add it to"
            ~ " macros/source_topology.sql before building against it."
        ) -%}
    {%- endif -%}
    {{ return(found) }}
{% endmacro %}
