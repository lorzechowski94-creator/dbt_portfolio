-- Intermediate: the job types of each client, one row per client and job type.
-- Resolves client.jobTypes, a comma-separated list of jobtype ids, for the Job
-- Type column and Job Type search of the All Clients page
-- (clientsTotalAllTableBc.php). Feeds the comma-joined Job Type column of
-- int__all_clients (every job type, in list order, as the page shows them) and
-- mart__bridge_client_job_type (live job types only, as the page's search offers).
--
-- Grain: source + client_id + job_type_id. ACCOUNT-WIDE: reads every care's
-- staging at once (macros/union_cares.sql); client and job type ids are allocated
-- per care, so the join carries the care.

with client_src as (
    {{ union_cares('client', 'staging') }}
),

jobtype_src as (
    {{ union_cares('jobtype', 'staging') }}
),

client as (
    select
        source,
        id,
        jobtypes
    from client_src
    where
        jobtypes is not null
        and trim(jobtypes) != ''
),

jobtype as (
    select
        source,
        id,
        name,
        deleted
    from jobtype_src
),

tokens as (
    -- tokens are try_cast so a stray non-numeric entry is dropped instead of
    -- failing the build
    select
        c.source,
        c.id as client_id,
        try_cast(trim(t.value) as number) as job_type_id,
        t.index as list_position
    from client as c,
        lateral split_to_table(c.jobtypes, ',') as t
),

exploded as (
    -- one row per job type, at its first place in the list: a list may repeat an id
    select
        source,
        client_id,
        job_type_id,
        min(list_position) as list_position
    from tokens
    where job_type_id is not null
    group by source, client_id, job_type_id
),

final as (
    -- an id with no jobtype row is dropped: there is no name to show
    select
        e.source,
        e.client_id,
        e.job_type_id,
        j.name as job_type_name,
        e.list_position,
        j.deleted is null as is_live_job_type
    from exploded as e
    inner join jobtype as j
        on
            e.source = j.source
            and e.job_type_id = j.id
)

select * from final
