{{ config(alias='timesheet') }}
select s.* {{ exclude_internal('timesheet') }}
from {{ source('raw_app', 'timesheet') }} as s
where {{ customer_access_filter() }}
