# Schedule Difference Report — Power BI setup

**This one is a detail export, not an aggregate report.** One row per individual
scheduled call occurrence (`scheduleReport_diff.php`), so the table visual mostly
shows *columns*, and the DAX is (a) display formatting for the two minute columns and
(b) an optional KPI header / summary page, which legacy has no equivalent of. Nothing
here is needed to make the detail table work — see
[What actually needs DAX](#what-actually-needs-dax).

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
| Fact | `report__schedule_difference_report` | `ANALYTICS_MART.REPORT.SCHEDULE_DIFFERENCE_REPORT` | `recurr_id` + `occurrence_date` |
| Dim client | `report__dim_client` | `…REPORT.DIM_CLIENT` | `client_id` |
| Dim carer | `report__dim_carer` | `…REPORT.DIM_CARER` | `carer_id` |
| Dim job type | `report__dim_jobtype` | `…REPORT.DIM_JOBTYPE` | `job_type_id` |
| Dim date | `report__dim_date` | `…REPORT.DIM_DATE` | `calendar_date` |

**All four dimensions are mandatory here.** The display names used to sit on the fact
and were the bulk of its storage at ~100M rows, so they were removed — a visual built
on the fact alone has no client name, no carer name, no job type name and no week /
day-of-call.

**Mark `dim_date` as the model's Date table.** It is the one report view with no RLS
predicate — a calendar carries no customer data, see `report__dim_date.sql`.

**ONE relation per ACCOUNT, and the names carry no care token.** Every care in the
account is stacked into the same table, with a `source` column saying which source
schema each row came from (`macros/union_cares.sql`); the bare names the measures
below use are the real ones in every account. The per-care `CARE1_` / `CARE2_` …
relations are gone — repoint the model at the bare names.

**`source` is part of every relationship.** Client, carer and job type ids are
allocated per care and collide across them, so relating on the bare id would join
one care's row to another's — and Power BI refuses the relationship outright,
because the duplicate id breaks the "one" side.

The warehouse ships the composite key ready-made, as one integer (care and id,
`macros/source_key.sql`; Whole number / int64 in Power BI, on both sides). This fact
carries `client_key`, `carer_key` and `job_type_key`, and each dimension carries
its own. Relate on those; no calculated column is needed, and the bare ids should
stay out of every relationship. `dim_date` needs no key — the calendar is shared
and carries no `source`.

## Relationships

```
#	Relationship	Cardinality	Cross-filter
1	dim_client[client_key]   → schedule_difference_report[client_key]	1:*	Single
2	dim_carer[carer_key]     → schedule_difference_report[carer_key]	1:*	Single
3	dim_jobtype[job_type_key]→ schedule_difference_report[job_type_key]	1:*	Single
4	dim_date[calendar_date]  → schedule_difference_report[occurrence_date]	1:*	Single
```

The date slicer filters `dim_date`; the job-type slicer filters `dim_jobtype`.

**Hide from report view:** `company_id` and `location_id` — RLS plumbing, never a
slicer. Keep `recurr_id` visible-but-hidden-in-visuals (see the duplicate-row note
below); it is the only thing that makes a row unique.

> **`client_id` changed meaning.** It used to hold `residentId` (the front-end display
> id) under the name `client_id`. It is now the real `client.id`. Both are numeric, so
> an old relationship on that column joined silently to the wrong clients. The display
> id is `dim_client[client_no]`.

## Report columns → Power BI

| Column (§5) | Power BI |
|---|---|
| Client ID | `dim_client[client_no]` (residentId) |
| Client | `dim_client[full_name]` |
| Client Area | `dim_client[area_name]` |
| Workgroup | `dim_client[workgroup]` |
| Branch | `dim_client[branch]` |
| Carer | `dim_carer[full_name]` |
| Job Type | `dim_jobtype[job_type_name]` |
| Week | `dim_date[iso_week]` (or `iso_week_label`) |
| Date Of Call | `schedule_difference_report[occurrence_date]`, format `dd-mm-yyyy` |
| Day Of Call | `dim_date[day_short]` (Mon/Tue/…), sort by `day_of_week_number` |
| Schedule Start | `schedule_start` |
| Clocked In | `clocked_in` |
| Schedule Finish | `schedule_finish` |
| Clocked Out | `clocked_out` |
| Early / Late | `early_late` — already formatted, put it straight on the visual |
| Scheduled Time | `scheduled_time` |
| Worked Time | `worked_time` |
| Time Diff Minutes | `time_diff_minutes` — needs formatting, see below |
| Cancellation Reason | `cancellation_reason` |
| Cancellation Comment | `cancellation_comment` |
| TimeSheet | `timesheet_status` |
| Council Id | `dim_client[council_id]` |
| System Comments | `system_comments` |

The four time columns are **text `"HH:MM"`**, zero-padded, so they already sort
chronologically as text and need no sort-by column. `"24:00"` (midnight finish, §4.5)
sorts last, which is correct.

Legacy sorts by `event_date`, client surname, carer surname (§8).

`dim_date[iso_week]` is the match for legacy's `DATE_PART('week', …)` under
Snowflake's default `WEEK_START`. Pair it with `dim_date[iso_year]`, never with
`year` — week 1 of January otherwise lands in the previous year's bucket.

> **Duplicate rows can collapse.** A table visual groups by the fields on it, so two
> occurrences identical in every *displayed* column render as one row. Put `recurr_id`
> on the visual (last column, or narrow it to nothing) to force one row per call, or
> add `[Calls]` below as a column so a collapsed pair shows as `2`.

## What actually needs DAX

**Early / Late needs nothing** — the model ships two columns for it:

| Use | Column |
|---|---|
| Table visual, tooltips, anything displayed | `early_late` — text, already `"On time"` / `"+15"` / `"- 10"` |
| Sorting, and every measure below | `early_late_minutes` — signed integer |

Drop `early_late` on the visual and it renders exactly as legacy. Sort that column by
`early_late_minutes` (*Column tools → Sort by column*), otherwise the text sorts
alphabetically and `"+9"` lands after `"+10"`.

**Time Diff still needs formatting.** It is stored as signed integer minutes —
deliberately, so it sorts numerically and stays additive — while legacy renders it as
text. Prefer a custom format string over DAX: set it on the column itself (*Column
tools → Format*), which costs nothing, keeps the numeric sort, and keeps the blank
blank:

```
Time Diff        +0;- 0;0
```

If `Custom` is missing from the Format dropdown, set `formatString` in the TMDL
definition instead — a PBIP project keeps that in git, next to these models.

The three sections are positive / negative / zero; the negative section formats the
absolute value, so `-10` renders `- 10`, matching §4.3 exactly.

Do **not** reach for a `SELECTEDVALUE` + `SWITCH` measure to build the string instead:
`SELECTEDVALUE` returns blank when the visual row groups more than one occurrence, so
such a measure silently empties on a collapsed row (see the duplicate-rows note above),
which neither the format string nor `early_late` does. That collapse risk is the reason
Early / Late is formatted in SQL rather than in the model.

Blank means **no timesheet matched** (§4.2): the carer never clocked in against this
scheduled call. `time_diff_minutes` is additionally blank while the carer is still
clocked in (`status = 'In'`, §4.6).

## Optional — KPI header and summary page

Legacy has none of this; it is the obvious win from having the export in a semantic
model instead of a CSV. All of these are cheap (row counts and a SUM over an integer
column).

```DAX
Calls = COUNTROWS(schedule_difference_report)
```

```DAX
Cancelled Calls = CALCULATE([Calls], schedule_difference_report[status_id] = 2)
```

```DAX
Missing Timesheets = CALCULATE([Calls], schedule_difference_report[timesheet_status] = "None")
```

```DAX
Confirmed % =
ROUND(
    DIVIDE(
        CALCULATE([Calls], schedule_difference_report[timesheet_status] = "Confirmed"),
        [Calls]
    ) * 100,
    2
)
```

Punctuality, with a tolerance the user can move. Create a numeric-range what-if
parameter `On-Time Tolerance` (0 → 30 minutes, step 1); `SELECTEDVALUE(…, 0)` makes
the measures work before anyone drops the slicer on the page:

```DAX
On Time Calls =
VAR Tol = SELECTEDVALUE('On-Time Tolerance'[Minutes], 0)
RETURN
CALCULATE(
    [Calls],
    NOT ISBLANK(schedule_difference_report[early_late_minutes])
        && schedule_difference_report[early_late_minutes] >= -Tol
        && schedule_difference_report[early_late_minutes] <= Tol
)
```

```DAX
Late Calls =
VAR Tol = SELECTEDVALUE('On-Time Tolerance'[Minutes], 0)
RETURN CALCULATE([Calls], schedule_difference_report[early_late_minutes] > Tol)
```

```DAX
Early Calls =
VAR Tol = SELECTEDVALUE('On-Time Tolerance'[Minutes], 0)
RETURN CALCULATE([Calls], schedule_difference_report[early_late_minutes] < -Tol)
```

```DAX
On Time % =
ROUND(DIVIDE([On Time Calls], [On Time Calls] + [Late Calls] + [Early Calls]) * 100, 2)
```

**The `NOT ISBLANK` guard is load-bearing.** In a `CALCULATE` filter a blank compares
as zero, so `early_late_minutes >= -Tol && <= Tol` alone counts every call that has no
timesheet at all as "on time" — inflating the KPI by exactly the `[Missing
Timesheets]` count. `Late`/`Early` need no guard: blank is neither `> Tol` nor
`< -Tol`. The denominator of `On Time %` is the three buckets summed, i.e. matched
calls only, rather than `[Calls]` — otherwise unmatched calls drag the percentage down
without belonging to any bucket.

```DAX
Avg Early / Late (mins) = ROUND(AVERAGE(schedule_difference_report[early_late_minutes]), 1)
```

`AVERAGE` skips blanks, so this is over matched calls. It **nets** early against late —
a carer 10 early and 10 late averages 0. For typical *deviation* use
`AVERAGEX(schedule_difference_report, ABS(…[early_late_minutes]))`, which materialises
the column and is materially slower on this fact; put it on a summary page with a date
filter, not on the detail table.

`time_diff_minutes` is per-row minutes and therefore additive:

```DAX
Total Time Diff (mins) = SUM(schedule_difference_report[time_diff_minutes])
```

```DAX
Total Time Diff (HH:MM) =
VAR Mins = SUM(schedule_difference_report[time_diff_minutes])
VAR AbsMins = ABS(Mins)
RETURN
IF(
    NOT ISBLANK(Mins),
    IF(Mins < 0, "-", "")
        & FORMAT(INT(AbsMins / 60), "00") & ":" & FORMAT(MOD(AbsMins, 60), "00")
)
```

A calculated column for a schedule-status slicer — `status_id` is an opaque `1`/`2`
(§6) and two distinct values compress to nothing:

```DAX
Schedule Status = IF(schedule_difference_report[status_id] = 2, "Cancelled", "Active")
```

## Scheduled / worked hours are NOT summable here

`scheduled_time` and `worked_time` are text `"HH:MM"` durations — legacy display
strings. To total them you must parse:

```DAX
Scheduled (mins) =
SUMX(
    schedule_difference_report,
    VAR T = schedule_difference_report[scheduled_time]
    RETURN IF(NOT ISBLANK(T), VALUE(LEFT(T, 2)) * 60 + VALUE(RIGHT(T, 2)))
)
```

The same shape works for `worked_time` (blank when there is no timesheet or the carer
is still clocked in — the `ISBLANK` guard is required, `VALUE("")` is an error, not a
blank).

**Do not build hours reporting on this.** A `SUMX` with string functions over ~100M
rows is orders of magnitude slower than a column scan, and the numbers already exist,
additive and unrounded, in `report__client_hours_report` / `report__carer_hours_report`
(`total_scheduled_hrs`, `worked_hrs`). Use those for totals and this fact for
per-call investigation.

> **Open item.** If summed scheduled/worked minutes are genuinely wanted on this
> report, the fix belongs in the mart, not in DAX: add `scheduled_minutes` /
> `worked_minutes` integer columns next to the display strings (the minute values are
> already computed there for `time_diff_minutes`). That is the project rule — stored
> columns additive and unrounded, presentation in DAX — and this fact is the one place
> it is not followed, because legacy's export is text.

## Conditional formatting

Thresholds are a business choice — legacy colours nothing. Useful defaults, as
*Format by → Field value* measures:

```DAX
Punctuality Colour =
VAR Mins = SELECTEDVALUE(schedule_difference_report[early_late_minutes])
VAR Tol = SELECTEDVALUE('On-Time Tolerance'[Minutes], 15)
RETURN
SWITCH(
    TRUE(),
    ISBLANK(Mins), "#9E9E9E",          -- no timesheet
    ABS(Mins) <= Tol, "#2E7D32",
    ABS(Mins) <= Tol * 2, "#EF6C00",
    "#C62828"
)
```

```DAX
TimeSheet Colour =
SWITCH(
    SELECTEDVALUE(schedule_difference_report[timesheet_status]),
    "Confirmed", "#2E7D32",
    "Submitted", "#EF6C00",
    "#C62828"                          -- None
)
```

Cancelled calls read best as a row-level background driven by `[Schedule Status]`
rather than a colour on one cell — the whole occurrence is void, not one measure.

## Import or DirectQuery

> **Decided by the delivery: Import.** App-owns-data embedding runs every query as
> one service principal, and SSO to Snowflake is not available in that mode. So the
> first row below cannot happen, and neither can the second: there is no per-customer
> credential. The model imports the marts, and the "rebuild RLS as Power BI roles"
> case in the third row is what was built, as the `Tenant` role, refreshed by a
> dedicated read-only user rather than a build role. See
> [powerbi_embedded_setup.md](powerbi_embedded_setup.md). The analysis below is kept
> for the report-side trade-offs, which still apply.

**This is not a performance question first — it is an RLS question.** Protection here
is `customer_access_filter`, which resolves `current_role()` against
`meta_customer_role_map` (see the macro). So "Import or DirectQuery" is really "which
Snowflake role runs the query", and the storage mode follows from the answer:

| Delivery | Mode | Why |
|---|---|---|
| Viewers authenticate as themselves (Entra ID SSO → Snowflake OAuth) | **DirectQuery** | Each query carries the viewer's role, the secure views filter exactly as designed, and ONE semantic model serves every tenant |
| Report shipped per customer / embedded, one stored credential | **Import**, credential = that customer's reader role | RLS is baked in at refresh; the model holds one tenant's slice, which is a fraction of 100M |
| Import using a build role (`SYSADMIN` / `DBT_TRANSFORMER`) | **never** | Those roles are exempt from the filter, so the model imports every tenant into one PBIX and RLS has to be rebuilt from scratch as Power BI roles over `company_id`/`location_id`. The secure views then protect nothing |

Given SSO, **DirectQuery is the better fit for this report specifically.** The usage
pattern is investigating individual calls inside a narrow date range — a pruned
columnar scan, which is Snowflake's best case and VertiPaq's worst (a 20-column detail
table with high-cardinality `recurr_id` and free-text comment columns is close to the
least compressible thing you can put in an import model). It also means no refresh of a
100M-row fact, and it is why the format-string route above beats calculated columns —
a calculated column is materialised per row, a format string is metadata.

> **In DirectQuery, leave every customer-scoped table in DirectQuery storage mode.**
> Only `dim_date` may be Import or Dual — it is the one report view with no RLS
> predicate. The usual "Dual mode for the small dimensions" advice is actively unsafe
> here: the imported side of a Dual table is materialised under the *dataset's* refresh
> credential, not the viewer's, so a Dual `dim_client` would fill its slicer with every
> tenant's client names while the fact rows stayed correctly filtered.

### From the report's side, Import is the better report

Feasibility decides the mode, but do not mistake DirectQuery for a free choice — what
the user of *this* report feels is worse in every interaction:

| | Import | DirectQuery |
|---|---|---|
| Scrolling a 20-column detail table | in-memory, instant | a query per fetched page — visibly laggy |
| Slicer change / cross-highlight | milliseconds | one query per visual, seconds |
| 1M-row limit on a single query result | none | applies; a detail table without a narrow filter can fail with *resultset exceeds max* |
| Calculated tables (incl. what-if parameters) | supported | not in a pure DQ model — needs a composite model |
| Freshness | last dataset refresh | last dbt run |

**DirectQuery is not "live" here.** It shows the state of the mart, and the mart is an
incremental dbt model on a schedule. Chain the dataset refresh after the dbt run and
the freshness gap is minutes — which is most of DirectQuery's report-side advantage
gone.

Two traps specific to this model:

- **"Assume referential integrity"** is the main DirectQuery performance lever (INNER
  instead of OUTER joins), and it is safe **only on `client_id` and `occurrence_date`** —
  the former has an enforced relationships test, and `occurrence_date` is capped at
  the report horizon (today + 60, `macros/report_horizon.sql`) by
  `int__schedule_difference`, while `dim_date` runs to the end of the year the later
  projection horizon (`macros/projection_horizon.sql`) falls in, so it always lands
  inside `dim_date`. Do **not**
  tick it on `carer_id` or `job_type_id`: `job_type_id = -1` has no row in
  `dim_jobtype`, and a deleted carer has none in `dim_carer` (which is why those
  relationship tests are `warn`, not `error`). An INNER join silently drops exactly
  those calls — the anomalies this report exists to find.
- **The `On-Time Tolerance` what-if parameter is a calculated table** (`GENERATESERIES`),
  so a pure DirectQuery model cannot host it. Keep the parameter table in Import
  alongside the DirectQuery fact — a composite model, which is also what lets
  `dim_date` be imported.

If people need to pull the rows out rather than read them on screen, neither mode is
the answer: per-visual export limits apply to both. A **paginated report** (Report
Builder) is the right tool for a true detail export and runs happily over either mode.

DirectQuery costs a round trip per visual, so keep the detail page sparse (one table
plus slicers, no card row), turn on *Query reduction → Apply filter/slicer changes on
demand* so a half-typed filter does not fire a query, and give BI its own auto-resume
XS/S warehouse — the first query after suspend pays the resume, the rest hit
Snowflake's result cache.

In Import mode the size is dominated by `cancellation_comment`, `system_comments` (free
text, poor compression) and `recurr_id` (high cardinality, no RLE). If the model will
not fit, drop the two comment columns to a drill-through page rather than trimming the
date range further — they are read one row at a time, never aggregated.

Whichever mode, the detail page should open **filtered** — a date slicer defaulted to
the last week or two. The report is an investigation tool; there is no useful
all-history view of 100M call rows. In Import mode that default is not optional: pair
it with an incremental refresh policy on `occurrence_date` (Premium/PPU) or a
date-bounded view, or expect a multi-hour full refresh.

## Legacy fidelity notes

- **Both active and cancelled schedules produce rows** (`statusId IN (1, 2)`, §6) —
  unlike the hours reports, which are active-only. Cancellation reason / comment are
  populated only on the cancelled ones.
- **`confirmSch = 'Yes'` only.** Unconfirmed templates are excluded, which also drops
  the unassigned (`carerId = 0`) rows that `int__recurr_occurrences` admits for other
  consumers.
- **Carer state 1/2/3** (Active / Pending / Archived) — legacy's carer loop driver.
  `dim_carer` is narrower (`permissionId = 4`, `deleted IS NULL`), so a deleted carer's
  calls have no dimension row and lose their name. The relationship test warns rather
  than errors for exactly this; the fix is to widen `dim_carer`, never to drop the
  fact rows.
- **`clocked_in` shows even when `status = 'In'`.** §4.6 blanks only `logOut` and
  `worked` — the carer *has* clocked in. The skeleton in §8 blanks `clocked_in` too;
  that is a bug in the skeleton and is not reproduced.
- **No-show occurrences are excluded**, matching `returnDates()` step 5 (§4.1).
- **Timesheet matched exactly on `carerId + recurrId + logDate`** (§3.4), left joined,
  so a scheduled call with no timesheet still produces a row with `"None"`.
- **`job_type_id = -1`** means the source recorded no job type (project-wide
  convention). `dim_jobtype` holds no `-1` row, so those calls show a blank job type
  and **a job-type slicer excludes them** — same behaviour as the hours reports, and
  the same reason: legacy's inner join to `jobtype` dropped them outright.
- **Location scoping is a report filter, company scoping is RLS.** Legacy ran per
  `locationId`. In the embedded report, the `Tenant` role cuts the model to the
  customer's company, and the app sets `SCHEDULE_DIFFERENCE_REPORT[location_id]` as a
  filter (the `Report Ready` gate). Direct Snowflake readers still go through
  `report__schedule_difference_report`, which filters on the `company_id`/`location_id`
  carried on each row.
