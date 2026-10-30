-- Intermediate: Carer Qualification Export — one row per carer × qualification
-- record. Ports carerQualificationExport.php (carer list + qualifications per
-- carer + modified-by / state name lookups). A carer with three qualifications
-- produces three rows; a carer with none still appears once (LEFT JOIN) with null
-- qualification columns.
--
-- Grain: source + carer_id + qualification record. ACCOUNT-WIDE: reads every care's
-- staging at once (macros/union_cares.sql). Carer, position, qualification, state
-- and area ids are all allocated per care and collide across them, so every join
-- below carries the care.
--
-- Notes:
--  * permissionId = 4 keeps carers only (matches the PHP).
--  * carer.deleted is NOT filtered — all carers regardless of deleted status.
--  * q.deleted IS NULL excludes deleted qualification records; the qualification
--    TYPE deleted flag is kept, NOT filtered on, and surfaced as the boolean
--    is_type_deleted so the front end can render retired types in red (per the
--    output-column spec). Retired HR file types are never hidden anywhere in this
--    lineage: an audit can look back years, so history against a type the company
--    has since dropped must stay visible and be MARKED, not filtered away.
--  * File Uploaded = any row in cmMultipleQualifications for the record (newer
--    multi-file mechanism) OR the legacy single file (fileName not empty).
--  * State name comes from the `state` lookup (carer.state -> state.id ->
--    state.name); state 3 -> 'Archived'.
--  * qualification_type_id is the HR File key -> mart__dim_hrfile (the "HR File"
--    filter of the PHP form); -1 means the carer holds no qualification record at
--    all (the LEFT JOIN row). The category -> HR File Type label lives in that
--    dimension only, so the mapping has a single definition.

with carer_src as (
    {{ union_cares('carer', 'staging') }}
),

positions_src as (
    {{ union_cares('cm_employee_positions', 'staging') }}
),

qualification_type_src as (
    {{ union_cares('cm_qualifications_type', 'staging') }}
),

multiple_files_src as (
    {{ union_cares('cm_multiple_qualifications', 'staging') }}
),

qualifications_src as (
    {{ union_cares('cm_qualifications', 'staging') }}
),

state_src as (
    {{ union_cares('state', 'staging') }}
),

area_src as (
    {{ union_cares('area', 'staging') }}
),

carer as (
    select
        source,
        id,
        carerid,
        fname,
        sname,
        position,
        address1,
        town,
        county,
        postcode,
        phone,
        email,
        dob,
        startdate,
        area,
        state,
        companyid,
        location,
        permissionid
    from carer_src
    where permissionid = 4
),

positions as (
    select
        source,
        id,
        name
    from positions_src
),

qualification_type as (
    -- name + deleted flag + alert window; the category label is the dimension's
    -- job (mart__dim_hrfile), reached from the fact via qualification_type_id.
    -- alertBefore is text such as '4 week' (macros/alert_before.sql).
    select
        source,
        id,
        name,
        deleted,
        {{ alert_before_value('alertbefore') }} as alert_before_value,
        {{ alert_before_unit('alertbefore') }} as alert_before_unit
    from qualification_type_src
),

multiple_files as (
    -- newer multi-file mechanism: one row per attached file on a qualification
    -- record. Join key follows the doc (cmQualificationsId). Soft-deleted
    -- attachments (deleted timestamp set) are excluded so they don't count.
    select
        source,
        cmqualificationsid,
        count(*) as multiple_count
    from multiple_files_src
    where deleted is null
    group by source, cmqualificationsid
),

qualifications as (
    select
        q.source,
        q.id as qualification_record_id,
        q.carerid,
        q.qualificationid,
        q.awarddate as award_date,
        q.expiredate as expire_date,
        q.modifiedby,
        q.filename,
        q.comment,
        q.multiple,
        -- days until expiry as of the build date; 0 => expires today (which is
        -- already expired, see expire_status), negative => overdue
        datediff('day', current_date(), q.expiredate) as days_to_expiry,
        -- The file's status: not_actioned / expired / valid. ONE column serving
        -- both the flat export (its searchable keyword) and the compliance
        -- dashboard (its valid/not-actioned/expired split) — they want the same
        -- three values on the same boundary, so a second status column would only
        -- be a copy to keep in step.
        --
        -- Computed in this CTE rather than in final on purpose: the LEFT JOIN then
        -- gives the "carer holds no file" row a null status for free, instead of a
        -- guard on the record id. A carer with no file has nothing to action, so it
        -- must NOT read as 'not_actioned'.
        --
        -- Expired is <=, i.e. a file expiring TODAY is expired.
        case
            when q.awarddate is not null and q.expiredate is null then 'valid'
            when q.awarddate is null and q.expiredate is null then 'not_actioned'
            when q.expiredate <= current_date() then 'expired'
            else 'valid'
        end as expire_status,
        t.name as qualification_name,
        t.deleted as type_deleted,
        -- first day of the type's alert window; null when it has none
        {{ alert_window_start('q.expiredate', 't.alert_before_value', 't.alert_before_unit') }}
            as alert_from,
        coalesce(mf.multiple_count, 0) as multiple_count
    from qualifications_src as q
    left join qualification_type as t
        on
            q.source = t.source
            and q.qualificationid = t.id
    left join multiple_files as mf
        on
            q.source = mf.source
            and q.id = mf.cmqualificationsid
    where q.deleted is null
),

carer_state as (
    select
        source,
        id,
        name
    from state_src
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

modifier as (
    select
        source,
        id,
        fname || ' ' || sname as modifier_name
    from carer_src
),

final as (
    select
        c.source,
        c.id as carer_id,
        c.carerid as carer_no,                                  -- No. (front-end id)
        c.fname as first_name,
        c.sname as surname,
        p.name as position,                                     -- cmEmployeePositions.name
        c.address1 as address,
        c.town,
        c.county,
        c.postcode as post_code,
        c.phone,
        c.email,
        c.dob as date_of_birth,
        -- the qualification record itself (null on the no-record LEFT JOIN row):
        -- the only safe key for counting FILES, since counting rows would count
        -- those carer-with-no-file rows too
        q.qualification_record_id,
        -- HR File key -> mart__dim_hrfile; -1 = no qualification record
        coalesce(q.qualificationid, -1) as qualification_type_id,
        q.qualification_name,                                   -- cmQualificationsType.name
        -- true => the company has retired this HR file type; the row still shows
        -- (audit history), the front end renders it in red
        q.type_deleted is not null as is_type_deleted,
        q.award_date as awarded,
        q.expire_date as expired,
        -- null here exactly when the carer holds no file (the LEFT JOIN below)
        q.expire_status,
        q.days_to_expiry,
        -- still valid but inside its type's alert window: an overlay on
        -- expire_status = 'valid', not a fourth state. The window runs from
        -- alert_from to the day before expiry, because the expiry date itself is
        -- already 'expired'. Types with no alertBefore never flag, hence the
        -- coalesce over a null.
        coalesce(
            (q.expire_date > current_date() and current_date() >= q.alert_from), false
        ) as is_expiring,
        -- cmQualifications.multiple = 1 marks a record that replaced an earlier
        -- file; with awarded it gives the "renewed" counts
        coalesce((q.multiple = 1), false) as is_renewal,
        c.startdate as start_date,
        case when c.state = 3 then 'Archived' else st.name end as state,
        try_to_number(c.state::varchar) as state_id,
        try_to_number(c.area::varchar) as area_id,              -- branch RLS key
        a.name as area,
        h.branch_names as branch,
        h.workgroup_names as workgroup,
        m.modifier_name as modified_by,                         -- carer name of q.modifiedBy
        case
            when
                q.multiple_count > 0
                or (q.filename is not null and q.filename != '') then 'Yes'
            else 'No'
        end as file_uploaded,
        q.comment as comments,
        c.companyid as company_id,                              -- RLS key (with location_id)
        c.location as location_id
    from carer as c
    left join qualifications as q
        on
            c.source = q.source
            and c.id = q.carerid
    -- numeric-FK joins wrapped in try_to_number: some source columns hold free
    -- text, so a non-numeric value yields no match (null) instead of a cast error.
    left join positions as p
        on
            c.source = p.source
            and try_to_number(c.position::varchar) = p.id
    left join carer_state as st
        on
            c.source = st.source
            and try_to_number(c.state::varchar) = st.id
    left join area as a
        on
            c.source = a.source
            and try_to_number(c.area::varchar) = a.id
    left join area_hierarchy as h
        on
            c.source = h.source
            and try_to_number(c.area::varchar) = h.area_id
    left join modifier as m
        on
            c.source = m.source
            and try_to_number(q.modifiedby::varchar) = m.id
)

select * from final
