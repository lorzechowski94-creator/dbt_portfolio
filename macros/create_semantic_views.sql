{#
    Snowflake SEMANTIC VIEWs over the REPORT layer, for the managed MCP server.

    WHY THIS IS A MACRO AND NOT A MODEL — AND WHY THAT IS A STOPGAP: dbt-snowflake
    has no NATIVE materialization for semantic views (still an open request,
    dbt-labs/dbt-adapters#1260). But there IS a supported package —
    Snowflake-Labs/dbt_semantic_view, pointed at from the dbt Snowflake configs
    docs — which adds `materialized='semantic_view'` and takes the same
    tables/relationships/facts/dimensions/metrics body. That is the better home:
    real models, real lineage, `dbt build`, and no hand-built object names. Moving
    there is the intended next step; this macro exists because the project has no
    packages.yml yet. CI does not run `dbt deps` either (.gitlab-ci.yml,
    .dbt_setup), so adopting it means adding packages.yml and putting that call
    back.

        dbt run-operation create_semantic_views --target dev
        DBT_CARE=care2 dbt run-operation create_semantic_views --target prod_r2

    Print the DDL instead of running it — do this FIRST, the `create semantic view`
    grammar is version-sensitive and NONE of this has been executed against a
    warehouse yet:

        dbt run-operation create_semantic_views --args '{dry_run: true}'

    WIRED INTO CI, in all four build jobs (.gitlab-ci.yml). `dbt build` does NOT
    run run-operations, so that line is the only thing that ever executes this DDL
    — remove it and the semantic views silently stop being maintained while every
    deploy stays green. It runs ONCE PER ACCOUNT, after the shared phase that
    builds the report views, NOT inside the per-care loop: both the object name and
    the relations it ref()s are account-wide now. It gets its own --target-path
    (run-operation writes run_results.json too) and its failure sets the job's RC
    without unwinding the build that already ran.

    THE GRAMMAR HAS NOT BEEN EXECUTED AGAINST SNOWFLAKE. `--args '{dry_run: true}'`
    renders and resolves ref(), which is all it proves; the DDL itself has never
    reached a parser. These could still be rejected: `count(*)` as a metric
    with no fact reference, a qualified column inside a dimension expression
    (trim(clients.area_name)), `position` as an expression (it is a Snowflake
    function name), the clause order primary key -> with synonyms -> comment, and
    from the qualification view, `count(distinct case when ... end)` as a metric
    expression plus a bare boolean column used as a predicate (is_expiring). Those
    two have safe rewrites if rejected: sum(distinct ...) is not one, but
    count(distinct iff(...)) and `= true` are. From the workforce view:
    `non additive by` naming a dimension by its bare name (the documented form),
    a derived metric that combines two logical tables and reads a semi-additive
    one, and two fact tables declared with no primary key. From the all carers
    and all clients views: no FACTS clause at all (only dimensions and metrics),
    and in the all clients view a primary key column that can be null (branch_id
    of the workgroup bridge, for a workgroup with no branch).
    Run `dbt run-operation create_semantic_views --target dev` against your own
    DBT_DEV_ sandbox BEFORE merging this to main — otherwise the first prod deploy
    is where it gets found, on three accounts at once.
    The task review view adds current_date() inside a metric and inside a dimension
    expression, and again a fact table with no primary key.

    ALSO STILL NEEDED, and not in this repo: the CREATE SEMANTIC VIEW grant for
    DBT_TRANSFORMER (ci/bootstrap-wif.sql, added in the same commit as this macro
    and therefore not yet applied in ANY account — a CI run fails without it), the
    SELECT grants that let a reader role query these, and the MCP server object
    that registers them as tools. A semantic view nothing is granted on and no MCP
    server points at is an object with no consumer.

    `create or replace` is idempotent, but it is NOT grant-preserving on its own —
    hence `copy grants` on every statement. Without it every redeploy silently
    revokes the MCP role's SELECT. Note also that the CREATE SEMANTIC VIEW schema
    privilege is a distinct grant (see ci/bootstrap-wif.sql), and that granting a
    role on a semantic view exposes the data underneath it without needing SELECT
    on the underlying relations.

    THE TABLES ARE THE `REPORT` VIEWS, NEVER THE MARTS. Those views are secure and
    carry customer_access_filter, so RLS still applies to whatever the MCP server
    asks. Pointed at care_management this would hand every customer's rows to every
    reader. Verified safe on the axis that matters: a semantic view is owner's-rights
    for PRIVILEGE CHECKS, but current_role() is session-scoped, so the filter still
    evaluates with the READER's role — the build role's exemption is not inherited.

    WHICH METRICS ARE HERE: the additive sums, plus every non-additive measure from
    docs/powerbi_*_measures.md that is pure arithmetic over aggregates — those are
    the whole point, computed at query time after the date filter, exactly as DAX
    computes them. DELIBERATELY ABSENT: the continuity trio (Carers, Continuity,
    Continuity %), the whole `Year …` family, `Total Deliverable`, every `HH:MM`
    measure and every `… Colour` measure, and from Workforce Capacity `Unfilled
    hrs/wk`, `Estimated Additional Customers` and every prior-period and Δ
    measure. Each absence has a reason, recorded at the
    metric's own site below or in docs/mcp_semantic_view_metrics.md — the continuity
    ones are argued at length, because their absence is the one that looks like an
    oversight. The all carers and all clients views are the exception to "from a
    Power BI doc": their counts are defined here, for the overlapping branch /
    workgroup / tag (and, for clients, job type) breakdowns no Power BI measure
    covers. From Task Review, `% Completed` is absent as well: its definition is
    still a draft (docs/powerbi_task_review_setup.md).

    NAMING: no care token, because there is nothing to separate. The report views
    these sit over are ACCOUNT-WIDE — one relation per account, every care's rows
    in it, the care carried as a column — so one semantic view per account covers
    all of them and `source` is available as a dimension inside it. Creating one per
    care would create N identical objects, each exposing every care, differing only
    in name: worse than useless, because the name would assert a scoping that is
    not there.

    THAT IS A CHANGE. The per-care objects (care1_client_hours_sv, ...) are not
    dropped by this macro — `create or replace` only replaces what it names. They
    stay behind, frozen over relations that no longer refresh. Repoint the MCP
    server at the unprefixed names, then drop the old ones by hand.

    SO `source` IS EXPOSED AS A DIMENSION IN EVERY VIEW, and every view comment
    names its possible values. (In the workforce view it sits on the location,
    which both of its facts reach, and in the plan & assessment dates view, which
    all three of its lists reach.) The MCP server answers in natural language, and a
    question like "how many hours last month" now spans every tenant in the
    account unless someone says which one — so the model has to know the axis
    exists, what it is called, and that R3's tenants are `alpha` / `alpha2` rather
    than careN. Do not drop the dimension to tidy the view: without it the answer
    silently aggregates organisations that have nothing to do with each other.

    IT IS ALSO IN EVERY PRIMARY KEY AND EVERY RELATIONSHIP, which is not
    cosmetic. Client, carer, job type, group and location ids are allocated per
    care and collide within an account — measured on the R2 account, care2 and
    care3 share 9025 client ids and NOT ONE is the same person, and all 24 shared
    location ids name different places. A reference on the bare id joins one
    tenant's fact to another tenant's dimension, silently. `dates` is the only
    table keyed without the care: the calendar is shared and carries no care.

    THE KEYS ARE THE `*_key` COLUMNS the marts carry (client_key, carer_key,
    job_type_key, group_key, hr_file_key, location_key: care and id packed into
    one integer, macros/source_key.sql). They were built for Power BI, where a
    relationship takes exactly one column, and they serve here for the reason
    above: the care is part of the value, so no later edit can drop it from a
    join. A fact without a packed key (schedule difference, qualifications) names
    `source` in its primary key instead.

    The object's DATABASE AND SCHEMA come from a ref'd relation, never from
    `target.database` (which is ANALYTICS_RAW in every profile, while the report views
    live in ANALYTICS_MART) and never from a literal 'report' (which would bypass
    generate_schema_name's DBT_DEV_ sandbox prefix and let a local run overwrite the
    customer-facing objects).
#}

{#- Anchor for the object's container. dim_date is the one report view with no
    RLS predicate, so it is the most stable thing to hang the database/schema off,
    whether or not the view itself uses it (all_carers_sv and all_clients_sv do
    not). -#}
{% macro semantic_view_name(base) -%}
    {%- set anchor = ref('report__dim_date') -%}
    {{ anchor.database }}.{{ anchor.schema }}.{{ base }}
{%- endmacro %}


{% macro create_semantic_views(dry_run=false) %}
    {#- on-run-start does NOT fire for run-operation, so the care/account guard has
        to be called explicitly. 'run-operation' was added to that macro's `building`
        list for this reason — this operation writes to the warehouse. -#}
    {{ assert_care_target() }}

    {% set views = [
        semantic_view_client_hours(),
        semantic_view_carer_hours(),
        semantic_view_continuity(),
        semantic_view_schedule_difference(),
        semantic_view_carer_qualification(),
        semantic_view_workforce_capacity(),
        semantic_view_plan_assessment_dates(),
        semantic_view_task_review(),
        semantic_view_all_carers(),
        semantic_view_all_clients()
    ] %}

    {% for ddl in views %}
        {% if dry_run %}
            {{ log(ddl, info=True) }}
        {% else %}
            {% do run_query(ddl) %}
        {% endif %}
    {% endfor %}

    {#- The account, not $DBT_CARE: these are account-wide now, and logging a single
        care would read as if only that tenant were covered. -#}
    {{ log(
        (views | length) ~ " semantic view(s) "
        ~ ("rendered (dry run)" if dry_run else "created")
        ~ " for account " ~ normalise_account(target.account)
        ~ " (cares: " ~ sources_in_account() | join(', ') ~ ")",
        info=True
    ) }}
{% endmacro %}


{#- ------------------------------------------------------------------ client hours -#}
{% macro semantic_view_client_hours() %}
create or replace semantic view {{ semantic_view_name('client_hours_sv') }}
    tables (
        hours as {{ ref('report__client_hours_report') }}
            primary key (client_key, service_date, job_type_key)
            comment = 'Client hours per client per service date per job type, full history plus the next 60 days, every care in the account.',
        clients as {{ ref('report__dim_client') }}
            primary key (client_key)
            with synonyms ('client', 'service user', 'resident'),
        job_types as {{ ref('report__dim_jobtype') }}
            primary key (job_type_key)
            with synonyms ('job type', 'visit type', 'service type'),
        job_type_groups as {{ ref('report__dim_jobtype_group') }}
            primary key (group_key)
            with synonyms ('job type group', 'service group'),
        job_type_group_bridge as {{ ref('report__bridge_jobtype_group') }}
            primary key (group_key, job_type_key)
            comment = 'Group membership, one row per (source, group, job type). Many-to-many.',
        dates as {{ ref('report__dim_date') }}
            primary key (calendar_date)
    )
    -- EVERY KEY AND EVERY REFERENCE CARRIES `source`, INSIDE THE KEY, and that is the
    -- point. Client, job type and group ids are allocated per care and genuinely
    -- collide: measured on the R2 account, care2 and care3 share 9025 client ids and
    -- NOT ONE of them is the same person, and all 24 shared location ids name
    -- different places. A reference that lost `source` would join one tenant's hours
    -- to another tenant's client — silently, and with no row count that looks wrong.
    --
    -- The *_key columns (care and id in one integer, macros/source_key.sql) make that mistake
    -- unavailable rather than merely documented: the tenant is part of the value, so
    -- there is no `source` for a later edit to drop. They were introduced for Power BI,
    -- which allows only one column per relationship; reusing them here costs nothing
    -- and removes the one failure mode this comment used to guard by hand.
    -- `dates` is the exception: the calendar is shared and carries no care.
    relationships (
        hours (client_key) references clients (client_key),
        hours (job_type_key) references job_types (job_type_key),
        hours (service_date) references dates (calendar_date),
        -- JOB TYPE GROUP IS MANY-TO-MANY, and the bridge is the CHILD of both
        -- dimensions: mart__bridge_jobtype_group explodes
        -- jobtypeGroupName.jobTypeList, so one job type can appear under several
        -- groups (13 do in care2). Reaching a group from the fact therefore means
        -- hours -> job_types -> bridge -> job_type_groups, and the middle hop runs
        -- AGAINST the declared direction, one-to-many.
        --
        -- WHETHER SNOWFLAKE RESOLVES THAT AT ALL IS UNVERIFIED — the first execution
        -- of this DDL is the test, not the dry run. If it is rejected: delete
        -- job_type_groups, job_type_group_bridge, these two relationships and the
        -- group_name dimension from all three fact views, and state in the MCP tool
        -- description that grouping by job type group is unavailable. Do NOT work
        -- around it by folding one group onto dim_jobtype — a job type in two groups
        -- would then show under one, which understates that group and disagrees with
        -- the report.
        job_type_group_bridge (job_type_key) references job_types (job_type_key),
        job_type_group_bridge (group_key) references job_type_groups (group_key)
    )
    facts (
        hours.allocated_hrs as allocated_hrs,
        hours.total_scheduled_hrs as total_scheduled_hrs,
        hours.scheduled_unassigned_hrs as scheduled_unassigned_hrs,
        hours.scheduled_event_hrs_all as scheduled_event_hrs_all,
        hours.non_delivered_incl_cancelled_hrs as non_delivered_incl_cancelled_hrs,
        hours.cancelled_timesheet_billed_hrs as cancelled_timesheet_billed_hrs,
        hours.cancelled_timesheet_not_billed_hrs as cancelled_timesheet_not_billed_hrs,
        hours.confirmed_payable_hrs as confirmed_payable_hrs,
        hours.total_confirmed_billed_hrs as total_confirmed_billed_hrs,
        hours.total_actual_time_hrs as total_actual_time_hrs,
        hours.schedule_difference_hrs as schedule_difference_hrs,
        hours.breaks_paid_scheduled_hrs as breaks_paid_scheduled_hrs,
        hours.breaks_unpaid_scheduled_hrs as breaks_unpaid_scheduled_hrs,
        hours.breaks_paid_scheduled_unassigned_hrs as breaks_paid_scheduled_unassigned_hrs,
        hours.breaks_unpaid_scheduled_unassigned_hrs as breaks_unpaid_scheduled_unassigned_hrs,
        hours.breaks_paid_confirmed_hrs as breaks_paid_confirmed_hrs,
        hours.breaks_unpaid_confirmed_hrs as breaks_unpaid_confirmed_hrs
    )
    dimensions (
        -- WHICH SOURCE SCHEMA THE ROW CAME FROM, and the first thing to check when a
        -- question implies one organisation. ONE view covers every care in the
        -- account: care1 / care4 in R1, care2 / care3 / care5 / beta in R2, and
        -- alpha / alpha2 in R3 — beta and the R3 tenants are NOT named careN at all, so
        -- never assume the value looks like "careN". An unfiltered question totals
        -- across all of them, which is rarely what someone means; ask which care
        -- they want, or answer for all and say so.
        hours.source as source
            with synonyms ('care', 'tenant', 'source schema', 'instance', 'care database')
            comment = 'Tenant the row came from: care1/care4 (R1), care2/care3/care5/beta (R2), alpha/alpha2 (R3).',
        clients.client_name as full_name with synonyms ('client name'),
        clients.client_no as client_no with synonyms ('social services ref', 'resident id'),
        clients.area as area_name,
        clients.branch as branch,
        clients.workgroup as workgroup,
        -- These are DISPLAY columns in Power BI, not grouping ones: the report's
        -- `Report Grouping` field parameter groups only by client, area, branch and
        -- job type group, while `Column Visibility` offers the rest as columns shown
        -- beside a client in the two client-grain views. A semantic view has no such
        -- split — a dimension can always be grouped by — so these are exposed
        -- because "hours by county" / "by care manager" / "by funder" are sensible
        -- questions, not because the report does it.
        clients.town as town,
        clients.county as county,
        clients.cso as cso with synonyms ('client services officer'),
        clients.coordinator_zone as coordinator_zone with synonyms ('coordinator', 'zone'),
        clients.care_manager as care_manager,
        clients.funder as funder,
        clients.referral_reason as referral_reason,
        -- NOT EXPOSED, though Power BI offers them as columns: date_of_birth,
        -- address, post_code, phone and email are personal data with no grouping
        -- value, and billing_code / unit_id / council_id are opaque ids nobody asks
        -- a question in. A report showing a phone number to a named user is not the
        -- same act as handing it to a language model.
        -- STATUS AS THE LABEL, NOT THE CODE. state_id is 1/2/3, so grouping by it
        -- answers with "1, 2, 3" and leaves the caller to decode it; status_label
        -- carries the text and sits on the same row. The code was only ever in scope
        -- because Total Deliverable's fallback reads SELECTEDVALUE(state_id), and
        -- that measure is deliberately absent (see the metrics block below), so it
        -- had no consumer here. If it comes back as a per-row condition it needs the
        -- column inside the metric, not a dimension. Neither is grouped or displayed
        -- by the Power BI report.
        clients.client_status as status_label with synonyms ('status', 'client status'),
        job_types.job_type as job_type_name,
        -- GROUP FIGURES OVERLAP, AND THAT MATCHES THE REPORT. 13 job types in care2
        -- belong to 2-3 groups, so their hours count under every group they are in
        -- and the group rows sum to MORE than the overall total. Power BI does
        -- exactly the same through the bidirectional cross-filter on the bridge —
        -- this is a property of the membership data, not of the model, so it is not
        -- something to "fix" here.
        -- SEPARATELY: the fact's NO_JOB_TYPE (-1) bucket belongs to no group, so any
        -- group-level figure EXCLUDES the client-level non-delivered hours parked
        -- there. Power BI works around it with
        -- CALCULATE([m], ALL(dim_jobtype_group), ALL(bridge)); a metric cannot
        -- rewrite its caller's filter, so here there is no workaround — only the
        -- comment on the dimension, which the MCP server can read.
        job_type_groups.job_type_group as group_name
            comment = 'Job type group. A job type may belong to several groups, so group totals overlap and do not sum to the overall total. Rows with no job type are excluded entirely.',
        dates.calendar_date as calendar_date,
        dates.year as year,
        dates.quarter as quarter_name,
        dates.month as month_name,
        dates.month_year as month_year_label
    )
    metrics (
        -- Additive: a plain sum is already the right answer. EVERY stored column
        -- gets one — a bare fact is not summable by the caller, since a semantic
        -- view query selects metrics and dimensions, not facts.
        hours.allocated as sum(hours.allocated_hrs),
        hours.total_scheduled as sum(hours.total_scheduled_hrs),
        hours.scheduled_unassigned as sum(hours.scheduled_unassigned_hrs),
        hours.scheduled_event_all as sum(hours.scheduled_event_hrs_all),
        hours.non_delivered_incl_cancelled as sum(hours.non_delivered_incl_cancelled_hrs),
        hours.cancelled_timesheet_billed as sum(hours.cancelled_timesheet_billed_hrs),
        hours.cancelled_timesheet_not_billed as sum(hours.cancelled_timesheet_not_billed_hrs),
        hours.total_confirmed_billed as sum(hours.total_confirmed_billed_hrs),
        hours.confirmed_payable as sum(hours.confirmed_payable_hrs),
        hours.total_actual_time as sum(hours.total_actual_time_hrs),
        hours.schedule_difference as sum(hours.schedule_difference_hrs),
        hours.breaks_paid_scheduled as sum(hours.breaks_paid_scheduled_hrs),
        hours.breaks_unpaid_scheduled as sum(hours.breaks_unpaid_scheduled_hrs),
        hours.breaks_paid_scheduled_unassigned as sum(hours.breaks_paid_scheduled_unassigned_hrs),
        hours.breaks_unpaid_scheduled_unassigned as sum(hours.breaks_unpaid_scheduled_unassigned_hrs),
        hours.breaks_paid_confirmed as sum(hours.breaks_paid_confirmed_hrs),
        hours.breaks_unpaid_confirmed as sum(hours.breaks_unpaid_confirmed_hrs),

        -- NON-ADDITIVE from here down. Each is the DAX measure of the same name in
        -- docs/powerbi_client_hours_measures.md, and each is WRONG if summed over
        -- date ranges or job types instead of being evaluated here.

        -- MAX(0, ...) floor: a job type whose cancelled hours exceed its
        -- non-delivered must read 0, not a negative.
        hours.non_delivered as greatest(
            0,
            sum(hours.non_delivered_incl_cancelled_hrs)
            - sum(hours.cancelled_timesheet_billed_hrs)
            - sum(hours.cancelled_timesheet_not_billed_hrs)
        ),

        -- IF(Sched > 0, ...) gate: allocated with no schedule contributes nothing.
        hours.a_v_s_difference as case
            when sum(hours.total_scheduled_hrs) > 0
                then round(sum(hours.allocated_hrs), 2) - round(sum(hours.total_scheduled_hrs), 2)
            else 0
        end,

        hours.billable_schedule as case
            when sum(hours.total_scheduled_hrs) > 0
                then sum(hours.total_scheduled_hrs) - sum(hours.cancelled_timesheet_not_billed_hrs)
            else 0
        end,

        hours.billable_v_confirmed as case
            when sum(hours.total_scheduled_hrs) > 0
                then sum(hours.total_scheduled_hrs) - sum(hours.cancelled_timesheet_not_billed_hrs)
            else 0
        end - sum(hours.total_confirmed_billed_hrs)

        -- DELIBERATELY ABSENT: Total Deliverable (hrs).
        --
        -- Its fallback branch reads SELECTEDVALUE(dim_client[state_id]), which only
        -- resolves with a single client in filter context. Two problems, either one
        -- enough to keep it out:
        --   * it would have to aggregate a column from ANOTHER logical table
        --     (max(clients.state_id)). A cross-table metric needs USING
        --     ( <relationship_name> ), and the relationships above are unnamed — so
        --     re-adding it means naming them first.
        --   * max(state_id) is NOT equivalent to SELECTEDVALUE above client grain.
        --     state_id is 1/2/3, so max() = 1 only when EVERY client in scope is
        --     active; one pending or inactive client silently flips the whole group
        --     to the else-0 branch. It also sees only clients joined to fact rows,
        --     while SELECTEDVALUE sees clients with no rows in the range too.
        --
        -- docs/mcp_semantic_view_metrics.md already lists this as an open decision:
        -- restrict it to client-grain questions, or rewrite the branch as a per-row
        -- condition so it aggregates. Until that is settled it stays out, same rule
        -- as the continuity trio — an absent measure beats one that quietly
        -- under-reports.
    )
    -- THE GRAIN OF THE ANSWER IS PART OF THE ANSWER. The Power BI report makes the
    -- caller pick one of four views (Client Hours, Client Hours Jobtype, Client
    -- Hours Area, Client Hours Branch) and defaults to the first; a semantic view
    -- has no such selector, so the default has to be stated here or the model picks
    -- one silently. It matters beyond layout: the non-additive metrics are evaluated
    -- PER GROUP, so a_v_s_difference and billable_schedule genuinely differ between
    -- a per-client and a per-branch answer. Same string belongs in the MCP tool
    -- description, which is what the model reads before it queries anything.
    comment = 'Client hours per client, service date and job type. DEFAULT GROUPING: per client - that is the default view of the Power BI report. Its other views group by job type group, by area, and by branch. If the question does not say which breakdown it wants, answer per client and state that. Non-additive metrics are evaluated per group, so the grouping changes their value, not only the layout. INCLUDES THE NEXT 60 DAYS: rows dated after today are a forecast from the current schedule, rebuilt on every refresh, so for a question about what has happened filter service_date to today or earlier, and say so when an answer includes future dates. COVERS EVERY CARE IN THE ACCOUNT - care1/care4 (R1), care2/care3/care5/beta (R2), alpha/alpha2 (R3), where the tenants are not named careN at all. An unfiltered answer totals across all of them, which is rarely what is meant: filter or group by source (the care) when the question is about one organisation, and always say which care the answer covers.'
    copy grants
{% endmacro %}


{#- ------------------------------------------------------------------- carer hours -#}
{% macro semantic_view_carer_hours() %}
create or replace semantic view {{ semantic_view_name('carer_hours_sv') }}
    tables (
        hours as {{ ref('report__carer_hours_report') }}
            primary key (carer_key, service_date, job_type_key)
            comment = 'Carer hours per carer per service date per job type, full history plus the next 60 days, every care in the account.',
        carers as {{ ref('report__dim_carer') }}
            primary key (carer_key)
            with synonyms ('carer', 'employee', 'staff member'),
        job_types as {{ ref('report__dim_jobtype') }}
            primary key (job_type_key),
        job_type_groups as {{ ref('report__dim_jobtype_group') }}
            primary key (group_key)
            with synonyms ('job type group', 'service group'),
        job_type_group_bridge as {{ ref('report__bridge_jobtype_group') }}
            primary key (group_key, job_type_key)
            comment = 'Group membership, one row per (source, group, job type). Many-to-many.',
        dates as {{ ref('report__dim_date') }}
            primary key (calendar_date)
    )
    -- Every key and every reference carries `source` inside the *_key value — see
    -- semantic_view_client_hours for why, and for the measured collision rates.
    relationships (
        hours (carer_key) references carers (carer_key),
        hours (job_type_key) references job_types (job_type_key),
        hours (service_date) references dates (calendar_date),
        -- Many-to-many via the bridge, and the traversal runs against the declared
        -- direction — see semantic_view_client_hours for the full argument and for
        -- what to delete if Snowflake rejects it.
        job_type_group_bridge (job_type_key) references job_types (job_type_key),
        job_type_group_bridge (group_key) references job_type_groups (group_key)
    )
    facts (
        hours.scheduled_hrs as scheduled_hrs,
        hours.confirmed_payable_hrs as confirmed_payable_hrs,
        hours.worked_hrs as worked_hrs,
        hours.contracted_hrs as contracted_hrs,
        hours.over_under_contracted_hrs as over_under_contracted_hrs,
        hours.phone_admin_total_count as phone_admin_total_count,
        hours.carer_confirmed_count as carer_confirmed_count
    )
    dimensions (
        -- Tenant the row came from — see the `source` dimension in
        -- semantic_view_client_hours for how to treat an unfiltered question.
        hours.source as source
            with synonyms ('care', 'tenant', 'source schema', 'instance', 'care database')
            comment = 'Tenant the row came from: care1/care4 (R1), care2/care3/care5/beta (R2), alpha/alpha2 (R3).',
        carers.carer_name as full_name with synonyms ('carer name'),
        carers.carer_no as carer_no,
        carers.area as area,
        carers.position as position,
        carers.town as town,
        carers.county as county,
        -- An attribute of the CARER, not of the hours row: filtering it asks "carers
        -- who started before X", never "hours booked before X". Exposed because
        -- tenure questions are the obvious use and dim_carer already carries it.
        carers.start_date as start_date
            comment = 'Carer employment start date.',
        -- NOT EXPOSED from dim_carer, deliberately: date_of_birth and address are
        -- personal data with no analytic use here (the birthday report is the place
        -- for the former), and surname / first_name are already covered by
        -- carer_name. Every extra dimension also dilutes the model's choice among
        -- them, so the bar is "someone groups or filters by this".
        job_types.job_type as job_type_name,
        -- Overlapping group totals, same as client hours. The no-job-type exclusion
        -- bites HARDER here: contracted hours sit ONLY on the no-job-type row (see
        -- the metric comment below), so every group-level figure has zero contracted
        -- hours in it.
        job_type_groups.job_type_group as group_name
            comment = 'Job type group. A job type may belong to several groups, so group totals overlap. Contracted hours carry no job type and are therefore absent from every group figure.',
        dates.calendar_date as calendar_date,
        dates.year as year,
        dates.quarter as quarter_name,
        dates.month as month_name,
        dates.month_year as month_year_label
    )
    metrics (
        hours.scheduled as sum(hours.scheduled_hrs),
        hours.confirmed_payable as sum(hours.confirmed_payable_hrs),
        hours.worked as sum(hours.worked_hrs),

        -- Contracted sits ONLY on the no-job-type row: cmContractsHours carries no
        -- jobType. So a question filtered to a real job type correctly returns zero
        -- contracted hours — the comment is here so that reads as intended rather
        -- than as missing data.
        hours.contracted as sum(hours.contracted_hrs)
            comment = 'Contracted hours. Recorded against no job type, so filtering to a job type returns 0.',

        hours.over_under_contracted as round(sum(hours.over_under_contracted_hrs), 2),
        hours.phone_admin_total as sum(hours.phone_admin_total_count),
        hours.carer_confirmed as sum(hours.carer_confirmed_count),

        -- NON-ADDITIVE: a ratio of two sums, never a sum of ratios.
        --
        -- The `> 0` gate is load-bearing and matches the DAX's two-argument
        -- IF(Total > 0, ...), which yields BLANK for a zero denominator. Bare div0
        -- would answer "0% carer-confirmed" instead of "no value" — and the
        -- denominator is zero in ordinary cases, not edge ones:
        -- phone_admin_total_count counts CONFIRMED timesheets only and is
        -- coalesced to 0 on every row raised by the scheduled or contracted pillar.
        -- The implicit NULL from the un-matched CASE is the BLANK equivalent.
        hours.confirmed_phone_vs_admin_pct as case
            when sum(hours.phone_admin_total_count) > 0
                then round(
                    div0(sum(hours.carer_confirmed_count), sum(hours.phone_admin_total_count)) * 100,
                    2
                )
        end
    )
    -- Default grain, same reasoning as client hours. NOT taken from a report view
    -- selector as that one is - this is the grain of the fact subject, so revisit it
    -- if the carer hours report turns out to default to something else.
    comment = 'Carer hours per carer, service date and job type. DEFAULT GROUPING: per carer. If the question does not say which breakdown it wants, answer per carer and state that. Contracted hours carry no job type, so they are absent from any job type or job type group breakdown - see the metric comment. INCLUDES THE NEXT 60 DAYS: rows dated after today are a forecast from the current schedule and contracts, rebuilt on every refresh, so for a question about what has happened filter service_date to today or earlier, and say so when an answer includes future dates. COVERS EVERY CARE IN THE ACCOUNT - care1/care4 (R1), care2/care3/care5/beta (R2), alpha/alpha2 (R3), where the tenants are not named careN at all. An unfiltered answer totals across all of them, which is rarely what is meant: filter or group by source (the care) when the question is about one organisation, and always say which care the answer covers.'
    copy grants
{% endmacro %}


{#- -------------------------------------------------------------------- continuity -#}
{% macro semantic_view_continuity() %}
create or replace semantic view {{ semantic_view_name('continuity_sv') }}
    tables (
        visits as {{ ref('report__continuity_report') }}
            primary key (client_key, service_date, carer_key)
            comment = 'Delivered visits per client per service date per carer, full history, every care in the account.',
        clients as {{ ref('report__dim_client') }}
            primary key (client_key)
            with synonyms ('client', 'service user', 'resident'),
        carers as {{ ref('report__dim_carer') }}
            primary key (carer_key),
        dates as {{ ref('report__dim_date') }}
            primary key (calendar_date)
    )
    -- Every key and every reference carries `source` inside the *_key value — see
    -- semantic_view_client_hours for why, and for the measured collision rates.
    relationships (
        visits (client_key) references clients (client_key),
        visits (carer_key) references carers (carer_key),
        visits (service_date) references dates (calendar_date)
    )
    facts (
        visits.visit_count as visit_count
    )
    dimensions (
        -- Tenant the row came from — see the `source` dimension in
        -- semantic_view_client_hours for how to treat an unfiltered question.
        visits.source as source
            with synonyms ('care', 'tenant', 'source schema', 'instance', 'care database')
            comment = 'Tenant the row came from: care1/care4 (R1), care2/care3/care5/beta (R2), alpha/alpha2 (R3).',
        clients.client_name as full_name with synonyms ('client name'),
        clients.client_no as client_no with synonyms ('social services ref'),
        -- Legacy prints 'Area Not Assigned' for an empty area; dim_client carries the
        -- raw name because it is shared, so the fallback happens here, matching the
        -- calculated column in Power BI.
        clients.area as coalesce(nullif(trim(clients.area_name), ''), 'Area Not Assigned'),
        clients.branch as branch,
        carers.carer_name as full_name,
        dates.calendar_date as calendar_date,
        dates.year as year
            comment = 'Calendar year. For a question about a whole year, filter this rather than a date range.',
        dates.quarter as quarter_name,
        dates.month as month_name,
        dates.month_year as month_year_label
    )
    metrics (
        visits.visits as sum(visits.visit_count)
            comment = 'Delivered timesheets. Additive; the denominator of the continuity ratio.'

        -- DELIBERATELY ABSENT: Carers, Continuity, Continuity %.
        --
        -- Not an oversight and not a syntax problem. Legacy's Carers is a distinct
        -- count PER CLIENT, then summed over clients, so a carer serving two clients
        -- counts twice. That is an aggregate of an aggregate; a metric is a single
        -- aggregate expression over the fact, with no iterator over a grain. It also
        -- cannot be precomputed in a view, because the per-client distinct has to
        -- form after the date filter.
        --
        -- The expressible alternative, count(distinct carer_id), is a GLOBAL distinct
        -- and a materially different number — systematically a higher continuity %.
        -- Which of the two the report should show is still an open business decision
        -- (see docs/powerbi_continuity_report_measures.md). Publishing the global
        -- distinct here would settle that decision silently, for one consumer only,
        -- and leave MCP disagreeing with Power BI with nothing on screen to say which
        -- is right. An absent measure is the honest answer until the call is made.
        --
        -- When it is made: add it under a name that states which definition it is.
    )
    comment = 'Continuity of care - delivered visits per client, service date and carer. DEFAULT GROUPING: per client, which is the grain the report continuity figures are built on. Visits only - the carer and continuity measures need a business decision first, see docs/mcp_semantic_view_metrics.md. COVERS EVERY CARE IN THE ACCOUNT - care1/care4 (R1), care2/care3/care5/beta (R2), alpha/alpha2 (R3), where the tenants are not named careN at all. An unfiltered answer totals across all of them, which is rarely what is meant: filter or group by source (the care) when the question is about one organisation, and always say which care the answer covers.'
    copy grants
{% endmacro %}


{#- ----------------------------------------------------------- schedule difference -#}
{% macro semantic_view_schedule_difference() %}
create or replace semantic view {{ semantic_view_name('schedule_difference_sv') }}
    tables (
        calls as {{ ref('report__schedule_difference_report') }}
            primary key (source, recurr_id, occurrence_date)
            comment = 'One row per scheduled call occurrence, scheduled template vs matched timesheet, full history plus the next 60 days, every care in the account.',
        clients as {{ ref('report__dim_client') }}
            primary key (client_key),
        carers as {{ ref('report__dim_carer') }}
            primary key (carer_key),
        job_types as {{ ref('report__dim_jobtype') }}
            primary key (job_type_key),
        -- GROUPS ARE HERE ON PURPOSE, AND THE POWER BI REPORT DOES NOT HAVE THEM.
        -- scheduleReport_diff.php filters on a flat multi-select of job type NAMES —
        -- "Example Care Group HCA", "Example Care Group Shadowing" and so on are job
        -- types whose names happen to start with a customer name, not groups — so
        -- the Power BI port stops at a dim_jobtype slicer and carries no bridge.
        --
        -- The semantic view keeps the group path anyway because the two consumers pay
        -- different prices for it. Reaching a group from a fact in Power BI needs the
        -- bridge <-> dim_jobtype relationship to be BIDIRECTIONAL, which is a decision
        -- with consequences once RLS is on; in Snowflake the same path is an ordinary
        -- many-to-many join and costs nothing structural. So "schedule difference by
        -- job type group" is answerable here and deliberately absent from the report.
        -- If the report ever gains a group slicer, this view needs no change.
        job_type_groups as {{ ref('report__dim_jobtype_group') }}
            primary key (group_key)
            with synonyms ('job type group', 'service group'),
        job_type_group_bridge as {{ ref('report__bridge_jobtype_group') }}
            primary key (group_key, job_type_key)
            comment = 'Group membership, one row per (source, group, job type). Many-to-many.',
        dates as {{ ref('report__dim_date') }}
            primary key (calendar_date)
    )
    -- Every key and every reference carries `source` inside the *_key value — see
    -- semantic_view_client_hours for why, and for the measured collision rates.
    relationships (
        calls (client_key) references clients (client_key),
        calls (carer_key) references carers (carer_key),
        calls (job_type_key) references job_types (job_type_key),
        calls (occurrence_date) references dates (calendar_date),
        -- Many-to-many via the bridge — see semantic_view_client_hours. Note this
        -- fact COUNTS rows rather than summing hours, so an overlapping job type
        -- inflates `calls` and every count derived from it under each group it
        -- belongs to; confirmed_pct and on_time_pct_15 stay correct only because
        -- numerator and denominator inflate together.
        job_type_group_bridge (job_type_key) references job_types (job_type_key),
        job_type_group_bridge (group_key) references job_type_groups (group_key)
    )
    facts (
        calls.early_late_minutes as early_late_minutes,
        calls.time_diff_minutes as time_diff_minutes
    )
    dimensions (
        -- Tenant the row came from — see the `source` dimension in
        -- semantic_view_client_hours for how to treat an unfiltered question.
        calls.source as source
            with synonyms ('care', 'tenant', 'source schema', 'instance', 'care database')
            comment = 'Tenant the row came from: care1/care4 (R1), care2/care3/care5/beta (R2), alpha/alpha2 (R3).',
        clients.client_name as full_name,
        carers.carer_name as full_name,
        job_types.job_type as job_type_name,
        job_type_groups.job_type_group as group_name
            comment = 'Job type group. A job type may belong to several groups, so call counts overlap across groups and do not sum to the total. Calls with no job type are excluded.',
        calls.timesheet_status as timesheet_status comment = 'Confirmed / Submitted / None.',
        calls.schedule_status as case when calls.status_id = 2 then 'Cancelled' else 'Active' end,
        calls.cancellation_reason as cancellation_reason,
        dates.calendar_date as calendar_date,
        dates.year as year,
        dates.month as month_name,
        dates.iso_week as iso_week_label
    )
    metrics (
        calls.calls as count(*),
        calls.cancelled_calls as count_if(calls.status_id = 2),
        calls.missing_timesheets as count_if(calls.timesheet_status = 'None'),
        calls.total_time_diff_minutes as sum(calls.time_diff_minutes),

        -- NON-ADDITIVE: ratios and averages, computed here rather than summed.
        -- No gate needed on this one: its denominator is count(*), which is only
        -- zero when the group has no rows at all and therefore emits nothing.
        calls.confirmed_pct as round(
            div0(count_if(calls.timesheet_status = 'Confirmed'), count(*)) * 100,
            2
        ),
        calls.avg_early_late_minutes as round(avg(calls.early_late_minutes), 1),

        -- THE TOLERANCE IS FROZEN AT 15 MINUTES, AND IT IS IN THE METRIC NAMES.
        -- In Power BI it is a what-if parameter the user drags; a metric takes no
        -- runtime argument, so a value had to be picked. Do NOT read 15 as "the"
        -- tolerance: the DAX KPIs default to SELECTEDVALUE(..., 0), i.e. exact
        -- punctuality, and only Punctuality Colour defaults to 15. So an unsliced
        -- Power BI report and these metrics answer different questions — which is
        -- exactly why the number is in the identifier and in the comment the MCP
        -- server can actually see. To offer another tolerance, ADD a variant
        -- (on_time_pct_5, on_time_pct_30); never quietly re-point these.
        --
        -- NULL early_late_minutes means no timesheet matched at all. SQL comparisons
        -- exclude those on their own, but the DENOMINATOR must stay the three buckets
        -- summed, not count(*), or unmatched calls drag the percentage down without
        -- belonging to any bucket. (In DAX this is the load-bearing NOT ISBLANK
        -- guard.) count_if(... is not null) IS that sum: the three buckets partition
        -- the non-null rows exactly, and a call sitting on +/-15 lands in on-time
        -- under both definitions.
        calls.on_time_calls_15 as count_if(calls.early_late_minutes between -15 and 15)
            comment = 'Calls within +/-15 minutes of schedule. Fixed 15-minute tolerance.',
        calls.late_calls_15 as count_if(calls.early_late_minutes > 15)
            comment = 'Calls more than 15 minutes late. Fixed 15-minute tolerance.',
        calls.early_calls_15 as count_if(calls.early_late_minutes < -15)
            comment = 'Calls more than 15 minutes early. Fixed 15-minute tolerance.',

        -- Gated like the carer-hours percentage: a filter in which no call has a
        -- matched timesheet has a zero denominator with rows present, and must
        -- answer "no value" rather than "0% on time".
        calls.on_time_pct_15 as case
            when count_if(calls.early_late_minutes is not null) > 0
                then round(
                    div0(
                        count_if(calls.early_late_minutes between -15 and 15),
                        count_if(calls.early_late_minutes is not null)
                    ) * 100,
                    2
                )
        end
            comment = 'On-time share of MATCHED calls, fixed 15-minute tolerance. Null when no call has a timesheet.'
    )
    comment = 'Schedule difference - one row per scheduled call occurrence. DEFAULT GROUPING: per client. If the question does not say which breakdown it wants, answer per client and state that. On-time metrics use a fixed 15-minute tolerance, named in each metric; the Power BI KPIs default to 0, so these answer a different question than an unsliced report. INCLUDES THE NEXT 60 DAYS: calls dated after today are a forecast from the current schedule with no timesheet yet, so they count as timesheet status None - for a question about what has happened (missed calls, punctuality) filter occurrence_date to today or earlier. COVERS EVERY CARE IN THE ACCOUNT - care1/care4 (R1), care2/care3/care5/beta (R2), alpha/alpha2 (R3), where the tenants are not named careN at all. An unfiltered answer totals across all of them, which is rarely what is meant: filter or group by source (the care) when the question is about one organisation, and always say which care the answer covers.'
    copy grants
{% endmacro %}


{#- --------------------------------------------------------- carer qualifications -#}

{#- HR compliance. The view whose fact is NOT primarily a measure store: it is
    the flat qualification export, which the compliance dashboard reuses. That is why it earns a semantic view even though every
    figure is "just a count" — the counts are wrong in five different ways when
    written naively, and four of the five are invisible in the result:

      * STAFF vs FILES. Every non-compliant figure is a distinct count of carers;
        a row count answers with files and is silently larger.
      * The no-record rows. A carer holding no files still has a row, so count(*)
        counts them as files. Counting distinct qualification_record_id (null on
        exactly those rows) is what excludes them.
      * is_expiring OVERLAPS valid. It is not a fourth status.
      * The alert window is PER TYPE (cmQualificationsType.alertBefore). A caller
        writing SQL guesses 30 days and gets a plausible wrong number; the flag is
        already resolved on the row.
      * The report's SCOPE (active/pending carers) is a Power BI report-level
        filter, i.e. it exists nowhere in the warehouse.

    THE SCOPE IS THEREFORE BAKED INTO EVERY METRIC, not left to the caller: these
    metrics must return the report's numbers. `state` is deliberately NOT a
    dimension for the same reason — it could only ever contradict the metrics. -#}

{% macro semantic_view_carer_qualification() %}
    {#- One definition of the report's scope, interpolated into every metric below.
        Ten hand-copied predicates would be ten chances to drift. -#}
    {%- set in_scope = 'qualifications.state_id in (1, 2)' -%}
create or replace semantic view {{ semantic_view_name('carer_qualification_sv') }}
    tables (
        qualifications as {{ ref('report__carer_qualification_report') }}
            primary key (source, qualification_record_id)
            comment = 'One row per carer per HR file, every care in the account. A carer holding no files still has a row, with a null record id; every metric here excludes those.',
        hr_files as {{ ref('report__dim_hrfile') }}
            primary key (hr_file_key)
            with synonyms ('HR file type', 'qualification type', 'document type'),
        dates as {{ ref('report__dim_date') }}
            primary key (calendar_date)
    )
    -- Every key and every reference carries `source` inside the *_key value — see
    -- semantic_view_client_hours for why, and for the measured collision rates.
    relationships (
        qualifications (hr_file_key) references hr_files (hr_file_key),
        -- On the EXPIRY date, so "files expiring in October" is a date-range
        -- question. Files with no expiry (not-actioned, and valid-with-award-only)
        -- do not join, so ANY expiry filter drops them - stated in the view comment
        -- because not_actioned_files then reads 0 rather than "not applicable".
        qualifications (expired) references dates (calendar_date)
    )
    facts (
        -- Signed: negative is overdue. Exposed so "average days overdue" is
        -- answerable; the two metrics below mirror the report's own columns.
        qualifications.days_to_expiry as days_to_expiry
    )
    dimensions (
        -- Tenant the row came from — see the `source` dimension in
        -- semantic_view_client_hours for how to treat an unfiltered question.
        qualifications.source as source
            with synonyms ('care', 'tenant', 'source schema', 'instance', 'care database')
            comment = 'Tenant the row came from: care1/care4 (R1), care2/care3/care5/beta (R2), alpha/alpha2 (R3).',
        -- The NAME, never the id: cmQualificationsType is per tenant, so one file
        -- name exists once per company/location and only the name groups them.
        -- Retired types are included on purpose (audit history).
        hr_files.hr_file as hr_file_name
            comment = 'HR file / qualification name. Includes types the company has retired, because files recorded against them still count.',
        hr_files.hr_file_category as hr_file_type
            comment = 'One of the seven universal categories: Additional / Registrational / Company / Legal / Training / Private / Confidential Requirement.',
        qualifications.expire_status as expire_status
            comment = 'The file status: valid / not_actioned / expired. Mutually exclusive and exhaustive. Expiring is NOT a value here - it is a separate flag over valid, exposed as the expiring_files and expiring_staff metrics.',
        qualifications.area as area,
        qualifications.position as position,
        -- The fact carries the two name parts, not a full name, and dim_carer is
        -- deliberately absent as a table: it filters deleted is null while this
        -- fact keeps deleted carers, so joining it would drop their files from
        -- every figure. area and position come off the fact for the same reason.
        qualifications.surname as surname,
        qualifications.first_name as first_name,
        -- NOT EXPOSED, deliberately: `state` (the scope is baked into the metrics,
        -- so a state filter could only contradict them) and qualification_name
        -- (the fact's copy of hr_file_name, which the dimension above already
        -- carries).
        --
        -- Named for the expiry rather than reusing the other four views'
        -- calendar_date/year/month, because that is the only date this fact relates
        -- to and "in October" must not read as "recorded in October".
        dates.expiry_date as calendar_date,
        dates.expiry_year as year,
        dates.expiry_month as month_name
    )
    metrics (
        -- FILES are counted on the record id, never with count(*): null on the
        -- carer-holds-nothing rows, which count(distinct) drops for free.
        qualifications.total_hr_files as count(distinct case
            when {{ in_scope }} then qualifications.qualification_record_id
        end)
            comment = 'HR files held by active/pending carers. The report headline.',

        -- STAFF, not files: a carer with three expired files counts once. This is
        -- the continuity-report Carers trap without the trap - a plain global
        -- distinct, no aggregate of an aggregate, so it translates exactly.
        qualifications.non_compliant_staff as count(distinct case
            when {{ in_scope }} and qualifications.expire_status = 'expired'
                then qualifications.carer_key
        end)
            comment = 'Active/pending carers with at least one EXPIRED file. Staff, not files.',
        qualifications.expiring_staff as count(distinct case
            when {{ in_scope }} and qualifications.is_expiring
                then qualifications.carer_key
        end)
            comment = 'Active/pending carers with at least one file inside its own type alert window. Staff, not files. Still valid - not overdue.',

        -- The File Types / category split. The first three partition the files;
        -- expiring is a SUBSET of valid, so adding all four double counts.
        qualifications.valid_files as count_if({{ in_scope }} and qualifications.expire_status = 'valid'),
        qualifications.not_actioned_files as count_if({{ in_scope }} and qualifications.expire_status = 'not_actioned')
            comment = 'Files with neither an award date nor an expiry date. Zero under any expiry-date filter, since these have no expiry to filter on.',
        qualifications.expired_files as count_if({{ in_scope }} and qualifications.expire_status = 'expired'),
        qualifications.expiring_files as count_if({{ in_scope }} and qualifications.is_expiring)
            comment = 'Files still valid but inside their type alert window. A SUBSET of valid_files - never add it to valid + not_actioned + expired.',

        -- THE WINDOW IS FROZEN AT 30 DAYS AND IT IS IN THE NAME, same precedent as
        -- on_time_pct_15: a metric takes no runtime argument. The report uses a
        -- rolling 30 days rather than a calendar month; to offer the other, ADD
        -- renewed_files_last_calendar_month, never re-point this one.
        qualifications.renewed_files_30d as count_if(
            {{ in_scope }}
            and qualifications.is_renewal
            and qualifications.awarded >= dateadd('day', -30, current_date())
        )
            comment = 'Files awarded in the last 30 days that replaced an earlier file. Rolling 30 days, not a calendar month.',

        -- The drill-down columns. At file grain there is one value per row, so
        -- max/min return it; above that they answer "the worst case in this group",
        -- which is what the report's sorted tables show at the top.
        --
        -- Day 0 belongs to OVERDUE, not remaining: a file expiring today is
        -- expired, so it reads as 0 days overdue rather than 0 days left. The two
        -- boundaries below therefore mirror the expired <= today rule.
        qualifications.days_overdue as max(case
            when {{ in_scope }} and qualifications.days_to_expiry <= 0
                then -qualifications.days_to_expiry
        end)
            comment = 'Days past expiry, worst case in the group. 0 means it expires today, which counts as expired. Null when nothing in scope is overdue.',
        qualifications.days_remaining as min(case
            when {{ in_scope }} and qualifications.days_to_expiry > 0
                then qualifications.days_to_expiry
        end)
            comment = 'Days until the soonest expiry in the group, counting from tomorrow. Null when nothing in scope has a future expiry.'
    )
    -- No default grain to inherit: the report's headline figures are company-wide
    -- totals, and its breakdowns are the four dimensions named below.
    comment = 'HR compliance - one row per carer per HR file. DEFAULT GROUPING: none; the headline figures are company-wide totals, and the report breaks them down by area, position, HR file name and category. SCOPE: every metric covers ACTIVE and PENDING carers only, matching the report - a question about archived or deleted staff cannot be answered here. EXPIRED MEANS expireDate today or earlier, so a file expiring today already counts as expired and as 0 days overdue. The status columns are computed at the daily refresh, deliberately, so these figures equal the Power BI report between refreshes rather than being independently fresher. Expiring files are a SUBSET of valid files, not a fourth status. Filtering by expiry date excludes files that have no expiry date at all. COVERS EVERY CARE IN THE ACCOUNT - care1/care4 (R1), care2/care3/care5/beta (R2), alpha/alpha2 (R3), where the tenants are not named careN at all. An unfiltered answer totals across all of them, which is rarely what is meant: filter or group by source (the care) when the question is about one organisation, and always say which care the answer covers.'
    copy grants
{% endmacro %}


{#- ------------------------------------------------------------ workforce capacity -#}

{#- Staff supply against customer demand. The one view over TWO facts: the hours
    (report__workforce_capacity) and the headcount (report__workforce_movement)
    share the location and the date, and the report divides one by the other
    (Avg Contracted hrs per Customer), which only a view holding both can do.
    Every figure clears the bar for a semantic view: hours per week divide by the
    length of the range, utilisation is a ratio, and a headcount is a balance that
    must never be summed over days. The argument per measure is in
    docs/mcp_semantic_view_metrics.md. -#}

{% macro semantic_view_workforce_capacity() %}
    {#- Hours per week = hours x 7 / days in the range, one definition for every
        per-week metric below. The days are the distinct dates that hold a capacity
        row for the group, not DAX's COUNTROWS(DIM_DATE): a metric belongs to one
        table, and one on dates could not be grouped by location, which dates does
        not reach. The two agree wherever a contract runs, since contracted hours
        have a row on every day of the contract, 0 on its days off. -#}
    {%- set per_week = '* 7 / count(distinct capacity.calendar_date)' -%}
create or replace semantic view {{ semantic_view_name('workforce_capacity_sv') }}
    tables (
        capacity as {{ ref('report__workforce_capacity') }}
            comment = 'Workforce hours per day: contracted, available and scheduled hours of each carer at the location of the carer, and one demand row per location (customer contracted hours, unassigned hours, hours still booked to a carer who has left). Full history plus the outlook to the end of the third whole month from the build, every care in the account.',
        movement as {{ ref('report__workforce_movement') }}
            comment = 'Staff and customer headcount, joiners and leavers per location and day, history only up to the build date, every care in the account.',
        locations as {{ ref('report__dim_location') }}
            primary key (location_key)
            with synonyms ('location', 'branch', 'office'),
        dates as {{ ref('report__dim_date') }}
            primary key (calendar_date)
    )
    -- NO PRIMARY KEY ON THE TWO FACTS: nothing references them, and their grain
    -- includes area_id, which is null wherever the source holds the area as free
    -- text. location_key carries the care inside the value, see
    -- semantic_view_client_hours.
    relationships (
        capacity (location_key) references locations (location_key),
        capacity (calendar_date) references dates (calendar_date),
        movement (location_key) references locations (location_key),
        movement (calendar_date) references dates (calendar_date)
    )
    facts (
        capacity.contracted_hrs as contracted_hrs,
        capacity.available_hrs as available_hrs,
        capacity.scheduled_hrs as scheduled_hrs,
        capacity.unassigned_hrs as unassigned_hrs,
        capacity.inactive_carer_hrs as inactive_carer_hrs,
        capacity.customer_contracted_hrs as customer_contracted_hrs
        -- NO MOVEMENT FACTS, deliberately. active_staff and active_customers are
        -- end-of-day balances, and a fact is a column a caller may sum. The
        -- metrics below read the movement columns directly.
    )
    dimensions (
        -- Tenant, on the location rather than on a fact, because both facts reach
        -- it there. See the `source` dimension in semantic_view_client_hours for
        -- how to treat an unfiltered question.
        locations.source as source
            with synonyms ('care', 'tenant', 'source schema', 'instance', 'care database')
            comment = 'Tenant the row came from: care1/care4 (R1), care2/care3/care5/beta (R2), alpha/alpha2 (R3).',
        -- The report's Branch slicer. It is the LOCATION: the `branch` of the
        -- client hours view is a different, finer level (area, workgroup, branch).
        locations.location_name as location_name
            with synonyms ('location name', 'branch name')
            comment = 'Location name. The Workforce Capacity report labels it Branch.',
        locations.town as town,
        locations.county as county,
        -- NOT EXPOSED: the area (the facts carry area_id for the embedded report's
        -- TenantArea role, an id with no name to group by), the carer (the demand
        -- row's carer -1 matches no one, and dim_carer holds current carers only),
        -- and the job type: contracted and available hours carry none, so a job
        -- type filter would cut demand but not supply.
        dates.calendar_date as calendar_date,
        dates.year as year,
        dates.quarter as quarter_name,
        dates.month as month_name,
        dates.month_year as month_year_label,
        dates.iso_week as iso_week_label,
        -- The NON ADDITIVE BY dimension of the headcount metrics. Every documented
        -- example names a dimension of the metric's own table, so this is the
        -- movement row's own date rather than dates.calendar_date: the same value,
        -- on the rows the metric reads.
        movement.headcount_date as movement.calendar_date
            comment = 'Date of a headcount row. Picks the last day of a range for the headcount metrics; filter and group on calendar_date instead.'
    )
    metrics (
        -- Additive totals over the range. Every stored hours column gets one, plus
        -- booked: a sum of sums is still a sum.
        capacity.staff_contracted as sum(capacity.contracted_hrs)
            comment = 'Staff contracted hours in the range, in total. For a weekly figure use staff_contracted_per_week.',
        capacity.staff_available as sum(capacity.available_hrs)
            comment = 'Hours the staff offered as available, flexible hours included: the wider offer, not the capacity baseline, and nothing else is built on it. A company that records no availability reads 0.',
        capacity.scheduled as sum(capacity.scheduled_hrs)
            comment = 'Roster hours booked to an active care worker.',
        capacity.unassigned as sum(capacity.unassigned_hrs)
            comment = 'Roster hours booked to no one.',
        capacity.inactive_carer as sum(capacity.inactive_carer_hrs)
            comment = 'Roster hours still booked to a carer who is no longer an active care worker.',
        capacity.customer_contracted as sum(capacity.customer_contracted_hrs)
            comment = 'Customer contracted hours, the demand baseline.',
        capacity.booked as sum(capacity.scheduled_hrs) + sum(capacity.unassigned_hrs) + sum(capacity.inactive_carer_hrs)
            comment = 'Every booked hour: scheduled, unassigned, and still booked to a carer who has left. The last two still need a carer.',

        -- NON-ADDITIVE from here down. Hours per week divide by the days in the
        -- range, so a four-week and a six-month answer compare like for like, as
        -- the report's hrs/wk measures do. Never sum them.
        capacity.staff_contracted_per_week as sum(capacity.contracted_hrs) {{ per_week }}
            comment = 'Staff contracted hours per week over the range: the capacity baseline.',
        capacity.staff_available_per_week as sum(capacity.available_hrs) {{ per_week }},
        capacity.customer_contracted_per_week as sum(capacity.customer_contracted_hrs) {{ per_week }},
        capacity.scheduled_per_week as sum(capacity.scheduled_hrs) {{ per_week }},
        capacity.booked_per_week as (
            sum(capacity.scheduled_hrs) + sum(capacity.unassigned_hrs) + sum(capacity.inactive_carer_hrs)
        ) {{ per_week }},

        -- Contracted minus booked. Over the outlook it is the report's Projected
        -- Headroom: the outlook is only a date range, so it needs no metric of its own.
        capacity.headroom_per_week as (
            sum(capacity.contracted_hrs)
            - sum(capacity.scheduled_hrs)
            - sum(capacity.unassigned_hrs)
            - sum(capacity.inactive_carer_hrs)
        ) {{ per_week }}
            comment = 'Staff contracted minus booked hours per week. Over the three whole months after the current one this is the report Projected Headroom. Negative means demand exceeds contracted capacity.',

        -- DIVIDE() yields BLANK for a zero denominator, hence the gate with no else.
        capacity.capacity_utilisation_pct as case
            when sum(capacity.contracted_hrs) > 0
                then round(sum(capacity.scheduled_hrs) / sum(capacity.contracted_hrs) * 100, 2)
        end
            with synonyms ('utilisation', 'utilization', 'capacity utilisation')
            comment = 'Scheduled hours as a percentage of staff contracted hours. Above 100 means missing contracts, not overwork: carers with no recorded contract (zero-hour or bank staff) add scheduled hours but no contracted hours. Null when nothing is contracted.',

        -- SEMI-ADDITIVE: an end-of-day balance sums across locations but never
        -- across days, so a range answers with its LAST day, per group: every month
        -- of a trend shows its own last day, as DAX Active Staff does. A row series
        -- that stops before the end of the range stopped at 0 (the fact keeps the
        -- day of the last leaver), so its absence from the last day is correct.
        movement.staff_headcount non additive by (headcount_date)
            as sum(movement.active_staff)
            with synonyms ('active staff', 'active carers', 'staff count', 'headcount')
            comment = 'Care workers in the workforce at the end of the last day of the range that holds data (at most the build date).',
        movement.customer_headcount non additive by (headcount_date)
            as sum(movement.active_customers)
            with synonyms ('active customers', 'active clients', 'customer count')
            comment = 'Customers active at the end of the last day of the range that holds data (at most the build date).',

        movement.staff_joiners as sum(movement.staff_joined)
            comment = 'Care workers whose start date falls in the range.',
        movement.staff_leavers as sum(movement.staff_left)
            comment = 'Care workers moved out of Active in the range: Archived, or Pending (on hold). A reactivated carer reads as never having left.',
        movement.staff_net_change as sum(movement.staff_joined) - sum(movement.staff_left),
        movement.customer_joiners as sum(movement.customers_joined)
            comment = 'Customers whose start date (induction, else admission) falls in the range.',
        movement.customer_leavers as sum(movement.customers_left)
            comment = 'Customers moved out of Active in the range: Archived, or Pending (on hold).',
        movement.customer_net_change as sum(movement.customers_joined) - sum(movement.customers_left),

        -- DERIVED, across both facts: the report's Avg Contracted hrs per Customer,
        -- both halves over the caller's one range, as in DAX. Only a derived metric
        -- may combine two logical tables, and only a derived metric may read a
        -- semi-additive one.
        avg_contracted_per_customer as case
            when movement.customer_headcount > 0
                then capacity.customer_contracted_per_week / movement.customer_headcount
        end
            comment = 'Customer contracted hours per week divided by the customers active on the last day of the range. Use a past range: the headcount stops at the build date.'

        -- DELIBERATELY ABSENT.
        --
        -- Unfilled hrs/wk. DAX clips contracted - scheduled at zero PER CARER PER
        -- ISO WEEK and then sums: an aggregate of an aggregate, the shape of the
        -- continuity Carers measure, and a metric has no iterator over carer x
        -- week. The nearest expressible figure, the net gap, lets one carer's
        -- overtime fill another's empty contract and reads lower than the report.
        --
        -- Estimated Additional Customers. Headroom over the outlook divided by the
        -- average from the selected PAST period: two date ranges in one figure, and
        -- a metric sees one filter. The view comment gives the model the recipe
        -- instead, the same move as the continuity Year family.
        --
        -- Every (period) / (prior) / Δ measure: they rewrite the date filter. Two
        -- queries answer them.
    )
    -- The report's default period is stated here because a semantic view has no
    -- slicer: without a range the per-week metrics average the whole history plus
    -- the outlook, which nobody means.
    comment = 'Workforce capacity - staff supply against customer demand, per location and day. Hours: staff contracted, available and scheduled hours, customer contracted hours, and visits booked but unassigned or still booked to a carer who has left. Headcount: staff and customers active, joiners and leavers. DEFAULT GROUPING: none - the report shows totals for the selected locations; break down by location (the report calls it Branch) when asked. ALWAYS FILTER calendar_date. The report uses a rolling period ending yesterday, by default the last 6 months, and compares it with the period of the same length just before. If the question names no period, use the last 6 months ending yesterday and say so. A metric cannot compare two periods: query each range and compare. HOURS PER WEEK are normalised by the days in the range, so ranges of any length compare like for like; never add weekly figures together. HEADCOUNT is the count at the end of the last day of the range, never a sum over days. INCLUDES THE OUTLOOK: hours dated after today project the contracts, roster rules and customer contracts as they stand at the build, up to the end of the third whole month from now - a projection, not a forecast. For what has happened, end the range yesterday. Headcount, joiners and leavers stop at the build date. UTILISATION ABOVE 100% means missing contracts, not overwork. NOT AVAILABLE: unfilled capacity, and any service line or job type split. ESTIMATED ADDITIONAL CUSTOMERS, if asked: headroom_per_week over the three whole months after the current one, divided by avg_contracted_per_customer over the selected past period, rounded down, and 0 when the headroom is not positive. COVERS EVERY CARE IN THE ACCOUNT - care1/care4 (R1), care2/care3/care5/beta (R2), alpha/alpha2 (R3), where the tenants are not named careN at all. An unfiltered answer totals across all of them, which is rarely what is meant: filter or group by source (the care) when the question is about one organisation, and always say which care the answer covers.'
    copy grants
{% endmacro %}


{#- ------------------------------------------------------- plan & assessment dates -#}

{#- Plan & Assessment Dates: what is due for review, from the three tabs of the
    legacy page - care plans by review date, assessments by next assessment date,
    wounds by review date (docs/powerbi_plan_assessment_dates_setup.md). ONE view
    over the three lists, so a question can take plans, assessments and wounds
    together ("what is due next week"): they share the location and the due date,
    and assessments and wounds also share the client. It clears the bar
    (docs/mcp_semantic_view_metrics.md) because the naive counts are wrong in ways
    the result does not show:

      * A WOUND IS NOT A ROW. The skin table has a row per entry (the first
        assessment of a wound and each review), so count(*) counts entries. The
        page lists a wound once, when ANY of its entries is due in the window, and
        drops it when its latest entry is healed; wounds_due does both.
      * EVERY VERSION IS LISTED. The page lists superseded plan versions and
        assessments that a newer one of the same type replaced. The _latest
        metrics count the current one only; over a range ending yesterday they are
        the overdue figures the Power BI doc drafts, a definition the business has
        not confirmed yet.
      * PLANS ARE CLIENTS' AND CARERS'. Assessments and wounds are clients' only.

    The plans keep their own person dimensions: a plan can be a carer's and holds
    no client_key, so only assessments and wounds reach report__dim_client. A
    client-level question across all three lists therefore takes two queries. -#}

{% macro semantic_view_plan_assessment_dates() %}
create or replace semantic view {{ semantic_view_name('plan_assessment_dates_sv') }}
    tables (
        plans as {{ ref('report__plans_taken_report') }}
            primary key (plan_taken_key)
            with synonyms ('care plan', 'plan')
            comment = 'One row per plan started for a client or a carer, every version, full history, every care in the account. Due on its review date.',
        assessments as {{ ref('report__assessments_report') }}
            primary key (assessment_key)
            with synonyms ('assessment')
            comment = 'One row per assessment of a client, full history, every care in the account. Due on its next assessment date.',
        skin_assessments as {{ ref('report__skin_assessments_report') }}
            primary key (skin_assessment_key)
            with synonyms ('wound', 'skin assessment', 'wound assessment')
            comment = 'One row per entry of a client wound record - the first assessment of a wound or one of its reviews - full history. Due on the review date of the entry. Count wounds with the wound metrics, never rows.',
        clients as {{ ref('report__dim_client') }}
            primary key (client_key)
            with synonyms ('client', 'service user', 'resident'),
        locations as {{ ref('report__dim_location') }}
            primary key (location_key)
            with synonyms ('location', 'office'),
        dates as {{ ref('report__dim_date') }}
            primary key (calendar_date)
    )
    -- Every key and every reference carries `source` inside the *_key value, see
    -- semantic_view_client_hours. ONE dates table for three due dates: each list
    -- relates to it on its own date, so one due_date filter is the page's one window.
    relationships (
        plans (location_key) references locations (location_key),
        plans (review_date) references dates (calendar_date),
        assessments (location_key) references locations (location_key),
        assessments (next_assessment_date) references dates (calendar_date),
        assessments (client_key) references clients (client_key),
        skin_assessments (location_key) references locations (location_key),
        -- On the ENTRY's review date: the page lists a wound when any of its
        -- entries is due in the window, not only its latest.
        skin_assessments (review_date) references dates (calendar_date),
        skin_assessments (client_key) references clients (client_key)
    )
    dimensions (
        -- Tenant, on the location, which all three lists reach. See the `source`
        -- dimension in semantic_view_client_hours for how to treat an unfiltered
        -- question.
        locations.source as source
            with synonyms ('care', 'tenant', 'source schema', 'instance', 'care database')
            comment = 'Tenant the row came from: care1/care4 (R1), care2/care3/care5/beta (R2), alpha/alpha2 (R3).',
        -- THE LOCATION IS THE CARE OFFICE, not the branch, as in the all carers view.
        locations.location_name as location_name
            with synonyms ('location name', 'office')
            comment = 'Location (care office) of the plan, assessment or wound.',
        -- Named for the due date, as the qualification view names its dates for the
        -- expiry: "in October" means due in October, not recorded in October.
        dates.due_date as calendar_date
            with synonyms ('due date', 'review date', 'next assessment date')
            comment = 'The date a review is due: the review date of a plan, the next assessment date of an assessment, the review date of a wound entry.',
        dates.due_year as year,
        dates.due_month as month_year_label
            comment = 'Month of the due date, e.g. Oct 2026.',
        dates.due_week as iso_week_label
            comment = 'ISO week of the due date, e.g. 2026-W44.',
        -- THE CLIENT, for assessments and wounds only (see above). The state is
        -- built from state_id with the labels the lists use; the dimension's own
        -- status_label comes from the status lookup and is not the same thing.
        clients.client_name as full_name
            with synonyms ('client name', 'service user name')
            comment = 'Client of an assessment or a wound. For plans use person_name.',
        clients.client_state as case clients.state_id
            when 1 then 'Active'
            when 2 then 'Pending'
            when 3 then 'Archived'
        end
            comment = 'Active / Pending / Archived - the state of the client of an assessment or a wound. The legacy page shows Active by default. For plans use person_state.',
        clients.client_area as area_name
            comment = 'Area of the client of an assessment or a wound.',
        plans.person_type as person_type_label
            with synonyms ('client or carer')
            comment = 'Client or Carer - who the plan is for.',
        plans.person_name as full_name
            comment = 'The client or carer the plan is for.',
        plans.person_state as person_state
            comment = 'Active / Pending / Archived - the state of the client or carer the plan is for. The legacy page shows Active by default.',
        plans.person_area as area_name
            comment = 'Area of the client or carer the plan is for.',
        plans.plan_name as plan_template_name
            with synonyms ('plan name', 'care plan name')
            comment = 'Plan template name, shared by every version of a plan.',
        assessments.assessment_type as assessment_type_name
            with synonyms ('assessment name', 'assessment type')
            comment = 'Assessment type, by its current name.',
        skin_assessments.wound_name as wound_name
            comment = 'Name of the wound, from its latest entry - usually what and where it is.'
        -- NOT EXPOSED, deliberately: the assessment note and the wound entries'
        -- own names and dates (free text and row detail, which can hold health
        -- details); who started and completed a plan and when (the Plans Taken
        -- report's question, not this one); and the Work Group / Branch texts of
        -- every list (comma-joined names: an area in two workgroups reads "A, B",
        -- so grouping by them lists combinations).
    )
    metrics (
        -- AS THE PAGE LISTS THEM, under the due_date filter.
        plans.plans_due as count(plans.plan_taken_key)
            with synonyms ('plan reviews due', 'care plan reviews due')
            comment = 'Plans whose review date falls in the due_date range, completed or not, every version - as the legacy page lists them. Plans of clients and of carers: filter person_type.',
        plans.plans_due_not_completed as count_if(plans.is_completed = false)
            with synonyms ('plans not completed', 'pending plans')
            comment = 'Plans due in the range that nobody has completed yet, every version.',
        assessments.assessments_due as count(assessments.assessment_key)
            with synonyms ('assessments due')
            comment = 'Assessments whose next assessment date falls in the range, as the legacy page lists them - including ones that a newer assessment of the same type replaced.',
        -- WOUNDS, NOT ENTRIES: distinct on the wound, and only while its latest
        -- entry is not healed. Under a date filter a wound counts when any of its
        -- entries is due in the range, as on the page.
        skin_assessments.wounds_due as count(distinct case
            when skin_assessments.is_wound_healed = false then skin_assessments.wound_key
        end)
            with synonyms ('wound reviews due', 'skin assessments due')
            comment = 'Open wounds with a review due in the range: a wound counts once, when any of its entries has a review date in the range and its latest entry is not healed - as the legacy page lists them.',

        -- THE CURRENT ONE ONLY. Over a range ending yesterday these are the overdue
        -- figures of the Power BI doc: not on the page, and a draft definition the
        -- view comment tells the model to name as such.
        plans.plans_due_latest as count_if(plans.is_superseded = false)
            comment = 'Plans due in the range that are the latest version of the plan - no newer live version exists. Over a range ending yesterday: plans overdue for review (draft definition).',
        assessments.assessments_due_latest as count_if(assessments.is_latest_of_type = true)
            comment = 'Assessments due in the range that are the newest of their type for the client. Over a range ending yesterday: assessments overdue (draft definition).',
        -- The latest entry is one row per wound, so count_if counts wounds.
        skin_assessments.wounds_due_latest as count_if(
            skin_assessments.is_latest_entry = true and skin_assessments.is_wound_healed = false
        )
            with synonyms ('open wounds')
            comment = 'Open wounds whose current review date (that of the latest entry) falls in the range; with no due_date filter, every open wound. Over a range ending yesterday: wounds overdue for review (draft definition).',

        -- DERIVED, across the three lists: only a derived metric may combine logical
        -- tables. coalesce: a group with nothing due in one list has no value for
        -- it, and a NULL would blank the whole sum.
        reviews_due as coalesce(plans.plans_due, 0)
            + coalesce(assessments.assessments_due, 0)
            + coalesce(skin_assessments.wounds_due, 0)
            with synonyms ('reviews due', 'everything due')
            comment = 'Plans, assessments and wounds due in the range, added up, as the legacy page lists them.',
        reviews_due_latest as coalesce(plans.plans_due_latest, 0)
            + coalesce(assessments.assessments_due_latest, 0)
            + coalesce(skin_assessments.wounds_due_latest, 0)
            comment = 'The three _latest metrics added up. Over a range ending yesterday: everything overdue (draft definition).'

        -- DELIBERATELY ABSENT: Days To Review (a per-row display value; the due
        -- date is a dimension) and the state colours (formatting).
    )
    -- The page's window is stated because a semantic view has no slicer, and its
    -- Status default because "how many are due" means Active people on the page.
    comment = 'Plan & Assessment Dates - what is due for review, three lists: care plans of clients and carers (by review date), assessments of clients (by next assessment date) and wounds of clients (skin assessments, by review date). Full history, every person state. FILTER due_date for every question about what is due: the legacy page opens on the 14 days up to today; for what is coming up use today onwards, and always say which range the answer covers. DEFAULT STATE: a question that names no state means Active people - filter person_state (plans) and client_state (assessments, wounds) to Active and say so. LISTED vs LATEST: plans_due, assessments_due and wounds_due count what the legacy page lists, including superseded plan versions and assessments that a newer one of the same type replaced; the _latest metrics count the current one only (the latest plan version, the newest assessment of each type per client, a wound by its latest entry). OVERDUE is not on the legacy page: the _latest metrics over a range ending yesterday are a draft definition of it - say so when you use them. Many wounds are never marked healed, so overdue wounds include abandoned ones. reviews_due and reviews_due_latest add the three lists up. A WOUND COUNTS ONCE, never per entry, and a healed wound is never due. PLANS ARE OF CLIENTS AND CARERS: filter person_type for one kind; assessments and wounds are of clients only. DIMENSIONS: person_name, person_type, person_state, person_area and plan_name go with plan metrics only; client_name, client_state and client_area with assessment and wound metrics; assessment_type with assessment metrics; wound_name with wound metrics; location_name, source and the due date with every metric, so reviews_due breaks down by those alone. WOUND DATA exists only for the cares whose wound table is loaded (the R2 cares as of October 2026): elsewhere wound metrics are empty, not zero. COVERS EVERY CARE IN THE ACCOUNT - care1/care4 (R1), care2/care3/care5/beta (R2), alpha/alpha2 (R3), where the tenants are not named careN at all. An unfiltered answer totals across all of them, which is rarely what is meant: filter or group by source (the care) when the question is about one organisation, and always say which care the answer covers.'
    copy grants
{% endmacro %}


{#- ------------------------------------------------------------------- task review -#}

{#- Task Review: every scheduled task slot, the full history and the next 60 days,
    with what was recorded on it (docs/powerbi_task_review_setup.md), the port of
    the legacy Digital Task Review list. It clears the bar
    (docs/mcp_semantic_view_metrics.md) because the naive answer is wrong in three
    ways that the result does not show:

      * ROWS ARE RESULTS, NOT TASKS. A slot recorded twice, or marked Due and then
        Completed, has a row per result, so count(*) counts results. Every task
        metric counts only the rows flagged is_latest_for_slot: one per slot, by
        its latest result.
      * THE FUTURE. A slot after today is a forecast from the current schedule with
        nothing recorded; counted as "not recorded" it would read as a task left
        undone.
      * AN EMPTY SLOT IS NOT ALWAYS A FAILURE. Some locations schedule tasks and
        never record them in the app (in DEV care1 one location holds half of
        2024's empty slots), so a high not-recorded count can mean the location
        does not use digital task records. The app writes Missed for a slot nobody
        completed, which is the figure for tasks not done.

    It uses current_date() inside a metric and inside a dimension expression, and
    declares a fact table with no primary key: forms not yet run against Snowflake
    (see the header). -#}

{% macro semantic_view_task_review() %}
create or replace semantic view {{ semantic_view_name('task_review_sv') }}
    tables (
        -- NO PRIMARY KEY on the fact: its grain (source, schedule, time, date,
        -- result_number) holds two columns that are null by design (an "Any" slot
        -- has no time, a slot with nothing recorded no result_number), and nothing
        -- references it.
        tasks as {{ ref('report__task_review_report') }}
            with synonyms ('task', 'daily task', 'task sheet', 'task record')
            comment = 'One row per scheduled task slot per day per result recorded on it, full history plus the next 60 days, every care in the account. A slot with nothing recorded is one row with no status.',
        schedules as {{ ref('report__dim_task_schedule') }}
            primary key (task_schedule_key)
            with synonyms ('task schedule'),
        clients as {{ ref('report__dim_client') }}
            primary key (client_key)
            with synonyms ('client', 'service user', 'resident'),
        locations as {{ ref('report__dim_location') }}
            primary key (location_key)
            with synonyms ('location', 'office'),
        dates as {{ ref('report__dim_date') }}
            primary key (calendar_date)
    )
    -- Every key and every reference carries `source` inside the *_key value - see
    -- semantic_view_client_hours.
    relationships (
        tasks (task_schedule_key) references schedules (task_schedule_key),
        tasks (client_key) references clients (client_key),
        tasks (location_key) references locations (location_key),
        tasks (scheduled_date) references dates (calendar_date)
    )
    dimensions (
        -- Tenant the row came from - see the `source` dimension in
        -- semantic_view_client_hours for how to treat an unfiltered question.
        tasks.source as source
            with synonyms ('care', 'tenant', 'source schema', 'instance', 'care database')
            comment = 'Tenant the row came from: care1/care4 (R1), care2/care3/care5/beta (R2), alpha/alpha2 (R3).',
        clients.client_name as full_name with synonyms ('client name'),
        clients.client_no as client_no with synonyms ('social services ref', 'resident id'),
        clients.area as area_name,
        -- The fact keeps the history of clients who have left, so the client's
        -- state is the filter for "current clients". Built from state_id with the
        -- labels of the State slicer; status_label comes from the status lookup and
        -- is something else (see semantic_view_plan_assessment_dates).
        clients.client_state as case clients.state_id
            when 1 then 'Active'
            when 2 then 'Pending'
            when 3 then 'Archived'
        end
            comment = 'Active / Pending / Archived - the state of the client. Clients who have left keep their history here; filter to Active for current clients.',
        locations.location_name as location_name
            with synonyms ('location name', 'office')
            comment = 'Location (care office) of the task schedule. Not the branch.',
        schedules.task as task_name
            with synonyms ('task name', 'task type')
            comment = 'The task, as named in the app.',
        schedules.is_mandatory as is_mandatory
            comment = 'The schedule is flagged mandatory in the app.',
        schedules.schedule_pattern as schedule_pattern
            comment = 'How the schedule repeats: Once, Weekly: Mon, ..., Every N weeks: ..., Daily, Every N days.',
        tasks.task_time as assigned_time
            with synonyms ('time', 'scheduled time', 'assigned time')
            comment = 'Time of day the task is scheduled, HH:MM, or Any.',
        -- An empty slot reads "Not recorded" up to today and "Not due yet" after
        -- it, so a grouping by outcome never files a future slot under a failure.
        tasks.outcome as case
            when tasks.status_name is not null then tasks.status_name
            when tasks.is_recorded = true then 'No status'
            when tasks.scheduled_date > current_date() then 'Not due yet'
            else 'Not recorded'
        end
            with synonyms ('status', 'result')
            comment = 'What was recorded on the task: Completed, Partially Completed, Not Completed, Other, Missed, Due or Cancelled (or the name a company gave one of them); Not recorded when nothing was, Not due yet after today.',
        tasks.sub_status as sub_status_name
            with synonyms ('reason')
            comment = 'The reason recorded with the outcome.',
        tasks.recorded_by as recorded_by
            with synonyms ('carer', 'completed by', 'recorded by')
            comment = 'Who recorded the result, office staff and carers who have left included.',
        dates.calendar_date as calendar_date,
        dates.year as year,
        dates.month as month_name,
        dates.iso_week as iso_week_label
        -- NOT EXPOSED: the comment (free text, which can hold health details), the
        -- time recorded and result created stamps (row detail, not a grouping),
        -- and the Work Group / Branch texts (comma-joined names: an area in two
        -- workgroups reads "A, B", so grouping by them lists combinations).
    )
    metrics (
        -- ROWS ARE RESULTS, NOT TASKS: every task metric below counts only the rows
        -- flagged is_latest_for_slot, one per slot. Written `= true` / `= false`
        -- rather than as bare booleans, the unverified form (see the header).
        tasks.scheduled_tasks as count_if(tasks.is_latest_for_slot = true)
            with synonyms ('tasks', 'number of tasks', 'task slots')
            comment = 'Scheduled tasks, each slot counted once by its latest result, cancelled ones included. For the tasks due use expected_tasks.',
        tasks.expected_tasks as count_if(
            tasks.is_latest_for_slot = true
            and coalesce(tasks.status_id, 0) != 7
        )
            with synonyms ('tasks due', 'expected tasks')
            comment = 'Tasks due: scheduled and not cancelled. For the next week or month filter calendar_date to that window; dates after today are a forecast from the current schedule.',
        tasks.completed_tasks as count_if(tasks.is_latest_for_slot = true and tasks.status_id = 1)
            with synonyms ('tasks completed', 'tasks done')
            comment = 'Tasks whose latest result is Completed.',
        tasks.partially_completed_tasks as count_if(tasks.is_latest_for_slot = true and tasks.status_id = 3)
            comment = 'Tasks whose latest result is Partially Completed.',
        tasks.not_completed_tasks as count_if(tasks.is_latest_for_slot = true and tasks.status_id = 4)
            comment = 'Tasks whose latest result is Not Completed, recorded by a carer.',
        tasks.other_tasks as count_if(tasks.is_latest_for_slot = true and tasks.status_id = 2)
            comment = 'Tasks whose latest result is Other.',
        tasks.missed_tasks as count_if(tasks.is_latest_for_slot = true and tasks.status_id = 5)
            with synonyms ('tasks missed')
            comment = 'Tasks the app marked Missed: nobody completed them.',
        tasks.tasks_marked_due as count_if(tasks.is_latest_for_slot = true and tasks.status_id = 6)
            comment = 'Tasks whose latest result is the Due marker the app writes: no outcome recorded yet.',
        tasks.cancelled_tasks as count_if(tasks.is_latest_for_slot = true and tasks.status_id = 7)
            comment = 'Tasks cancelled, ahead of time or after.',
        tasks.not_recorded_tasks as count_if(
            tasks.is_latest_for_slot = true
            and tasks.is_recorded = false
            and tasks.scheduled_date <= current_date()
        )
            comment = 'Tasks due up to today with nothing recorded, not even Missed. Never counts a date after today. Some locations never record tasks in the app, so this can mean the location does not use digital task records.',
        tasks.results_recorded as count_if(tasks.is_recorded = true)
            comment = 'Results recorded, one per row as the legacy report lists them: a task recorded twice counts twice. For tasks use the task metrics.'

        -- DELIBERATELY ABSENT: % Completed. Its definition is still a draft
        -- (docs/powerbi_task_review_setup.md): whether Partially Completed counts,
        -- and whether today's slots not due yet do. completed_tasks and
        -- expected_tasks are both here.
    )
    comment = 'Task Review - every scheduled task (daily task sheet) per client per day with what was recorded on it, full history plus the next 60 days. ROWS ARE RESULTS: a task recorded twice has two rows, so count tasks only with the task metrics (scheduled_tasks, expected_tasks, completed_tasks, missed_tasks, not_recorded_tasks and the rest), never by counting rows. TASKS NOT DONE: missed_tasks counts what the app marked Missed; not_recorded_tasks counts slots with nothing at all, which in some locations means tasks are not recorded in the app, not that they were skipped - say so when it is large. For what is coming up use expected_tasks with calendar_date filtered to that window; dates after today are a forecast from the current schedule, rebuilt on every refresh, with nothing recorded yet. For what has happened filter calendar_date to today or earlier. DEFAULT GROUPING: per client, and per task for task questions; say which grouping you used. Clients who have left keep their history: filter client_state to Active for current clients. COVERS EVERY CARE IN THE ACCOUNT - care1/care4 (R1), care2/care3/care5/beta (R2), alpha/alpha2 (R3), where the tenants are not named careN at all. An unfiltered answer totals across all of them, which is rarely what is meant: filter or group by source (the care) when the question is about one organisation, and always say which care the answer covers.'
    copy grants
{% endmacro %}


{#- -------------------------------------------------------------------- all carers -#}

{#- The All Carers list. A list on its own does not clear the bar (birthday and
    anniversary stay out): one row per carer, and counting them is a count. What
    clears it is the breakdown people ask for, carers per branch, workgroup or
    tag. An area sits in several workgroups and a carer holds several tags, so
    those counts OVERLAP, and only a distinct count on the bridge gets each figure
    right; the job type group trap, on carers. A carer whose area is in no live
    workgroup counts in the totals but in no workgroup or branch figure.
    docs/mcp_semantic_view_metrics.md has the argument. -#}

{% macro semantic_view_all_carers() %}
create or replace semantic view {{ semantic_view_name('all_carers_sv') }}
    tables (
        carers as {{ ref('report__all_carers_report') }}
            primary key (carer_key)
            with synonyms ('carer', 'care worker', 'staff member', 'employee')
            comment = 'One row per Active, Pending or Archived care worker of a location, every care in the account. Current state only.',
        carer_workgroups as {{ ref('report__bridge_carer_workgroup') }}
            primary key (carer_key, workgroup_id, branch_id)
            comment = 'The workgroups and branches each carer belongs to through their area, one row per (carer, workgroup, branch). Many-to-many: an area can sit in several workgroups.',
        carer_tags as {{ ref('report__bridge_carer_tag') }}
            primary key (carer_key, tag_key)
            comment = 'The live tags of each carer, one row per (carer, tag). Many-to-many.',
        locations as {{ ref('report__dim_location') }}
            primary key (location_key)
            with synonyms ('location', 'office')
    )
    -- Every key and every reference carries `source` inside the *_key value, see
    -- semantic_view_client_hours. The bridges pair carer_key with a bare workgroup,
    -- branch or tag id, which is unique because carer_key already carries the care.
    -- No dates table: the list holds the current state, and its one date (the last
    -- status change) is hidden by default on the legacy page, so it stays out.
    relationships (
        -- THE BRIDGES ARE CHILDREN OF THE CARER: their metrics reach every carer
        -- dimension, but a metric on carers cannot reach theirs. A branch,
        -- workgroup or tag breakdown therefore needs the bridge metric, and the
        -- view comment says so.
        carer_workgroups (carer_key) references carers (carer_key),
        carer_tags (carer_key) references carers (carer_key),
        carers (location_key) references locations (location_key)
    )
    dimensions (
        -- Tenant the row came from, see the `source` dimension in
        -- semantic_view_client_hours for how to treat an unfiltered question.
        carers.source as source
            with synonyms ('care', 'tenant', 'source schema', 'instance', 'care database')
            comment = 'Tenant the row came from: care1/care4 (R1), care2/care3/care5/beta (R2), alpha/alpha2 (R3).',
        carers.carer_name as full_name with synonyms ('carer name'),
        carers.carer_no as carer_no with synonyms ('carer number', 'staff number'),
        carers.carer_state as state
            with synonyms ('state', 'lifecycle')
            comment = 'Active / Pending / Archived. Pending is on hold, Archived has left.',
        carers.carer_status as status
            with synonyms ('status', 'carer status')
            comment = 'The status the company assigned from its own list and the app-wide one. Not the same as state.',
        carers.area as area_name with synonyms ('area'),
        carers.county as county,
        -- THE LOCATION IS THE CARE OFFICE, and it does NOT get the synonym 'branch'
        -- the workforce view gives it: here branch is the cmLevelBranch grouping of
        -- workgroups inside a location, a different level.
        locations.location_name as location_name
            with synonyms ('location name', 'office')
            comment = 'Location (care office) the carer belongs to. Not the branch: branch_name groups workgroups inside a location.',
        carer_workgroups.workgroup_name as workgroup_name
            with synonyms ('workgroup', 'team')
            comment = 'Workgroup of the carer area. An area can sit in several workgroups, so a carer counts under each and workgroup figures overlap. Count with carers_by_workgroup.',
        carer_workgroups.branch_name as branch_name
            with synonyms ('branch')
            comment = 'Branch of those workgroups; blank for a workgroup with no live branch. Branch figures overlap for the same reason. Count with carers_by_workgroup.',
        carer_tags.tag as tag_name
            with synonyms ('tag', 'label')
            comment = 'A tag the carer holds. A carer can hold several, so tag figures overlap. Count with carers_by_tag.'
        -- NOT EXPOSED, deliberately: phone, email, address and post code (personal
        -- data with no grouping value, the rule of every view here); gender,
        -- nationality, transport type, pay cycle and the status change date (hidden
        -- by default on the legacy page, so hidden here too, decided 2026-10-23;
        -- area is hidden there as well but is the reason this view exists); the
        -- status comment (free text), known_as, and the private-note and
        -- future-status flags (icons on the list, not questions).
    )
    metrics (
        carers.carer_count as count(carers.carer_key)
            with synonyms ('number of carers')
            comment = 'Care workers on the list, every state unless state is filtered. Cannot be broken down by workgroup, branch or tag: use carers_by_workgroup or carers_by_tag.',
        carers.active_carers as count_if(carers.state = 'Active')
            with synonyms ('active carers')
            comment = 'Care workers in state Active now. For staff numbers over a period use workforce_capacity_sv.',
        -- DISTINCT on the bridge, never a row count: a carer whose area sits in two
        -- workgroups of one branch has two rows under that branch.
        carer_workgroups.carers_by_workgroup as count(distinct carer_workgroups.carer_key)
            comment = 'Care workers per workgroup or branch. Figures OVERLAP - a carer counts under every workgroup and branch of their area - so they sum to more than carer_count; never add them up.',
        carer_tags.carers_by_tag as count(distinct carer_tags.carer_key)
            comment = 'Care workers holding the tag. Figures OVERLAP - a carer counts under every tag they hold - so they sum to more than carer_count; never add them up.'
    )
    comment = 'All Carers - one row per care worker, Active, Pending or Archived, current state only, every carer of the location whatever their area. For staff numbers over time use workforce_capacity_sv. DEFAULT: a question about carers or staff that names no state means Active carers - use active_carers, or filter state to Active, and say so. BREAKDOWNS: by workgroup or branch use carers_by_workgroup, by tag carers_by_tag, filtering state to Active unless asked otherwise. Those figures overlap, and workgroup and branch figures leave out carers whose area is in no workgroup, so they never sum to the total; carer_count and active_carers cannot be broken down by them. Workgroup or branch and tag cannot be combined in one question. BRANCH IS NOT THE LOCATION: location_name is the care office, branch_name a grouping of workgroups inside it. NO DATES: the list is the current state, so it cannot answer when a carer joined, left or changed status. COVERS EVERY CARE IN THE ACCOUNT - care1/care4 (R1), care2/care3/care5/beta (R2), alpha/alpha2 (R3), where the tenants are not named careN at all. An unfiltered answer totals across all of them, which is rarely what is meant: filter or group by source (the care) when the question is about one organisation, and always say which care the answer covers.'
    copy grants
{% endmacro %}


{#- ------------------------------------------------------------------- all clients -#}

{#- The All Clients list, on the all carers argument (see above): what clears the
    bar is the breakdown, clients per branch, workgroup, tag or job type. An area
    sits in several workgroups, and a client holds several tags and several job
    types, so those counts OVERLAP and only a distinct count on the bridge gets
    each figure right. Like the carer list, it keeps every client, mapped to a
    workgroup or not, as the legacy page does; a client whose area is in no live
    workgroup counts in the totals but in no workgroup or branch figure.
    docs/mcp_semantic_view_metrics.md has the argument. -#}

{% macro semantic_view_all_clients() %}
create or replace semantic view {{ semantic_view_name('all_clients_sv') }}
    tables (
        clients as {{ ref('report__all_clients_report') }}
            primary key (client_key)
            with synonyms ('client', 'customer', 'service user', 'resident')
            comment = 'One row per Active, Pending or Archived client of a location, every care in the account. Current state only.',
        client_workgroups as {{ ref('report__bridge_client_workgroup') }}
            primary key (client_key, workgroup_id, branch_id)
            comment = 'The workgroups and branches each client belongs to through their area, one row per (client, workgroup, branch). Many-to-many: an area can sit in several workgroups.',
        client_tags as {{ ref('report__bridge_client_tag') }}
            primary key (client_key, tag_key)
            comment = 'The live tags of each client, one row per (client, tag). Many-to-many.',
        client_job_types as {{ ref('report__bridge_client_job_type') }}
            primary key (client_key, job_type_key)
            comment = 'The live job types of each client, one row per (client, job type). Many-to-many.',
        locations as {{ ref('report__dim_location') }}
            primary key (location_key)
            with synonyms ('location', 'office')
    )
    -- Keys as in semantic_view_all_carers: the bridges pair client_key with a bare
    -- workgroup or branch id, or a packed tag or job type key, unique because
    -- client_key already carries the care. No dates table: the list holds the
    -- current state, and its dates (status change, first contact, service
    -- commenced) are hidden by default on the legacy page, so they stay out.
    relationships (
        -- THE BRIDGES ARE CHILDREN OF THE CLIENT, as in the all carers view: a
        -- branch, workgroup, tag or job type breakdown needs the bridge metric.
        client_workgroups (client_key) references clients (client_key),
        client_tags (client_key) references clients (client_key),
        client_job_types (client_key) references clients (client_key),
        clients (location_key) references locations (location_key)
    )
    dimensions (
        -- Tenant the row came from, see the `source` dimension in
        -- semantic_view_client_hours for how to treat an unfiltered question.
        clients.source as source
            with synonyms ('care', 'tenant', 'source schema', 'instance', 'care database')
            comment = 'Tenant the row came from: care1/care4 (R1), care2/care3/care5/beta (R2), alpha/alpha2 (R3).',
        clients.client_name as full_name with synonyms ('client name', 'customer name'),
        clients.client_no as client_no with synonyms ('social services ref', 'resident id'),
        clients.client_state as state
            with synonyms ('state', 'lifecycle')
            comment = 'Active / Pending / Archived. Pending is on hold, Archived has left.',
        clients.client_status as status
            with synonyms ('status', 'client status')
            comment = 'The status the company assigned from its own list and the app-wide one. Not the same as state.',
        clients.area as area_name with synonyms ('area'),
        clients.county as county,
        -- THE LOCATION IS THE CARE OFFICE, not the branch, as in the all carers view.
        locations.location_name as location_name
            with synonyms ('location name', 'office')
            comment = 'Location (care office) the client belongs to. Not the branch: branch_name groups workgroups inside a location.',
        client_workgroups.workgroup_name as workgroup_name
            with synonyms ('workgroup', 'team')
            comment = 'Workgroup of the client area. An area can sit in several workgroups, so a client counts under each and workgroup figures overlap. Count with clients_by_workgroup.',
        client_workgroups.branch_name as branch_name
            with synonyms ('branch')
            comment = 'Branch of those workgroups; blank for a workgroup with no live branch. Branch figures overlap for the same reason. Count with clients_by_workgroup.',
        client_tags.tag as tag_name
            with synonyms ('tag', 'label')
            comment = 'A tag the client holds. A client can hold several, so tag figures overlap. Count with clients_by_tag.',
        client_job_types.job_type as job_type_name
            with synonyms ('job type', 'service type')
            comment = 'A job type in the client record. A client can have several, so job type figures overlap. Count with clients_by_job_type. Not the job type of a visit: for hours by job type use client_hours_sv.'
        -- NOT EXPOSED, deliberately: phone, email, address, post code and date of
        -- birth (personal data with no grouping value, the rule of every view
        -- here); gender, council id and the status change, first contact and
        -- service commenced dates (hidden by default on the legacy page, so hidden
        -- here too, the all carers rule of 2026-10-23); the status comment (free
        -- text) and the private-note, future-status and location-confirmed flags
        -- (icons on the list, not questions). Area and tags are hidden by default
        -- on the client page as well, but they are breakdowns this view exists
        -- for, as area is in the all carers view.
    )
    metrics (
        clients.client_count as count(clients.client_key)
            with synonyms ('number of clients', 'number of customers')
            comment = 'Clients on the list, every state unless state is filtered. Cannot be broken down by workgroup, branch, tag or job type: use clients_by_workgroup, clients_by_tag or clients_by_job_type.',
        clients.active_clients as count_if(clients.state = 'Active')
            with synonyms ('active clients', 'active customers')
            comment = 'Clients in state Active now. For customer numbers over a period use workforce_capacity_sv.',
        -- DISTINCT on the bridge, never a row count: a client whose area sits in two
        -- workgroups of one branch has two rows under that branch.
        client_workgroups.clients_by_workgroup as count(distinct client_workgroups.client_key)
            comment = 'Clients per workgroup or branch. Figures OVERLAP - a client counts under every workgroup and branch of their area - so they sum to more than client_count; never add them up.',
        client_tags.clients_by_tag as count(distinct client_tags.client_key)
            comment = 'Clients holding the tag. Figures OVERLAP - a client counts under every tag they hold - so they sum to more than client_count; never add them up.',
        client_job_types.clients_by_job_type as count(distinct client_job_types.client_key)
            comment = 'Clients with the job type in their record. Figures OVERLAP - a client counts under every job type they have - so they sum to more than client_count; never add them up.'
    )
    comment = 'All Clients - one row per client (customer, service user), Active, Pending or Archived, current state only, every client of the location whatever their area. For customer numbers over time use workforce_capacity_sv. DEFAULT: a question about clients or customers that names no state means Active clients - use active_clients, or filter state to Active, and say so. BREAKDOWNS: by workgroup or branch use clients_by_workgroup, by tag clients_by_tag, by job type clients_by_job_type, filtering state to Active unless asked otherwise. Those figures overlap, and workgroup and branch figures leave out clients whose area is in no workgroup, so they never sum to the total; client_count and active_clients cannot be broken down by them. Workgroup or branch, tag and job type cannot be combined in one question. JOB TYPE here is the job types listed on the client record, not the job type of visits or hours. BRANCH IS NOT THE LOCATION: location_name is the care office, branch_name a grouping of workgroups inside it. NO DATES: the list is the current state, so it cannot answer when a client started, left or changed status. COVERS EVERY CARE IN THE ACCOUNT - care1/care4 (R1), care2/care3/care5/beta (R2), alpha/alpha2 (R3), where the tenants are not named careN at all. An unfiltered answer totals across all of them, which is rarely what is meant: filter or group by source (the care) when the question is about one organisation, and always say which care the answer covers.'
    copy grants
{% endmacro %}
