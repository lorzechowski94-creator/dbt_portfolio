with account_loc as (
    {{ union_cares('location', 'raw') }}
),

loc as (
    select
        source,
        id,
        companyid,
        deleted,
        'ANALYTICS__' || upper(source) || '_'
        || iff(companyid < 10, '0', '') || companyid::varchar as role_stem
    from account_loc
),

multi_location_company as (
    select
        source,
        companyid
    from loc
    group by source, companyid
    having count(distinct id) >= 2
),

company_wide as (
    select
        role_stem || '_READER' as role_name,
        source,
        companyid as company_id,
        id as location_id,
        deleted is null as is_active,
        true as is_company_wide
    from loc
),

location_only as (
    select
        l.role_stem || '_L' || l.id::varchar || '_READER' as role_name,
        l.source,
        l.companyid as company_id,
        l.id as location_id,
        l.deleted is null as is_active,
        false as is_company_wide
    from loc as l
    inner join multi_location_company as mlc
        on
            l.source = mlc.source
            and l.companyid = mlc.companyid
),

-- one row per (group role, company); the yml says when to add one
company_group as (
    select * from (
        values
        ('ANALYTICS__CARE2_120_124_READER', 'care2', 120),
        ('ANALYTICS__CARE2_120_124_READER', 'care2', 124)
    ) as v (role_name, source, companyid)
),

company_group_rows as (
    select
        g.role_name,
        l.source,
        l.companyid as company_id,
        l.id as location_id,
        l.deleted is null as is_active,
        true as is_company_wide
    from loc as l
    inner join company_group as g
        on
            l.source = g.source
            and l.companyid = g.companyid
)

select * from company_wide
union all
select * from location_only
union all
select * from company_group_rows
