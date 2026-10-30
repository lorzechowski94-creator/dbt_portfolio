-- Mart (BRIDGE): carer <-> tag, one row per carer of mart__all_carers_report and
-- each of their live tags. Serves the Tags slicer ("has any of the selected
-- tags"); the comma-joined Tags column is already on the carer row.
--
-- Grain: source + carer_id + tag_id. Restricted to the carers of the report
-- table (inner join), so every row finds its carer in Power BI; the RLS keys
-- come from that carer, who owns the row.

with carer_tags as (
    select
        source,
        carer_id,
        tag_id,
        tag_name,
        tag_color,
        tag_category_id,
        is_carer_tag
    from {{ ref('int__carer_tags') }}
),

carers as (
    select
        source,
        carer_id,
        carer_key,
        company_id,
        location_id
    from {{ ref('mart__all_carers_report') }}
),

final as (
    select
        ct.source,
        ct.carer_id,
        c.carer_key,
        ct.tag_id,
        {{ source_key('ct.source', 'ct.tag_id') }} as tag_key,
        ct.tag_name,
        ct.tag_color,
        ct.tag_category_id,
        ct.is_carer_tag,
        c.company_id,
        c.location_id
    from carer_tags as ct
    inner join carers as c
        on
            ct.source = c.source
            and ct.carer_id = c.carer_id
)

select * from final
