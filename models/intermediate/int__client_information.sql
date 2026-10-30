-- Intermediate: Client Information dimension — one row per client, enriched with
-- demographics, billing, area/workgroup/branch, funder / care manager /
-- consultant contacts and the referral / status lookups. Ports the main client
-- query + getClientDetails() from the report.
--
-- Grain: source + client_id. ACCOUNT-WIDE: reads every care's staging at once
-- (macros/union_cares.sql). Client, contact, area, referral and status ids are
-- all allocated per care and collide across them, so the care joins every ON
-- clause AND every window PARTITION BY below — a qualify that partitions on
-- clientid alone would pick one contact for two different people.
--
-- Contacts by typeId: 8 = Funder, 10 = Care Manager, 32 = Consultant.
-- The PHP takes one contact per client ordered by invoiceeJobtype DESC and keeps
-- the last row iterated (= lowest invoiceeJobtype); replicated with a qualify
-- picking the lowest invoiceeJobtype.
--
-- CSO and Billing Code are the same value (clientDetails.billingCode) — the
-- report reads it twice but one join is enough.

with client_src as (
    {{ union_cares('client', 'staging') }}
),

client_details_src as (
    {{ union_cares('client_details', 'staging') }}
),

contacts_src as (
    {{ union_cares('contacts', 'staging') }}
),

area_src as (
    {{ union_cares('area', 'staging') }}
),

referral_reason_src as (
    {{ union_cares('referral_reason', 'staging') }}
),

referral_by_src as (
    {{ union_cares('referral_by', 'staging') }}
),

status_src as (
    {{ union_cares('status', 'staging') }}
),

client as (
    select
        source,
        id,
        companyid,
        residentid,
        fname,
        sname,
        area,
        currentaddress1,
        currenttown,
        currentcounty,
        postcode,
        phonehome,
        email,
        dob,
        sex,
        nhsnum,
        currentunit,
        hsecoordinator,
        councilid,
        state,
        location,
        deleted,
        created,
        inductiondate
    from client_src
),

client_details as (
    select
        source,
        clientid,
        companyid,
        locationid,
        billingcode,
        referralreason,
        referralby
    from client_details_src
    where clientid != 0
    qualify row_number() over (
        partition by source, clientid, companyid, locationid
        order by created desc nulls last, id desc
    ) = 1
),

contacts as (
    select
        source,
        clientid,
        fname,
        sname,
        typeid,
        invoiceejobtype
    from contacts_src
    where deleted is null
),

funder as (
    select
        source,
        clientid,
        fname,
        sname
    from contacts
    where typeid = 8
    qualify row_number() over (
        partition by source, clientid
        order by invoiceejobtype asc nulls last
    ) = 1
),

care_manager as (
    select
        source,
        clientid,
        fname,
        sname
    from contacts
    where typeid = 10
    qualify row_number() over (
        partition by source, clientid
        order by invoiceejobtype asc nulls last
    ) = 1
),

consultant as (
    select
        source,
        clientid,
        fname,
        sname
    from contacts
    where typeid = 32
    qualify row_number() over (
        partition by source, clientid
        order by invoiceejobtype asc nulls last
    ) = 1
),

area as (
    select
        source,
        id,
        name
    from area_src
),

area_hierarchy as (
    select
        source,
        area_id,
        workgroup_names,
        branch_names
    from {{ ref('int__area_hierarchy') }}
),

referral_reason as (
    select
        source,
        id,
        name
    from referral_reason_src
),

referral_by as (
    select
        source,
        id,
        referralbyname
    from referral_by_src
),

status as (
    select
        source,
        id,
        type
    from status_src
),

final as (
    select
        c.source,
        c.id as client_id,
        c.residentid as client_no,                              -- No. (front end id)
        c.fname as first_name,
        c.sname as surname,
        c.fname || ' ' || c.sname as full_name,
        try_to_number(c.area::varchar) as area_id,              -- branch RLS key
        a.name as area_name,                                    -- Area
        h.workgroup_names as workgroup,                         -- Workgroup
        h.branch_names as branch,                               -- Branch
        c.currentaddress1 as address,
        c.currenttown as town,
        c.currentcounty as county,
        c.postcode as post_code,
        c.phonehome as phone,
        c.email,
        c.dob as date_of_birth,
        c.sex,
        c.nhsnum as nhs_num,
        c.currentunit as unit_id,                              -- Unit Id
        d.billingcode as cso,                                  -- CSO (= billing code)
        d.billingcode as billing_code,                         -- Billing Code
        c.hsecoordinator as coordinator_zone,                  -- Coordinator/Zone
        c.councilid as council_id,                             -- Council Id
        rr.name as referral_reason,                            -- Referral Reason
        rb.referralbyname as referral_by,
        cm.fname || ' ' || cm.sname as care_manager,           -- Care Manager
        f.fname || ' ' || f.sname as funder,                   -- Funder
        con.fname || ' ' || con.sname as consultant,
        c.state as state_id,
        s.type as status_label,
        c.companyid as company_id,                              -- RLS key (with location_id)
        c.location as location_id,
        c.deleted,
        c.created,
        c.inductiondate as induction_date
    from client as c
    left join client_details as d
        on
            c.source = d.source
            and c.id = d.clientid
            and c.companyid = d.companyid
            and c.location = d.locationid
    left join funder as f
        on
            c.source = f.source
            and c.id = f.clientid
    left join care_manager as cm
        on
            c.source = cm.source
            and c.id = cm.clientid
    left join consultant as con
        on
            c.source = con.source
            and c.id = con.clientid
    -- numeric-FK joins wrapped in try_to_number: some source columns hold free
    -- text (e.g. client_details.referralby), so a non-numeric value yields no
    -- match (null) instead of a cast error — matching MySQL's loose comparison.
    left join area as a
        on
            c.source = a.source
            and try_to_number(c.area::varchar) = a.id
    left join area_hierarchy as h
        on
            c.source = h.source
            and try_to_number(c.area::varchar) = h.area_id
    left join referral_reason as rr
        on
            c.source = rr.source
            and try_to_number(d.referralreason::varchar) = rr.id
    left join referral_by as rb
        on
            c.source = rb.source
            and try_to_number(d.referralby::varchar) = rb.id
    left join status as s
        on
            c.source = s.source
            and try_to_number(c.state::varchar) = s.id
)

select * from final
