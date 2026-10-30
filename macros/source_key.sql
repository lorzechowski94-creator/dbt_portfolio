{#
    The composite key a POWER BI relationship joins on: the tenant and the id packed
    into ONE INTEGER, source_code * 10^12 + id (source_code: macros/source_topology.sql).
    care1's client 31185 is 1000000031185.

    WHY IT EXISTS AT ALL. Client, carer, job type and group ids are allocated per
    care (separate MySQL databases) and collide across them, so every relationship
    needs care + the id. A Power BI relationship takes exactly ONE column and
    refuses a duplicate value on the "one" side — relating on the bare id is not
    merely wrong, it is rejected at dataset load.

    SNOWFLAKE HAS NO SUCH LIMIT, AND USES THESE KEYS ANYWAY.
    macros/create_semantic_views.sql could declare `(source, client_id)` natively and
    once did. It keys on client_key instead for a different reason than Power BI's:
    the tenant is part of the VALUE, so a later edit cannot drop `source` from a
    reference and silently join one tenant's hours to another tenant's client. The
    old design guarded that by hand, in a comment. This one makes it unavailable.

    Where a grain has no surrogate key — schedule_difference (recurr_id) and the
    qualification record — the semantic views still key natively on (source, id).
    That is not an oversight; those ids feed no Power BI relationship, so no key
    was ever built for them.

    WHY IT IS A MACRO. The formula appears on both sides of every relationship —
    once on the dimension, once on each fact that relates to it, some two dozen
    call sites in all. Both sides must produce the SAME value or the relationship
    matches nothing, and Power BI reports that as blank dimension values rather
    than as an error. Two dozen hand-written copies is exactly the shape that
    drifts.

    WHY AN INTEGER. Until 2026-09 the key was the string care || '|' || id. Power BI
    stores a string column as a dictionary of its distinct values, so the text keys
    cost far more memory than their information, on both sides of every
    relationship; an integer is 8 bytes and joins faster, in VertiPaq and in
    Snowflake alike. mart__schedule_difference_report.occurrence_key follows the same
    idea with its own layout.

    THE ::int CAST STILL MATTERS. Id columns arrive with different declared scales
    (job_type_id once came through as 988.00000), and the cast pins the key to the
    id's whole value regardless of how any one relation declares its NUMBER.

    LIMITS. Ids must stay below 10^12, which no source table comes near. Keys stay
    below 2^53, so even a tool that reads them as doubles gets them exactly.

    Sentinels pass through: job_type_id / carer_id use -1 for "none at source", so
    the key is source_code * 10^12 - 1. It matches no dimension row and lands on
    Power BI's blank member exactly as the bare -1 did. It cannot meet a real key,
    which would take an id of 999,999,999,999 in the care numbered one lower. A NULL
    id gives a NULL key, as the string did.

        select
            {{ source_key('c.source', 'c.id') }} as carer_key,
            ...

    Pass the columns already qualified as the surrounding query needs them; this
    macro adds no aliases of its own.
#}
{% macro source_key(source_col, id_col) %}({{ source_code(source_col) }} * 1000000000000 + {{ id_col }}::int)::bigint{% endmacro %}
