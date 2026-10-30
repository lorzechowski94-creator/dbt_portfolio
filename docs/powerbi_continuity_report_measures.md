# Continuity of Care Report — Power BI setup

## Star schema

The embedded model imports these tables under the same names from
**`ANALYTICS_MART.CARE_MANAGEMENT`**, not from the `REPORT` secure views. The mart
tables hold every customer in the account. Tenant isolation is the model's `Tenant`
role, keyed on the company id in the embed token: see
[powerbi_embedded_setup.md](powerbi_embedded_setup.md). The `REPORT` views filter
on `current_role()`, which cannot tell customers apart when every embedded query
runs as one service principal.

| Role | Model | Physical name (care1 on DEV) | Grain |
|---|---|---|---|
| Fact | `report__continuity_report` | `ANALYTICS_MART.REPORT.CONTINUITY_REPORT` | `client_key` + `service_date` + `carer_key` |
| Dim client | `report__dim_client` | `…REPORT.DIM_CLIENT` | `client_id` |
| Dim carer | `report__dim_carer` | `…REPORT.DIM_CARER` | `carer_id` |
| Dim date | `report__dim_date` | `…REPORT.DIM_DATE` | `calendar_date` |

**ONE relation per ACCOUNT, and the names carry no care token.** Every care in the
account is stacked into the same table, with a `source` column saying which source
schema each row came from (`macros/union_cares.sql`); the names above are the real
ones in every account. The per-care `CARE1_` / `CARE2_` … relations this report
used to connect to are gone — repoint the model at the bare names.

**`source` is part of every relationship and of the fact's grain.** Client, carer and
job type ids are allocated per care and collide across them, so a relationship on
`client_id` alone would join care2's client 8842 to care3's — and Power BI refuses
the relationship outright, because the duplicate id breaks the "one" side. Carer
6410 exists in more than one R2 care, which is exactly the error this used to
produce at dataset load.

The warehouse ships the composite key ready-made, as one integer (care and id,
`macros/source_key.sql`; Whole number / int64 in Power BI, on both sides): the fact
carries `client_key` and `carer_key`, `dim_client` carries `client_key` and
`dim_carer` carries `carer_key`. Relate on those; no calculated column is needed,
and the bare ids should stay out of every relationship.

`dim_date` needs no key — the calendar is shared and carries no care. There is no
slicer on `source`: the `Tenant` role already limits a token to one source and one
company (see [powerbi_embedded_setup.md](powerbi_embedded_setup.md)).

The fact is all dates and additive only, and serves BOTH halves of the report — the
Year columns and the Period columns — see [Year vs Period](#year-vs-period).
`dim_client` supplies Client Name, Social Services Ref, Area and Branch;
`dim_carer` is optional, only needed if the report ever drills into who the carers
were.

**Mark `dim_date` as the model's Date table.** It runs 2000-01-01 → 31 Dec of the
current year, so calendar years are complete, which the Year measures below depend
on. Do not substitute a native PBI auto-calendar: the Year measures filter its
`year` column. It is the one report view with no RLS predicate — a calendar carries
no customer data, see `report__dim_date.sql`.

## Relationships
- `continuity_report[client_key]` → `dim_client[client_key]` (many-to-one) — the
  warehouse column above, NOT the bare `client_id`
- `continuity_report[service_date]` → `dim_date[calendar_date]` (many-to-one) — the
  calendar is care-free, so this one stays a plain single-column relationship
- `continuity_report[carer_key]` → `dim_carer[carer_key]` (many-to-one, optional) —
  NOT the bare `carer_id`

The date slicer filters `dim_date`; visuals put `dim_client` attributes on rows.

Set the sort columns on `dim_date` or labels order alphabetically: `month_name` by
`month_number`, `month_year_label` by `year_month`, `day_name` by
`day_of_week_number`.

## Report columns → Power BI

| Report column (§5) | Power BI |
|---|---|
| Client Name | `dim_client[full_name]` |
| Social Services Ref | `dim_client[client_no]` |
| Area | `dim_client[area_name]` — see the fallback note below |
| Branch | `dim_client[branch]` |
| Visits this Year | `[Year Visits]` |
| Carers (Yr) | `[Year Carers]` |
| Year Continuity | `[Year Continuity]` |
| % | `[Year Continuity %]` — colour coded |
| Visits In Search Period | `[Visits]` |
| Carers | `[Carers]` |
| Period Continuity | `[Continuity]` |
| % | `[Continuity %]` — colour coded |

Legacy §5 shows `"Area Not Assigned"` when the area is empty. `dim_client` carries
the raw `area.name` because it is shared with the other reports, so do that fallback
in Power BI. A **calculated column** (not a measure) — it goes on rows and in a
slicer, both of which need a groupable column:

```DAX
Area =
IF(
    ISBLANK(dim_client[area_name]) || TRIM(dim_client[area_name]) = "",
    "Area Not Assigned",
    dim_client[area_name]
)
```

Put this on the visual and hide `area_name`, otherwise two near-identical fields
show up in the field list. The same pattern applies to `branch` if the source can
leave it empty — legacy prints it raw, so it is left alone here.

**Client scope comes for free.** Legacy §3.1 lists only clients with at least one
visit in the calendar year. The fact only holds rows where a visit exists, so a
client with none simply has no rows in the window and drops out of the visual — no
filter to write.

## Additive metric — plain SUM

`visit_count` is the only stored measure. It is `COUNT` of delivered timesheets
(`timeType IS NULL`), unrounded, so any date-range `SUM` is exact.

```DAX
Visits = SUM(continuity_report[visit_count])
```

## Non-additive metrics — DAX measures

### Carers

```DAX
Carers =
SUMX(
    VALUES(continuity_report[client_key]),
    CALCULATE(
        DISTINCTCOUNT(continuity_report[carer_key]),
        RIGHT(continuity_report[carer_key], 3) <> "|-1"
    )
)
```

**`VALUES` iterates the COMPOSITE key, and the bare ids are no longer there to get
this wrong with.** The fact holds every care in the account and client ids repeat
across them: iterating a bare `client_id` would yield 8842 ONCE for two different
people and count their carers as one client's — understating the total and
overstating continuity. The distinct count inside runs on `carer_key` for the same
reason: two cares' carer 500 are two people. Both bare ids were dropped from the
fact once every consumer keyed on the composite, so the mistake is now unavailable
rather than merely documented.

Three more things are happening here, all deliberate:

**Why `SUMX` over clients and not a bare `DISTINCTCOUNT`.** Legacy's totals row
(§4.4) sums the *per-client* distinct carer counts, so a carer serving two clients is
counted twice. A bare `DISTINCTCOUNT` at the total level is a **global** distinct — it
counts that carer once, and fewer carers in the numerator means it reports a *higher*
continuity % than the old report. This `SUMX` is correct at **both** grains with one
definition and no `ISINSCOPE` / `HASONEVALUE` branching: on a client row `VALUES()`
yields that single client, so it degenerates to the plain `DISTINCTCOUNT`; at the total
it reproduces legacy's `finalTotalCarers`. `Continuity %` then needs no totals variant
either — it just receives the right numerator.

**Why `VALUES()` iterates the fact's key, not `dim_client`'s.** Clients visible in
the dimension but with no visits in the selected range would each contribute a
blank, which is harmless for a `SUM` but makes the intent murky. Iterating the fact
restricts it to clients that actually have rows.

**Why the `"|-1"` test.** `-1` is the "no carer recorded" sentinel (the fact needs a
non-null merge key), and the fact no longer carries the bare `carer_id` — only
`carer_key`, which renders the sentinel as `care1|-1`. `RIGHT(…, 3)` is therefore how
the sentinel is excluded, and it is care-safe: the last three characters can only be
`|-1` when the id itself is -1. MySQL's `COUNT(DISTINCT carerId)` skips `NULL`s, so
excluding it keeps the count identical to legacy. A client whose visits are *all* sentinel therefore
gets `Carers = 0` and reads 100% — which is what legacy does too (`0 / visits`), so leave
it; `dim_carer` has no -1 row, so such rows land on a blank carer if you drill in.

> **Open decision.** Whether the report *should* show legacy's double-counting total or
> the global distinct — arguably the more correct answer to "how many different people
> actually worked" — is a business call, not a modelling one. The fact supports both.
> Swap the `SUMX` for a bare `DISTINCTCOUNT` to switch, and expect the totals row to
> stop tying out against the old report. To decide with numbers rather than in the
> abstract, put both on one visual for a while — they differ only on the totals row:
>
> ```DAX
> Carers (global distinct) =
> CALCULATE(DISTINCTCOUNT(continuity_report[carer_key]), RIGHT(continuity_report[carer_key], 3) <> "|-1")
> ```

### Continuity and Continuity %

Both mirror legacy §4.1 branch for branch, in the same order:

```DAX
Continuity % =
VAR CarerCount = [Carers]
VAR VisitCount = [Visits]
RETURN
SWITCH(
    TRUE(),
    CarerCount = 1, 100,
    VisitCount > 0, ROUND(100 - DIVIDE(CarerCount, VisitCount) * 100, 2),
    0
)
```

```DAX
Continuity =
VAR CarerCount = [Carers]
VAR VisitCount = [Visits]
RETURN
SWITCH(
    TRUE(),
    CarerCount = 1, 1,
    VisitCount > 0, ROUND(1 - DIVIDE(CarerCount, VisitCount), 2),
    0
)
```

**The `CarerCount = 1` branch is not redundant — it is a legacy override.** The general
formula would give a single carer over 10 visits `100 - 10 = 90%`, but the PHP hardcodes
100% ("one carer always") whenever the distinct count is 1. The gap widens with visit
count: 100 visits with 1 carer reads 99% from the formula and 100% from legacy, while 5
visits with 1 carer reads 80%. Drop the branch and **every perfectly-continuous client
reads low, worst for the clients with fewest visits** — the exact opposite of what the
report is meant to show.

`Continuity` is defined separately rather than as `[Continuity %] / 100` on purpose:
legacy rounds the ratio and the percentage to 2dp *independently*, so dividing the
rounded percentage would drift (ratio `0.123456` → legacy gives `0.88` and `87.65`,
whereas `87.65 / 100 = 0.8765`).

Note also that legacy does **not** apply the `= 1` override to its totals row (§4.4 is
the plain ratio), so a single-client-single-carer grand total disagrees with its own
client row there. Legacy is inconsistent on that edge; the measures above follow the
row behaviour, which is the sensible one.

**A client with no visits in the selected period reads `0` visits, `0` carers, `0%`** —
the `SWITCH` falls through to its last branch. That is legacy-faithful (§4.1's `else`),
and it happens on the Period half whenever a client had visits earlier in the calendar
year but none in the slicer range, because the Year half keeps the row on the visual.
The colour rule then paints that `0%` red. If the business would rather see an empty
cell than a red zero, add the guard *only* to the display measure — do not touch the
`SWITCH`, whose `0` is what ties out against legacy:

```DAX
Continuity % (blank if no visits) = IF([Visits] > 0, [Continuity %])
```

### Formatting

The `%` measures return a number on a **0–100** scale, not a fraction. Format them as
`0.00` (or a custom `0.00"%"`) — do **not** apply Power BI's *Percentage* format, which
multiplies by 100 again and shows `9765.00%`. `Continuity` / `Year Continuity` are the
0–1 ratio, format `0.00`. `Visits` and `Carers` are whole numbers, format `#,0`.

## Year vs Period

Legacy runs two near-identical queries per client — a full-calendar-year window (§3.2)
and the user's selected range (§3.3) — and shows them side by side. Both read the same
rows with a different date predicate, so both sets of columns come from this one fact.
The Period measures are simply the base measures above, reading the current filter. The
Year measures re-apply that selection snapped out to whole calendar years (§4.3):

```DAX
Year Visits =
VAR SelYears = VALUES(dim_date[year])
RETURN CALCULATE([Visits], REMOVEFILTERS(dim_date), TREATAS(SelYears, dim_date[year]))
```

```DAX
Year Carers =
VAR SelYears = VALUES(dim_date[year])
RETURN CALCULATE([Carers], REMOVEFILTERS(dim_date), TREATAS(SelYears, dim_date[year]))
```

```DAX
Year Continuity % =
VAR SelYears = VALUES(dim_date[year])
RETURN CALCULATE([Continuity %], REMOVEFILTERS(dim_date), TREATAS(SelYears, dim_date[year]))
```

```DAX
Year Continuity =
VAR SelYears = VALUES(dim_date[year])
RETURN CALCULATE([Continuity], REMOVEFILTERS(dim_date), TREATAS(SelYears, dim_date[year]))
```

`REMOVEFILTERS(dim_date)` clears only the date filter, so the client context on each row
still applies. Selecting `01-03-2025 → 30-06-2025` gives `SelYears = {2025}` and the
Year columns cover all of 2025; a selection spanning Dec 2024 → Jan 2025 gives
`{2024, 2025}` and covers both full years, matching legacy's
`YEAR(dateFrom)-01-01 … YEAR(dateTo)-12-31`.

**With no date selection at all** `VALUES(dim_date[year])` yields every year in the
calendar (2000 → current), so the Year columns silently become all-history. Legacy
always received a from/to, so it has no equivalent state. Either default the page's
date slicer to a range, or make the fallback explicit — same `VAR` in all four Year
measures:

```DAX
VAR SelYears = IF(ISFILTERED(dim_date), VALUES(dim_date[year]), { YEAR(TODAY()) })
```

> One deviation, on an input legacy could not receive: with a **non-contiguous**
> multi-select (say 2023 and 2025), legacy's `BETWEEN` would also sweep in 2024, while
> `TREATAS` covers only the years actually selected. A normal from/to date picker cannot
> produce this, so it only matters if you expose a year multi-select.

Because both halves derive from one fact and one set of base measures, changing the date
slicer cannot desynchronise them — which two stored window columns could not guarantee.

## Colour coding (§4.2)

Thresholds: `> 90` green, `> 70` and `<= 90` orange, `<= 70` red. Either use Power BI's
rule-based conditional formatting on the % measures, or drive it from a measure and pick
*Format by → Field value*:

```DAX
Continuity Colour =
SWITCH(
    TRUE(),
    [Continuity %] > 90, "#2E7D32",
    [Continuity %] > 70, "#EF6C00",
    "#C62828"
)
```

Add a `Year Continuity Colour` the same way over `[Year Continuity %]`.

## Why these are DAX (not fact columns)

The core metric is `1 - COUNT(DISTINCT carerId) / COUNT(id)`, and a distinct count is
**not additive** — a carer working January and February counts once in each, so summing
monthly carer counts overstates the quarter. There is therefore nothing to store: any
carer count or continuity figure is only ever valid for the one window it was built
for, and materialising every possible user-selected range is combinatorially
impossible. Keeping the carer on the grain pushes the distinct count to query time,
where the user's actual selection is known. Same rule as the hours reports: stored
columns additive and unrounded, non-additive figures as measures.

The Year columns are the one part that *could* have been precomputed in SQL — "calendar
year" is a fixed grain, not an arbitrary range. It was not worth a second model: the
Period half needs measures regardless, and each Year measure is a three-line wrapper
over one that already exists.

## Legacy fidelity notes

- **`timeType IS NULL` is the only row filter.** Actual delivered visits; cancelled,
  training and every other `timeType` are excluded (§7).
- **No `timeConfirmed = 'Yes'` gate — settled.** An earlier revision of the source doc
  said "confirmed visit" in its prose while none of the §3 queries mentioned the column;
  the current one states outright that there is no such filter and that both submitted
  and confirmed timesheets count (§7). The model follows that. It differs from
  `int__client_delivered_hours` / `int__carer_confirmed_hours`, which do gate on it —
  deliberate, and flagged in `int__client_carer_visits.sql`. Do not add the filter: it
  would silently drop visits legacy counts.
- **No job type.** The report covers all visit types equally (§7), so `job_type_id` is
  deliberately absent from the grain.
- **No `location_id`.** Legacy scopes each run to one `locationId`. Here the reader's
  company/location is enforced by `report__continuity_report` via
  `mart__dim_client`, and a client's visits across locations aggregate together —
  matching `mart__client_hours_report`.
