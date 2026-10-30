-- Intermediate: the live tags of each carer, one row per carer and tag. Ports the
-- Tags column and Tags filter of the All Carers page (carerTblTotalAll.php).
-- Feeds both the comma-joined Tags column of int__all_carers and
-- mart__bridge_carer_tag, so the two cannot disagree on which tags a carer has.
--
-- Grain: source + carer_id + tag_id. ACCOUNT-WIDE: reads every care's staging at
-- once (macros/union_cares.sql); carer and tag ids are allocated per care, so the
-- join carries the care.

with tag_pick_src as (
    {{ union_cares('tag_pick', 'staging') }}
),

tag_src as (
    {{ union_cares('tag', 'staging') }}
),

tag_pick as (
    select
        source,
        carerid,
        tagid
    from tag_pick_src
    where
        deleted is null
        and carerid is not null
),

tag as (
    select
        source,
        id,
        tag,
        color,
        tagcategoryid,
        carerside
    from tag_src
    where deleted is null
),

final as (
    -- distinct: a tag picked twice for the same carer is still one tag
    select distinct
        tp.source,
        tp.carerid as carer_id,
        t.id as tag_id,
        t.tag as tag_name,
        t.color as tag_color,
        t.tagcategoryid as tag_category_id,
        -- the Tags filter offers carer-side tags only; a carer can still carry
        -- another tag, which the column shows and the filter cannot offer
        coalesce(t.carerside = 1, false) as is_carer_tag
    from tag_pick as tp
    inner join tag as t
        on
            tp.source = t.source
            and tp.tagid = t.id
)

select * from final
