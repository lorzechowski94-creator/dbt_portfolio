-- Intermediate: the live tags of each client, one row per client and tag. Ports
-- the Tags column and Tags filter of the All Clients page
-- (clientsTotalAllTableBc.php). Feeds both the comma-joined Tags column of
-- int__all_clients and mart__bridge_client_tag, so the two cannot disagree on
-- which tags a client has.
--
-- Grain: source + client_id + tag_id. ACCOUNT-WIDE: reads every care's staging
-- at once (macros/union_cares.sql); client and tag ids are allocated per care, so
-- the join carries the care.

with tag_pick_src as (
    {{ union_cares('tag_pick', 'staging') }}
),

tag_src as (
    {{ union_cares('tag', 'staging') }}
),

tag_pick as (
    select
        source,
        clientid,
        tagid
    from tag_pick_src
    where
        deleted is null
        and clientid is not null
),

tag as (
    select
        source,
        id,
        tag,
        color,
        tagcategoryid,
        clientside
    from tag_src
    where deleted is null
),

final as (
    -- distinct: a tag picked twice for the same client is still one tag
    select distinct
        tp.source,
        tp.clientid as client_id,
        t.id as tag_id,
        t.tag as tag_name,
        t.color as tag_color,
        t.tagcategoryid as tag_category_id,
        -- the Tags filter offers client-side tags only; a client can still carry
        -- another tag, which the column shows and the filter cannot offer
        coalesce(t.clientside = 1, false) as is_client_tag
    from tag_pick as tp
    inner join tag as t
        on
            tp.source = t.source
            and tp.tagid = t.id
)

select * from final
