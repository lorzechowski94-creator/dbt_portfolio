{#
    Every configured alert window must read as a count and a unit
    (macros/alert_before.sql). One that does not gives its type no window, and the
    type's files then never flag as expiring, with no error anywhere. One row per HR
    file type whose alertBefore is set but did not parse.

    Warn, not error: the value is free text typed in the app, so a new spelling
    should surface on the next build without blocking the deploy.
#}
{{ config(severity='warn') }}

select
    source,
    qualification_type_id,
    hr_file_name,
    alert_before
from {{ ref('mart__dim_hrfile') }}
where
    alert_before is not null
    and alert_before_unit is null
