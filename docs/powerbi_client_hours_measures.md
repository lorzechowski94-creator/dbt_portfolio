# Client Hours Report — Power BI setup

**One fact, one semantic model, two reports.** `client_hours_report` is grained to
job type and serves both the client-level report and the client × job type report;
there is no separate client-level fact (see [Grain change](#grain-change-on-the-fact)).

| | Report A — Client Hours | Report B — Client Hours by Job Type |
|---|---|---|
| Visual grain | one row per client | one row per client × job type |
| `JobType` column | absent | `dim_jobtype[job_type_name]` |
| Row suppression | none (all clients shown) | visual filter `Total Deliverable (hrs) <> 0` |
| Measures | identical set | identical set |

Report A simply omits job type from the visual; Power BI sums the job type rows
back to the client total. That works because the fact is fully additive — verified
against the pre-grain-change client-level fact with zero mismatched rows (care1,
all dates, 2026-07-30).

Ports `clientsHoursRpt.php` and `clientsHoursRpt_JobType_V2.php`.

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
| Fact | `report__client_hours_report` | `ANALYTICS_MART.REPORT.CLIENT_HOURS_REPORT` | `client_key` + `service_date` + `job_type_key` |
| Dim client | `report__dim_client` | `…REPORT.DIM_CLIENT` | `client_id` |
| Dim job type | `report__dim_jobtype` | `…REPORT.DIM_JOBTYPE` | `job_type_id` |
| Dim job type group | `report__dim_jobtype_group` | `…REPORT.DIM_JOBTYPE_GROUP` | `group_id` |
| Bridge | `report__bridge_jobtype_group` | `…REPORT.BRIDGE_JOBTYPE_GROUP` | `group_id` + `job_type_id` |
| Dim date | a Date table on `service_date` (mark as Date table) | — | `date` |

Build the Date table from `int__report_calendar` (`calendar_date`) or a
native PBI calendar.

**ONE relation per ACCOUNT, and the names carry no care token.** Every care in the
account is stacked into the same table, with a `source` column saying which source
schema each row came from (`macros/union_cares.sql`); the names in the table above
are the real ones in every account. The per-care `CARE1_` / `CARE2_` … relations
are gone — repoint the model at the bare names, and drop the per-tenant models that
used to exist one per care.

**`source` is part of every relationship and of the fact's grain.** Client and job
type ids are allocated per care and collide across them, so relating on the bare id
would join one care's client to another's — and Power BI refuses the relationship
outright, because the duplicate id breaks the "one" side.

The warehouse ships the composite key ready-made, as one integer (care and id,
`macros/source_key.sql`; Whole number / int64 in Power BI, on both sides). Relate on
the `*_key` columns; no calculated column is needed, and the bare ids should stay
out of every relationship:

| Key column | On the dimension | On the fact |
|---|---|---|
| `client_key` | `dim_client` | `client_hours_report` |
| `job_type_key` | `dim_jobtype` | `client_hours_report`, `bridge_jobtype_group` |
| `group_key` | `dim_jobtype_group` | `bridge_jobtype_group` |

`dim_date` is the exception — the calendar is shared and carries no `source`.

## Relationships

```
#	Relationship	Cardinality	Cross-filter
1	dim_jobtype_group[group_key] → bridge_jobtype_group[group_key]	1:*	Single
2	dim_jobtype[job_type_key] → bridge_jobtype_group[job_type_key]	1:*	Both
3	dim_jobtype[job_type_key] → client_hours_report[job_type_key]	1:*	Single
4	dim_client[client_key] → client_hours_report[client_key]	1:*	Single
5	DateDim[Date] → client_hours_report[service_date]	1:*	Single
```

The date slicer filters `DateDim`; visuals put `dim_client` attributes on rows.
Each row shows the client totals **for the selected date range**.

**Hide from report view:** the entire `bridge_jobtype_group` table, and
`dim_jobtype_group[group_id]`. The bridge's `job_type_id` is the identical raw id
already on the fact — it is a join key, not a slicer value.

### Job type group slicer

Put `dim_jobtype_group[group_name]` on the slicer. The filter propagates
group → bridge → `dim_jobtype` → fact, which is why the bridge ↔ `dim_jobtype`
relationship must be bidirectional: the filter has to travel *up* from the
many side.

Selecting several groups does not double-count. The filter resolves to a *set* of
job type ids, so a job type belonging to two selected groups still contributes once.

The groups come from `jobtypeGroupName.jobTypeList`, a comma-separated id list
exploded with `SPLIT_TO_TABLE` in `mart__bridge_jobtype_group`. Ignore the
note in `client_hours_report_jobtype_v2_snowflake.md` calling `jobtypeGroupName`
"UI only, not relevant to Snowflake model" — it is stale; the grouping is modelled.

## Cross-column search

Port of the DataTables global `Search:` box — one input that filters the table on
every column at once, honouring the column-visibility field parameter. Power BI
has no native equivalent, so it is three parts: an index table, a text slicer and
a measure used as a visual filter.

This section is the design and the reasoning. The paste-ready Power Query and
`Search Hit` DAX for every report are in
[powerbi_search_index_setup.md](powerbi_search_index_setup.md).

### What it cannot cover — substring matching on the hours columns

Text search reaches the **attribute** columns (Client, Area, Workgroup, Branch, …)
and not the hours columns. Two independent reasons:

1. The hours are measures evaluated against the selected date range, so there is
   no stored value to index — the same client shows `5.67` for one range and
   `144.34` for another.
2. No DAX expression can read the string the user typed. Every text input in
   Power BI (native text slicer, the certified Text Filter visual) applies a
   `contains` filter to a column; a measure sees the surviving *values* of that
   column, never the term. So `CONTAINSSTRING(FORMAT([Total Scheduled], …), Term)`
   cannot be written — `Term` does not exist.

The legacy report searched the rendered HTML, which is why it could match `5.` in
an hours cell.

Searching the hours **by value** is a different question and is solvable with a
second control — a numeric range slicer, unlike any text input, can be read back
in DAX. See [Searching the hours columns](#searching-the-hours-columns--a-second-control).
What stays lost is substring matching on a rendered number.

#### Why the index does not carry the hours — and the one case where it could

Reason 1 is a property of the *date filter*, not of where the number is computed.
Materialising the DAX measures as dbt columns changes nothing: the fact is grained
`client_id + service_date + job_type_id`, and the figure on screen is a sum over a
range that only exists at query time.

It would work if the date range came from a **finite, known-in-advance set of
periods**. Each period can then be aggregated in dbt up front and its formatted
total indexed beside the attributes — which would give full legacy parity, one box,
substring matching included. Non-additivity is no obstacle there: `MAX(0, …)`, the
`state_id` gate and the `HH:MM` formats are non-additive *over time*, and a fixed
period computes them once, after aggregation, exactly as the measures do now.

**Rejected: the free date picker is a hard requirement** (legacy takes any
`DD-MM-YYYY` to `DD-MM-YYYY`, and the PO keeps it). Recorded because "the hours
cannot be indexed" is only true given that requirement — if the report is ever
reduced to period presets, this becomes the better design. The other costs were
the index gaining a period dimension (clients × periods × ~20 columns, order 10M
rows, and again per job type for Report B) and a rebuild per new period.

### Model

| Piece | Setting |
|---|---|
| Table | `report__search_index` — `…REPORT.SEARCH_INDEX`, one row per entity × attribute |
| Relationships | one for a single-entity report; none when the report searches several entities (below) |
| Hidden | every column of `SEARCH_INDEX` |
| Slicer | text slicer on `SEARCH_INDEX[VALUE_TEXT]`, operator **Contains** |
| Visual filter | `Search Hit` **is** `1`, on every table and chart visual, never on cards |

`SEARCH_INDEX` is one table for every report, with one key column per entity and
exactly ONE populated per row. A report that searches one entity relates it. A
report that searches several matches each key in the measure instead:

| Report | How `SEARCH_INDEX` meets the report |
|---|---|
| Client Hours (both views) | no relationship; `TREATAS` on `CLIENT_KEY` and `GROUP_KEY` |
| Carer Hours | relationship from `DIM_CARER[CARER_KEY]` |
| Continuity | relationship from `DIM_CLIENT[CLIENT_KEY]` |
| Carer Qualification | relationship from `CARER_QUALIFICATION_REPORT[QUALIFICATION_KEY]` |
| Schedule Difference | no relationship; `TREATAS` on the fact's four keys |

The two fact-side keys exist only for this: those exports search columns that sit
on the fact, and a Power BI relationship needs a unique column on the "one" side,
which neither fact had. Keying them on `carer_key` instead would spread a hit
across all of that carer's rows — searching a qualification name would return every
file they hold, not the one that matched.

Where there is a relationship it is single-direction, deliberately. The slicer
filters the index, the measure reads it, and nothing has to propagate back into
the dimensions, so the search costs no bidirectional relationship.

**The search narrows a visual's rows, never its numbers.** That holds in every
report, because it is the only behaviour all five can share: a multi-entity
report has no relationship to carry the term into the fact. KPI cards therefore
ignore the search (Carer Hours, Continuity, Carer Qualification's *Staff
compliance* page). A visual grouped above the indexed grain keeps a row when any
of its records matches, and that row's figures stay whole: Carer Qualification's
*File types* table keeps every type one of whose files matches, and its counts
are not reduced to the matching files. A bidirectional relationship would narrow
the figures, but only in the single-entity reports. Carer Qualification ran that
way briefly on 2026-10-05, and it was reverted so that every report behaves the same.

**Why the multi-entity reports have no relationship at all: RLS.** A relationship
carries the dimension's RLS rule into the index. In Client Hours, `dim_client`'s
rule is the tenant boundary for the fact, so it is strict. Through a relationship it
would hide every group row, because those carry no `client_key`. `REMOVEFILTERS`
cannot lift a security filter, so group-name search would find nothing. Matched by
key, the index is filtered only by its own `COMPANY_ID` rule (see
[powerbi_embedded_setup.md](powerbi_embedded_setup.md)). A single-entity index loses
nothing to its relationship, because every row it holds belongs to that one entity.

The slicer is Microsoft's **Text Filter** from AppSource — PBI Certified — so the
report carries a custom visual dependency. It travels inside the report file,
nothing to install per viewer. One tenant setting still gates it: *Allow visuals
created using the Power BI SDK*. With that off, even a certified visual shows an
error placeholder while the rest of the page renders normally, which reads as a
broken tile rather than a governance setting. Confirm it before the embedded demo.

**Keep it certified if it is ever swapped.** The slicer is bound to `VALUE_TEXT` —
client names, addresses, phones and emails, every tenant's, in one column.
Certification is the guarantee that a visual calls no external service, so an
uncertified visual on this particular field would be a data-exfiltration path in a
multi-tenant product, not a governance checkbox.

A custom visual cannot bypass RLS: it only receives the rows the engine already
returned for the effective identity.

If a recent Desktop offers a core text/search slicer style, switching to it drops
the dependency and this whole section with it.

### The measure

The visible column set is spread over **two** field parameters — `Report Grouping`
(the row columns: Client ID, First Name, Surname, Area, Jobtype, Branch) and
`Column Visibility` (the hours columns and the client attributes). The measure
unions both, or half the visible columns never match.

It joins on **`Value2`**, the `NAMEOF()` reference, not the display label in
`Value1`: that is what `SEARCH_INDEX[COLUMN_REF]` is built to reproduce, so
renaming a column in the report cannot silently drop it from search.

```DAX
Search Hit =
VAR VisibleRefs =
    UNION (
        SELECTCOLUMNS (
            ALLSELECTED ( 'Report Grouping'[Parameter Fields] ),
            "@ref", SUBSTITUTE ( UPPER ( 'Report Grouping'[Parameter Fields] ), "'", "" )
        ),
        SELECTCOLUMNS (
            ALLSELECTED ( 'Column Visibility'[Value2] ),
            "@ref", SUBSTITUTE ( UPPER ( 'Column Visibility'[Value2] ), "'", "" )
        )
    )
VAR SearchableRefs =
    INTERSECT ( ALL ( SEARCH_INDEX[COLUMN_REF] ), VisibleRefs )
VAR Searching = ISFILTERED ( SEARCH_INDEX[VALUE_TEXT] )
VAR Scoped = TREATAS ( SearchableRefs, SEARCH_INDEX[COLUMN_REF] )
VAR ClientHits =
    CALCULATE ( COUNTROWS ( SEARCH_INDEX ), Scoped,
        TREATAS ( DISTINCT ( DIM_CLIENT[CLIENT_KEY] ), SEARCH_INDEX[CLIENT_KEY] ) )
VAR GroupHits =
    CALCULATE ( COUNTROWS ( SEARCH_INDEX ), Scoped,
        TREATAS ( DISTINCT ( DIM_JOBTYPE_GROUP[GROUP_KEY] ), SEARCH_INDEX[GROUP_KEY] ) )
RETURN
    IF (
        NOT Searching || ISEMPTY ( SearchableRefs ),
        1,
        IF ( ClientHits > 0 || GroupHits > 0, 1, 0 )
    )
```

**One branch per key.** Each branch matches the index on one key column. A single
`COUNTROWS` carrying both `TREATAS` would demand both keys on one row, and no row
carries two, so the result would always be zero and the table would blank out. The
branches are `OR`ed: the row survives if the term matched a visible column of the
client OR of the job type group.

**`DISTINCT`, not `VALUES`.** `VALUES` includes a dimension's blank row. As a
`TREATAS` value, that blank would match every index row whose key is blank, i.e.
every row of the other entity.

A report that searches one entity needs no split: drop the extra `VAR` and use
`Hits > 0` directly. Schedule difference matches four keys and needs four branches.

`GroupHits` costs nothing on the Client Hours view. `Value4` narrows the parameter
to that view, and `DIM_JOBTYPE_GROUP[GROUP_NAME]` is not in it, so only client refs
reach `Scoped`. Client rows carry no `GROUP_KEY`, so the group branch matches
nothing there. The group name becomes searchable only on the view that shows it.

The version before 2026-09-28 related the index and used `REMOVEFILTERS` in place of
`TREATAS`. That broke group search under RLS. On the Client Hours view, with no
group in context, it could also count every client's hits and keep every row.

The `SUBSTITUTE ( UPPER ( … ), "'", "" )` is not cosmetic. The report writes
`NAMEOF` both ways — `NAMEOF('DIM_CLIENT'[CLIENT_ID])` and
`NAMEOF(DIM_CLIENT[AREA_NAME])` — so rather than bet on which spelling the engine
stores, both sides are normalised: quotes stripped, uppercased, matching the
`column_ref` the mart already stores.

`ALLSELECTED` reads the slicers while ignoring the visual's own filter on the
parameters — that distinction is the whole reason a hidden column stops matching.
It keeps the page-level `Value4` filter, so each view sees only its own field list.
`Value2` repeats across views (both parameters are `CROSSJOIN`s), which is
harmless: `ALLSELECTED` returns distinct values.

The hours measures sit in `Column Visibility` and never appear in the index, so
`INTERSECT` drops them. Nothing special is needed for them.

Both guards matter:

- **`NOT Searching`** — with an empty search box nothing is filtered, so every
  client has index rows and every row would pass anyway; the guard is what keeps a
  client with no indexed attribute at all from silently disappearing.
- **`ISEMPTY ( SearchableRefs )`** — if a view ends up showing nothing searchable,
  returning `1` leaves the table alone instead of blanking it.

To verify the wiring, drop `Search Hit` on a card beside the table and toggle both
parameter slicers while a term is typed: the card must follow the visible column
set, not just the term.

### Searching the hours columns — a second control

**Deferred, not built.** The PO chose to ship the text field alone and see whether
it is enough (2026-09-22). Everything below is ready to drop in if it is not;
nothing in the mart or the text search depends on it, and until it exists the
visual filter stays `Search Hit is 1` rather than `Row Visible`.

Substring search over the hours columns is out (above). Searching them *by value*
is not: a **numeric range slicer** is readable in DAX, unlike every text input. Put
a disconnected table beside the model —

```DAX
Hours Search = SELECTCOLUMNS ( GENERATESERIES ( 0, 5000, 0.01 ), "Value", [Value] )
```

— related to nothing, hidden from the field list except for its slicer. A numeric
range slicer on `'Hours Search'[Value]` has editable min/max boxes, so typing
`15.5` into both is an exact-value lookup and a range comes for free. `MIN`/`MAX`
read the selection back:

```DAX
Hours Hit =
VAR Lo = MIN ( 'Hours Search'[Value] )
VAR Hi = MAX ( 'Hours Search'[Value] )
VAR VisibleRefs = -- identical to Search Hit; factor it into a shared measure
    UNION (
        SELECTCOLUMNS ( ALLSELECTED ( 'Report Grouping'[Parameter Fields] ),
            "@ref", SUBSTITUTE ( UPPER ( 'Report Grouping'[Parameter Fields] ), "'", "" ) ),
        SELECTCOLUMNS ( ALLSELECTED ( 'Column Visibility'[Value2] ),
            "@ref", SUBSTITUTE ( UPPER ( 'Column Visibility'[Value2] ), "'", "" ) )
    )
VAR Candidates =
    {
        ( "CLIENT_HOURS_REPORT[ALLOCATED (HRS)]", [Allocated (hrs)] ),
        ( "CLIENT_HOURS_REPORT[TOTAL SCHEDULED (HRS)]", [Total Scheduled (hrs)] ),
        ( "CLIENT_HOURS_REPORT[SCHEDULED UNASSIGNED (HRS)]", [Scheduled Unassigned (hrs)] ),
        ( "CLIENT_HOURS_REPORT[CANCELLED TIMESHEET (HRS) BILLED]", [Cancelled Timesheet (hrs) Billed] ),
        ( "CLIENT_HOURS_REPORT[CANCELLED TIMESHEET (HRS) NOT BILLED]", [Cancelled Timesheet (hrs) Not Billed] ),
        ( "CLIENT_HOURS_REPORT[BILLABLE SCHEDULE (HRS)]", [Billable Schedule (hrs)] ),
        ( "CLIENT_HOURS_REPORT[TOTAL CONFIRMED (BILLED) TIMESHEET (HRS)]", [Total Confirmed (Billed) Timesheet (hrs)] ),
        ( "CLIENT_HOURS_REPORT[TOTAL ACTUAL TIME (HRS)]", [Total Actual Time (hrs)] ),
        ( "CLIENT_HOURS_REPORT[TOTAL DELIVERABLE (HRS)]", [Total Deliverable (hrs)] ),
        ( "CLIENT_HOURS_REPORT[NON-DELIVERED INCLUDING CANCELLED (HRS)]", [Non-Delivered Including Cancelled (hrs)] ),
        ( "CLIENT_HOURS_REPORT[NON-DELIVERED (HRS)]", [Non-Delivered (hrs)] ),
        ( "CLIENT_HOURS_REPORT[A V S DIFFERENCE (HRS)]", [A v S Difference (hrs)] ),
        ( "CLIENT_HOURS_REPORT[BILLABLE V CONFIRMED (HRS)]", [Billable v Confirmed (hrs)] ),
        ( "CLIENT_HOURS_REPORT[SCHEDULE DIFFERENCE (HRS)]", [Schedule Difference (hrs)] ),
        ( "CLIENT_HOURS_REPORT[BREAKS PAID SCHEDULED (HRS)]", [Breaks Paid Scheduled (hrs)] ),
        ( "CLIENT_HOURS_REPORT[BREAKS UNPAID SCHEDULED (HRS)]", [Breaks Unpaid Scheduled (hrs)] ),
        ( "CLIENT_HOURS_REPORT[BREAKS PAID SCHEDULED UNASSIGNED (HRS)]", [Breaks Paid Scheduled Unassigned (hrs)] ),
        ( "CLIENT_HOURS_REPORT[BREAKS UNPAID SCHEDULED UNASSIGNED (HRS)]", [Breaks Unpaid Scheduled Unassigned (hrs)] ),
        ( "CLIENT_HOURS_REPORT[BREAKS PAID CONFIRMED (HRS)]", [Breaks Paid Confirmed (hrs)] ),
        ( "CLIENT_HOURS_REPORT[BREAKS UNPAID CONFIRMED (HRS)]", [Breaks Unpaid Confirmed (hrs)] )
    }
RETURN
    IF (
        NOT ISFILTERED ( 'Hours Search'[Value] ),
        1,
        IF (
            COUNTROWS (
                FILTER (
                    Candidates,
                    [Value1] IN VisibleRefs
                        && ROUND ( [Value2], 2 ) >= Lo
                        && ROUND ( [Value2], 2 ) <= Hi
                )
            ) > 0,
            1,
            0
        )
    )
```

Same visibility rule as the text search: a hidden hours column drops out of
`VisibleRefs` and stops matching. If the engine rejects measures inside the table
constructor, fall back to a chain of `||` over the same 20 pairs — more verbose,
identical result.

`ROUND ( …, 2 )` on both sides of the comparison is not optional. These are sums of
floats: a client showing `15.5` can hold `15.499999999`, and an exact-value lookup
(`Lo = Hi = 15.5`) would silently miss it. Rounding to the displayed precision is
what makes "type the number you see" work.

**One box instead of two.** The range slicer renders as *Between* — a min and a max
field. For a single field, closer to the legacy feel, use a What-if parameter
instead; its slicer has one editable value, and the measure compares
`ROUND ( [Value2], 2 ) = SELECTEDVALUE ( 'Hours Search'[Value] )`. It costs range
search ("everything over 100 hours"), which the filter pane can no longer give back
per column once the hours are searched centrally. Prefer the range unless the PO
asks for the single field by name.

The two `HH:MM` measures are absent: they return text, not a number, so they fit
neither control. They stay unsearchable.

**The non-additive measures are covered, and cannot drift.** `Candidates` calls the
same measures the cells render, in the same row filter context, after the date
range aggregates — so `MAX(0, …)`, the `state_id` gate and the per-job-type
evaluation in Report B all reach the comparison exactly as the user sees them. This
is what the rejected period-index variant could not have had: there the logic would
have been reimplemented in SQL, and any drift from the DAX would surface as a
search hit on a row displaying a different number.

Once it exists, combine the two controls on the table visual with one filter
measure, `is 1`, replacing `Search Hit` there:

```DAX
Row Visible = IF ( [Search Hit] = 1 && [Hours Hit] = 1, 1, 0 )
```

`AND` rather than `OR`, because two separate boxes read as two filters — "clients
in Sligo with about 15.5 hours". Both measures return `1` when their own control is
empty, so each works alone without a special case. Switch to `||` for one-box
semantics.

**Cost.** This evaluates 20 measures per visual row on top of the index lookup,
inside a visual-level filter. They are all SUMs over one fact, so the engine
resolves them in few scans, but it is the most expensive thing on the page —
measure it on the largest tenant before shipping.

**Full legacy parity needs a different tool.** If the PO will not accept two
controls, the only route to one box that substring-matches rendered numbers is a
**paginated report** (Report Builder): it has native free-text parameters, passes
them into the SQL, and the warehouse does `LIKE` over the formatted aggregates. F
SKUs run paginated reports. The cost is the field-parameter column-visibility UX,
which has no paginated equivalent.

### The Jobtype column, and why it is covered now

`Report Grouping` puts `DIM_JOBTYPE_GROUP[GROUP_NAME]` on the Client Hours Jobtype
view. It was left out of the first cut on the grounds that covering one
low-cardinality attribute would cost a second index table and a split measure, to
buy something the group slicer already does.

That reasoning expired when the index was consolidated. The multi-key table and the
`REMOVEFILTERS` split both had to exist anyway — schedule difference draws on four
entities and the qualification export on two — so the marginal cost of the group
became one source block and a few hundred rows. It is indexed under `group_key`.

The point generalises: **judge a search column by its marginal cost against the
index you already have, not by what it would have cost on its own.** The same
attribute went from "not worth the machinery" to free without anything about the
attribute changing.

### Keeping the parameters and the index in sync

Matching on `Value2` removes the display-name coupling, but not the column list: an
attribute a parameter exposes and the index does not is silently unsearchable.
`searchable_attributes` in `mart__search_index.sql` covers every
`dim_client` entry of both parameters, plus the attributes this dimension's sibling
reports use; add to both sides when a new column is exposed.

The one string that must still line up is the table name inside `column_ref` —
`DIM_CLIENT`. If the semantic model renames the table, the model's `column_ref`
expression has to follow, and the join fails silently when it does not.

### Reusing it

Nothing in the index is specific to this report — it indexes `dim_client`, which
the continuity and schedule difference reports also sit on. A second report reuses
the same table and the same measure shape; only the field parameter names in
`VisibleRefs` change. That reuse is the reason it is a dbt model rather than a
Power Query step inside one `.pbix`.

One table serves every report: `mart__search_index` carries one key column per
entity (`client_key`, `carer_key`, `job_type_key`, `group_key`,
`qualification_key`, `occurrence_key`) with exactly one populated per row. A report
relates only the entities it displays.

#### Which grain a new report's index gets

One rule decides it, and it is worth applying before writing any SQL, because the
two answers are not interchangeable:

- **The value sits on a dimension the report groups by** → index it under that
  dimension's key. The rows are then shared across every report showing that
  dimension, and the cost is one row per entity per attribute — entities are few,
  so this is the cheap case.
- **The value sits on the fact** (a flat denormalised export) → index it under the
  fact's own row key. The qualification export is this case: 20 of its 22 columns
  are on the fact, and `dim_carer` holds none of post_code / phone / email / state
  / branch / workgroup, so no dimension key could reach them.

Two things decide the key, and the second overrules the first.

**Which table's filter context reaches the visual row.** That is the table the
field parameter names in `NAMEOF()` — a value keyed on a dimension the visual never
groups by will never be filtered down to the row.

**Whether that relationship would close a loop.** `HR File` / `HR File Type` name
`DIM_HRFILE` in the parameter, so keying them on `hr_file_key` looked right and
cost a few hundred rows instead of ~3M. It is wrong: the qualification fact is
already related to `dim_hrfile` for the HR File slicer, so a second relationship
from the index makes `SEARCH_INDEX → DIM_HRFILE → FACT → SEARCH_INDEX` a cycle and
Power BI refuses the relationship outright. `USERELATIONSHIP` is no escape either —
it cannot activate a relationship that would be ambiguous against the active ones.

So those two values are keyed on the fact, their `column_ref` still says
`DIM_HRFILE[...]` because that is what the parameter names, and the visual row
reaches them through the fact. **Check the existing relationships of the entity
before choosing its key**; the cheaper key is not always available.

A report that mixes dimension and fact values still gets **one** table, because one
text slicer filters one column: the dimension values are joined in at build time
and labelled with the reference the parameter uses for them.

The price of the fact case is multiplication — each indexed attribute costs one
index row per fact row, so 1.7M fact rows and 22 columns is 38M rows. Curate the
column list against what people actually type, not against what the report shows;
anything that already has its own slicer is usually not worth 1.7M rows.

Two things differ per report and are worth checking before debugging anything else:

- **The field parameter's column names.** `client_hours_report` spells the `NAMEOF`
  column `Column Visibility[Value2]` in one parameter and `Report Grouping[Parameter
  Fields]` in the other — the name depends on how each was created, and a wrong name
  makes `SearchableRefs` empty, which reads as "search does nothing".
- **Columns pinned outside any parameter.** `continuity_report` has no field
  parameter at all, and other reports keep their row columns fixed. Those refs have
  to be unioned in as literals or they are visible but unsearchable.

Import each index scoped in Power Query to the refs that report can actually show —
`Table.SelectRows` on `COLUMN_REF` — and drop the key columns of entities that
report does not relate.

**Keep `SOURCE`, `COMPANY_ID` and `LOCATION_ID` in every model's index import.** The
index has no relationships, so the roles' own rule on it is the only thing that cuts
it to the tenant, and that rule matches `SOURCE` and `COMPANY_ID` (see
[powerbi_embedded_setup.md](powerbi_embedded_setup.md)). Until 2026-10 the care
column was dropped at import, because nothing in the model read it; the source-scoped
roles do. `LOCATION_ID` stays for the location filter the embedding app sets. On the
warehouse side `report__search_index` passes the same column to
`customer_access_filter` as `source_col`.

Continuity needs 4 of the 26 client attributes; importing all of
them into every model is the one avoidable cost of keeping six semantic models.

## The NO_JOB_TYPE (-1) bucket

`job_type_id = -1` is a sentinel, not a real job type. It means exactly one thing:
**the source never recorded a job type.** All four pillars reach it the same way —
`coalesce(<source>.jobType, -1)` over `recurr`, `timesheet`, `cmAssignedHours` and
`statusChangeEventsRemoved`.

A non-null sentinel rather than NULL because `job_type_key` is built from it, and
`source_key()` of a NULL id is NULL: a NULL id would leave the row with no key at all,
failing the key's `not_null` test, instead of one that names its care.

The fact stays additive: every source row contributes to exactly one
(client, date, job type) cell, so summing all job type rows for a client reproduces
the client total. Verified against the pre-grain-change fact — zero mismatched rows.

**The bucket belongs to no group,** so a job type or group selection excludes it.
Nothing in DAX compensates for that any more (see the deviation note below) — the
`-1` row is simply a row like any other, and it is visible in Report B unless a
group filter is active.

### Deviation from legacy — non-delivered is split by job type

`statusChangeEventsRemoved` **does** have a `JOBTYPE` column (verified in
`ANALYTICS_RAW.CARE1`). The legacy PHP never selected it — its query reads
`SELECT id, recurrId, eventMinutes, clientId` — and repeated one client-level
non-delivered total on every job type row (`…_v2_snowflake.md` lines 20, 167).

We use the real column instead, so a removed event lands on the job type it was
scheduled under. Consequences:

- `non_delivered_incl_cancelled_hrs` is a **plain additive SUM again** — no
  `REMOVEFILTERS` wrapper on it or on `Non-Delivered (hrs)`.
- `Non-Delivered` now consistently subtracts *that job type's* cancelled hours from
  *that job type's* non-delivered, which also removes the earlier ambiguity about
  which cancelled figure the PHP intended.
- Report B's non-delivered column will **not** match the legacy report: legacy
  showed the client total on every row, we show the per-job-type split. Report A is
  unaffected (it sums back to the same client total).

Required `dbt build --full-refresh` once per tenant: the pillar's grain changed and
`job_type_id` was then part of the incremental merge key, so existing rows would not
re-key themselves.

### Known data issue — care1

Measured 2026-07-30, three-month window, **before** non-delivered was split by job
type — so the 650 non-delivered hours were on `-1` by construction, not because the
data was missing. Re-measure after the full refresh.

| | hours on `-1` |
|---|---|
| non-delivered | 650 (pre-change; will redistribute) |
| **scheduled** | **4,518,985** |
| **allocated** | **414,847** |
| confirmed | 0 |

`recurr.jobType` and `cmAssignedHours.jobType` are unpopulated at scale, while
`timesheet.jobType` is always set — job type is captured when care is *delivered*,
not on the schedule template or the contract. Splitting non-delivered does not
help here: it moves at most 650 hours out of a ~4.9M-hour bucket. Consequence for
Report B: the
confirmed / actual / cancelled columns split cleanly by job type, but
`Allocated`, `Total Scheduled` and `Scheduled Unassigned` land almost entirely on
the "No job type" row.

The legacy PHP report hides this. Its spine is `client CROSS JOIN jobtype` with an
equality join on `jobTypeId`, so a NULL `jobType` matches nothing and is silently
dropped — the PHP V2 report has no "no job type" bucket and therefore does **not**
reconcile with the client-level report. Our `-1` bucket is strictly more complete.
Open item for the PO, not a modelling bug.

## Empty JobType in a visual — three different causes

| Cause | `job_type_id` | Fix |
|---|---|---|
| Source NULL | `-1` | expected; label it (see below) |
| Zero sentinel — app writes `0` for "unset", `coalesce` never fires | `0` | `coalesce(nullif(job_type_id, 0), -1)` in the mart. Currently **not** applied: PHP dropped `0` and NULL identically, so no total is affected — only an extra blank row. |
| Orphan id — populated and valid, but absent from `dim_jobtype`, which filters `deleted is null` | e.g. `1932` | keep soft-deleted job types in `dim_jobtype`; history still needs the label |

`-1` can only come from NULL — resolving `job_type_id` involves no join, it is a
bare column passthrough, so nothing can "fail to find a key".

To label the sentinel instead of showing a blank dimension row, add a `-1` row to
`dim_jobtype`. Note it needs `company_id`/`location_id` handling, or
`customer_access_filter` will drop it from the secure view.

## Additive metrics — plain SUM (no measure needed)

`allocated_hrs`, `total_scheduled_hrs`, `scheduled_unassigned_hrs`,
`non_delivered_incl_cancelled_hrs`, `cancelled_timesheet_billed_hrs`,
`cancelled_timesheet_not_billed_hrs`, `total_confirmed_billed_hrs`,
`total_actual_time_hrs`, `schedule_difference_hrs`, and all `breaks_*` columns.
(`scheduled_event_hrs_all` and `confirmed_payable_hrs` feed the HH:MM measures.)

Round for display: e.g. `Allocated (hrs) := ROUND(SUM(client_hours_report[allocated_hrs]), 2)`.

## Non-additive metrics — DAX measures

Computed after the date filter aggregates. **All seven are identical for both
reports** — every pillar is job-type-scoped in the fact, so no measure needs a
filter-removal wrapper. One definition set, two reports.

```DAX
Non-Delivered (hrs) =
MAX(0,
      SUM(client_hours_report[non_delivered_incl_cancelled_hrs])
    - SUM(client_hours_report[cancelled_timesheet_billed_hrs])
    - SUM(client_hours_report[cancelled_timesheet_not_billed_hrs]))
```

All three terms are job-type-scoped and consistent with each other. In Report B the
figure is per job type; in Report A the sums roll up to the client total.

The remaining six need **no change** for the job type grain:

```DAX
A v S Difference (hrs) =
VAR Sched = SUM(client_hours_report[total_scheduled_hrs])
RETURN IF(Sched > 0, ROUND(SUM(client_hours_report[allocated_hrs]), 2) - ROUND(Sched, 2), 0)
```

```DAX
Billable Schedule (hrs) =
VAR Sched = SUM(client_hours_report[total_scheduled_hrs])
RETURN IF(Sched > 0, Sched - SUM(client_hours_report[cancelled_timesheet_not_billed_hrs]), 0)
```

```DAX
Billable v Confirmed (hrs) =
[Billable Schedule (hrs)] - SUM(client_hours_report[total_confirmed_billed_hrs])
```

```DAX
Total Deliverable (hrs) =
VAR Sched        = SUM(client_hours_report[total_scheduled_hrs])
VAR Unassigned   = SUM(client_hours_report[scheduled_unassigned_hrs])
VAR CancNotBill  = SUM(client_hours_report[cancelled_timesheet_not_billed_hrs])
VAR HasConfirmed = SUM(client_hours_report[confirmed_payable_hrs]) > 0
VAR ClientState  = SELECTEDVALUE(dim_client[state_id])
RETURN
IF(Sched > 0,
   ROUND(Sched, 2) - ROUND(Unassigned, 2) - ROUND(CancNotBill, 2),
   IF(ClientState = 1 && HasConfirmed, ROUND(CancNotBill, 2), 0))
```

`SELECTEDVALUE(dim_client[state_id])` still resolves at client × job type grain —
the client is in filter context either way.

```DAX
Total Scheduled (HH:MM) =
VAR Mins = SUM(client_hours_report[scheduled_event_hrs_all]) * 60   -- no break deduction
RETURN IF(Mins >= 1, FORMAT(INT(Mins / 60), "00") & ":" & FORMAT(MOD(INT(Mins), 60), "00"))
```

```DAX
Total Confirmed (HH:MM) =
VAR Mins = SUM(client_hours_report[confirmed_payable_hrs]) * 60     -- before not-billed deduction
RETURN IF(Mins >= 1, FORMAT(INT(Mins / 60), "00") & ":" & FORMAT(MOD(INT(Mins), 60), "00"))
```

## Why these 7 are DAX (not fact columns)

They are non-linear (floor `MAX(0,…)`, per-client `has recurrence` gate, HH:MM
format), so a per-day value cannot be summed to a range total. They must be
computed once, after the date range is aggregated — which is exactly what a DAX
measure does at query time. Everything else is additive and summed by Power BI.

## Expected: these measures do not sum down a column in Report B

At client × job type grain the threshold logic fires **per job type**, so the
visible rows will not add up to the subtotal. This is correct — each row is the
truth for that job type, and the subtotal is re-evaluated in its own filter
context — but it will be reported as a bug, so explain it up front.

Worked examples:

- `A v S Difference` — a job type with `allocated > 0` but `scheduled = 0` is
  gated to `0` by `IF(Sched > 0, …)`, contributing nothing, while the client
  subtotal sees `Sched > 0` and computes the real difference.
- `Non-Delivered` — the `MAX(0, …)` floor clips per job type. A job type whose
  cancelled hours exceed its non-delivered shows `0` instead of a negative, so the
  column overstates relative to its own subtotal, where the negative would have
  offset another job type's surplus.

If a job-type-grained visual needs a column that *does* add up, restrict it to the
additive fact columns and keep the non-additive measures on the client subtotal.

## Grain change on the fact

`client_hours_report` used to be grained `client_id` + `service_date`, with a
separate `client_hours_report_jobtype` sibling holding the job type split. The two
were the same four intermediate models with a different `group by`, identical
columns apart from `job_type_id`, and the sibling's only consumer was its own
secure view — so the sibling was folded into the base model and deleted.

Keeping both was not an option once the group slicer exists. A group slicer
**silently does not apply** to a fact with no `job_type_id` column — no error, just
two tiles side by side showing different numbers, and identical column names make
it easy to bind a measure to the wrong table.

### Deploying the change

`job_type_id` joined both the grain and the incremental merge key, so a normal run
would merge new rows against the old two-column key and leave stale rows behind:

```
dbt build --full-refresh --select +mart__client_hours_report --target prod_r1
```

Once per tenant — the care is a run parameter, so repeat it per care. care1 is the
default; for the R2 cares set `DBT_CARE` and point at that account:

```
# bash
DBT_CARE=care2 dbt build --full-refresh --select +mart__client_hours_report --target prod_r2
# PowerShell
$env:DBT_CARE='care2'; dbt build --full-refresh --select +mart__client_hours_report --target prod_r2
```

The dropped `*_JOBTYPE` models leave orphaned Snowflake objects behind — dbt does
not drop what it no longer manages. Remove them by hand, per tenant, or someone
will connect to a frozen table that has stopped refreshing:

```sql
drop table if exists analytics_mart.care_management.client_hours_report_jobtype;
drop view  if exists analytics_mart.report.client_hours_report_jobtype;
-- care2/3/5: CARE2_CLIENT_HOURS_REPORT_JOBTYPE, etc.
```

### Reconciliation that justified the fold

Run **before** the full refresh, while the old client-level table still exists
(care1 returned 0 mismatched rows, all dates):

```sql
select count(*) as mismatched_rows
from analytics_mart.care_management.client_hours_report as b
full outer join (
    select client_id, service_date,
           sum(total_scheduled_hrs)   as total_scheduled_hrs,
           sum(confirmed_payable_hrs) as confirmed_payable_hrs,
           sum(allocated_hrs)         as allocated_hrs
    from analytics_mart.care_management.client_hours_report_jobtype
    group by 1, 2
) as j
    on b.client_id = j.client_id and b.service_date = j.service_date
where b.client_id is null
   or j.client_id is null
   or abs(b.total_scheduled_hrs - j.total_scheduled_hrs) > 0.0001
   or abs(b.confirmed_payable_hrs - j.confirmed_payable_hrs) > 0.0001
   or abs(b.allocated_hrs - j.allocated_hrs) > 0.0001;
```

Confirm it is not vacuously green — the client-level table's row count should equal
the job-type table's distinct `client_id`+`service_date` count, and be lower than
its total row count.

This validates **totals only**. It passes even if every row sat on `-1`, because
`-1` rows sum into the client total too. Sizing the `-1` bucket is the separate
check that validates the job type *split*.
