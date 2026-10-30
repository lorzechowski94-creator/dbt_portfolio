-- Intermediate: one row per calendar date across the full report history, up to
-- and including the projection horizon (the end of the third whole month from
-- today, macros/projection_horizon.sql). Drives the set-based recurrence expansion
-- by cross join.
--
-- No date vars: the spine is generated from a fixed early anchor and capped at the
-- horizon, so the calendar always ends three whole months ahead and covers all
-- historical data. The hours reports read it through models that clamp themselves
-- to their own, shorter horizon (macros/report_horizon.sql).

with spine as (
    select dateadd(day, seq4(), '2000-01-01'::date) as calendar_date
    from table(generator(rowcount => 20000))  -- ~year 2054; filtered to the horizon below
)

select calendar_date
from spine
where calendar_date <= {{ projection_horizon() }}
