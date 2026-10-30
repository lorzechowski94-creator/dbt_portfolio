-- Mart (DIMENSION): one row per client — demographics, area/workgroup/branch,
-- funder / care manager, referral, status, billing. Relate to
-- mart__client_hours_report on client_key in Power BI.
--
-- Grain: source + client_id. client.id is allocated per care, so the same id is a
-- different person in another care — client_key carries both, and is the column
-- every relationship uses.
--
-- service_commencement = client.inductionDate.
-- first_scheduled_event = earliest timesheet logDate ever for the client
-- (client-level attribute, independent of the report date filter).

with dim as (
    select * from {{ ref('int__client_information') }}
),

-- Read straight from staging, across every care in the account: there is no
-- intermediate between this mart and the timesheet table, so the union happens
-- here (macros/union_cares.sql).
timesheet as (
    {{ union_cares('timesheet', 'staging') }}
),

first_timesheet as (
    select
        source,
        clientid as client_id,
        min(logdate) as first_scheduled_event
    from timesheet
    group by 1, 2
),

final as (
    select
        dim.source,
        dim.client_id,
        {{ source_key('dim.source', 'dim.client_id') }} as client_key,
        dim.client_no,
        dim.first_name,
        dim.surname,
        dim.full_name,
        dim.area_id,
        dim.area_name,
        dim.address,
        dim.town,
        dim.county,
        dim.post_code,
        dim.phone,
        dim.email,
        dim.date_of_birth,
        dim.induction_date as service_commencement,
        ft.first_scheduled_event,
        dim.cso,
        dim.workgroup,
        dim.branch,
        dim.coordinator_zone,
        dim.billing_code,
        dim.referral_reason,
        dim.unit_id,
        dim.council_id,
        dim.care_manager,
        dim.funder,
        dim.state_id,
        dim.status_label,
        dim.company_id,
        dim.location_id
    from dim
    left join first_timesheet as ft
        on
            dim.source = ft.source
            and dim.client_id = ft.client_id
)

select * from final
