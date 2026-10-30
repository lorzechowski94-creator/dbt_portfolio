# Semantic view metrics for the MCP server

## Why this document exists

Every mart in this project stores **only additive, unrounded columns** and pushes the
real report figures into DAX. That was deliberate — a non-additive figure cannot be
precomputed for an arbitrary date range. You cannot store "carers in January" and
"carers in February" and add them to get carers in Q1, because a carer working both
months counts twice.

Power BI computes those figures with DAX, *after* the date filter. The MCP server has
no equivalent: the warehouse holds no definition of `Continuity %`, `Non-Delivered
(excl)` or `A v S`. Asked "what was continuity in March", the server sees `visit_count`
and `carer_id` and will return something plausible and wrong, with no warning.

A Snowflake **semantic view** is where those definitions can live on the warehouse
side: its `metrics` are expressions evaluated at query time, i.e. at the same moment
DAX evaluates. This document classifies every measure in the `powerbi_*_measures`
docs by whether it can go there.

**Point the semantic view at the `REPORT` schema, never at `CARE_MANAGEMENT`.** The
report views are secure and carry `customer_access_filter`, so RLS still applies to
MCP queries. Built over the marts, a semantic view would expose every customer's data
to every reader.

## The buckets

| | meaning |
|---|---|
| **A — additive** | a plain `SUM` / `COUNT` is already correct; expose as a fact and a trivial metric |
| **B — expressible** | non-additive, but pure arithmetic over aggregates: translates 1:1 |
| **C — needs a decision** | translatable only after someone settles a definition question |
| **D — out of scope** | display formatting or Power BI plumbing; no place in a semantic view |
| **E — not expressible** | requires rewriting the caller's filter context, or aggregating an aggregate, which a metric cannot do |

## Translation patterns (bucket B)

One trap before the table: **a two-argument `IF` is not `else 0`.** `IF(Total > 0, …)`
with no else returns BLANK, and the SQL equivalent of BLANK is an un-matched `CASE`,
i.e. NULL — not zero. Translating those to a bare `div0(…)` turns "not measurable"
into "0%", which reads as a real, bad number. Every ratio below whose denominator can
be zero *while rows are present* therefore keeps an explicit gate; only a `count(*)`
denominator is safe ungated, since it is zero only when nothing is returned at all.

| DAX | semantic view metric |
|---|---|
| `IF(x > 0, a, b)` | `case when x > 0 then a else b end` |
| `IF(x > 0, a)` — no else | `case when x > 0 then a end` (NULL, **not** 0) |
| `MAX(0, …)` | `greatest(0, …)` |
| `DIVIDE(a, b) * 100` | `div0(a, b) * 100` |
| `ROUND(…, 2)` | `round(…, 2)` |
| `DISTINCTCOUNT(c)` | `count(distinct c)` |
| `COUNTROWS(t)` | `count(*)` |
| `AVERAGE(c)` | `avg(c)` |
| `CALCULATE([m], t[c] = v)` | `count_if(c = v)` / `sum(case when c = v …)` |
| a balance: `CALCULATE(SUM(c), DIM_DATE[date] = LastDay)` | `non additive by (<date dimension>) as sum(c)` — the last day per group |
| a ratio of measures from two facts | a derived metric (no table alias) over the two metrics |

## Client hours — `client_hours_report`

| Measure | Bucket | Metric |
|---|---|---|
| the 18 stored `_hrs` columns | A | `sum(<col>)` |
| `Non-Delivered (hrs)` | B | `greatest(0, sum(non_delivered_incl_cancelled_hrs) - sum(cancelled_timesheet_billed_hrs) - sum(cancelled_timesheet_not_billed_hrs))` |
| `A v S Difference (hrs)` | B | `case when sum(total_scheduled_hrs) > 0 then round(sum(allocated_hrs), 2) - round(sum(total_scheduled_hrs), 2) else 0 end` |
| `Billable Schedule (hrs)` | B | `case when sum(total_scheduled_hrs) > 0 then sum(total_scheduled_hrs) - sum(cancelled_timesheet_not_billed_hrs) else 0 end` |
| `Billable v Confirmed (hrs)` | B | `<Billable Schedule> - sum(total_confirmed_billed_hrs)` |
| `Total Deliverable (hrs)` | **C — not implemented** | the `Sched = 0` branch reads `SELECTEDVALUE(dim_client[state_id])` — see below |
| `Total Scheduled (HH:MM)`, `Total Confirmed (HH:MM)` | D | formatting; expose the hours, let the caller format |

## Carer hours — `carer_hours_report`

| Measure | Bucket | Metric |
|---|---|---|
| `scheduled_hrs`, `confirmed_payable_hrs`, `worked_hrs`, `contracted_hrs`, the two counts | A | `sum(<col>)` |
| `Over/Under Contracted (hrs)` | A | `round(sum(over_under_contracted_hrs), 2)` |
| `Confirmed Phone vs Admin (%)` | B | `case when sum(phone_admin_total_count) > 0 then round(div0(sum(carer_confirmed_count), sum(phone_admin_total_count)) * 100, 2) end` — the gate is **required**, see below |
| `Contracted (hrs, all job types)` | D | exists only to defeat a Power BI slicer; in SQL the caller simply omits the job type |
| the five `HH:MM` measures | D | formatting |

> **Contracted sits on the no-job-type row.** `cmContractsHours` carries no jobType, so
> a question filtered to a real job type legitimately returns zero contracted hours.
> Worth a synonym or a description on the metric, or MCP answers will look wrong.

## Continuity — `continuity_report`

| Measure | Bucket | Metric |
|---|---|---|
| `Visits` | A | `sum(visit_count)` |
| `Area` (the "Area Not Assigned" fallback) | B | a *dimension* expression, not a metric: `coalesce(nullif(trim(area_name), ''), 'Area Not Assigned')` — include it so MCP groups exactly as Power BI does |
| `Carers` | **C** | legacy is a per-client distinct then summed — see below |
| `Continuity`, `Continuity %` | **C** | both derive from `[Carers]`; the `carers = 1 -> 100%` override is a plain `case` and translates fine |
| `Year Visits`, `Year Carers`, `Year Continuity`, `Year Continuity %` | **E** | see below |
| `Continuity Colour` | D | Power BI conditional formatting |

## Schedule difference — `schedule_difference_report`

| Measure | Bucket | Metric |
|---|---|---|
| `Calls` | A | `count(*)` |
| `Cancelled Calls` | B | `count_if(status_id = 2)` |
| `Missing Timesheets` | B | `count_if(timesheet_status = 'None')` |
| `Confirmed %` | B | `round(div0(count_if(timesheet_status = 'Confirmed'), count(*)) * 100, 2)` |
| `Total Time Diff (mins)` | A | `sum(time_diff_minutes)` |
| `Avg Early / Late (mins)` | B | `round(avg(early_late_minutes), 1)` |
| `On Time Calls`, `Late Calls`, `Early Calls`, `On Time %` | **C** | the tolerance is a user-movable parameter — see below |
| `Schedule Status` | B | a dimension expression: `case when status_id = 2 then 'Cancelled' else 'Active' end` |
| `Time Diff (HH:MM)` | D | formatting |
| `Punctuality Colour`, `TimeSheet Colour` | D | Power BI conditional formatting |

## Carer qualifications / HR compliance — `carer_qualification_report`

Every metric here is scope-bound: `state_id in (1, 2)` is folded into each expression,
so nothing in this view is a plain `sum`/`count` even where the underlying figure is
additive. See "Why this fact flipped" below for why that scope is not left to the caller.

| Measure | Bucket | Metric |
|---|---|---|
| `Total HR Files` | B | `count(distinct case when <scope> then qualification_record_id end)` — **not** `count(*)`, which counts the carer-holds-no-files rows as files |
| `Non-Compliant Staff (Expired)` | B | `count(distinct case when <scope> and expire_status = 'expired' then carer_id end)` — staff, not files |
| `Expiring Staff (Alert Window)` | B | the same shape on `is_expiring` |
| `Valid Files`, `Not Actioned Files`, `Expired Files` | B | `count_if(<scope> and expire_status = …)` — the three partition the files |
| `Expiring Files` | B | `count_if(<scope> and is_expiring)` — a **subset** of `valid_files`, never a fourth bucket |
| `Renewed (Last 30 Days)` | C → **implemented frozen** | `renewed_files_30d`; the window is in the identifier and the comment, exactly as `on_time_pct_15` freezes its tolerance |
| `Days Overdue` / `Days Remaining` | B | `max(case … then -days_to_expiry end)` / `min(case … then days_to_expiry end)`; at file grain one value per row, above it the worst case in the group |
| `Renewed (Last Calendar Month)` | D | not the report's window. Add as a named variant if someone asks; do not re-point the 30-day metric |

Two things this view does NOT expose, both deliberate: `state` as a dimension (the scope
is inside the metrics, so a state filter could only contradict them) and `expire_status`
(the export's own keyword — two status vocabularies would dilute the model's choice
between them for no gain).

`report__dim_carer` is not a table in this view either. It filters `deleted is null`
while the fact keeps deleted carers, so joining it would drop their files from every
figure; `area`, `position` and the name parts come off the fact instead.

### Stored flags, not query-time recomputation

`expire_status`, `is_expiring` and `days_to_expiry` are computed in SQL at the daily
refresh. A metric could recompute the expiry test at query time (`count_if(expired <
current_date())`) and would then be **fresher than Power BI** between refreshes — and
would disagree with it. These metrics read the stored columns instead: matching the
report is worth more than being independently right, which is the same trade this
document already makes by refusing to publish a `Carers` figure that disagrees with the
report. The daily-refresh caveat is in the view's `comment =` rather than fixed.

## Workforce capacity — `workforce_capacity` + `workforce_movement`

The one view over two facts. They share the location and the date, and the report
divides one by the other (`Avg Contracted hrs per Customer`), which needs both in one
view. `source` therefore sits on `dim_location`, which both facts reach, rather than on
a fact.

| Measure | Bucket | Metric |
|---|---|---|
| the stored `_hrs` columns, and booked hours | A | `sum(<col>)`, totals over the range |
| `Staff Contracted hrs/wk`, `Staff Available hrs/wk`, `Customer Contracted hrs/wk`, `Scheduled hrs/wk`, `Booked hrs/wk` | B | `sum(<col>) * 7 / count(distinct calendar_date)` — see "Weeks" below |
| `Capacity Utilisation %` | B | `case when sum(contracted_hrs) > 0 then round(sum(scheduled_hrs) / sum(contracted_hrs) * 100, 2) end` |
| `Projected Headroom hrs/wk` | B | `headroom_per_week`, contracted minus booked per week; the outlook is only its date range |
| `Staff Joined` / `Left`, `Customers Joined` / `Left`, the net changes | A | `sum(<col>)` |
| `Active Staff`, `Active Customers` | B | `non additive by (headcount_date) as sum(active_*)` — see "Headcount" below |
| `Avg Contracted hrs per Customer` | B | derived: `customer_contracted_per_week / customer_headcount`, gated on a headcount above 0 |
| `Unfilled hrs/wk` | **E** | an aggregate of an aggregate — see below |
| `Estimated Additional Customers` | **E** | two date ranges in one figure — see below |
| every `(period)`, `(prior)`, `Δ`, `Δ %` and `(trend)` measure, `Period Start` / `End` | **E** | they rewrite the date filter; query each range |
| the `Card`, `Flip Card`, `Subtitle` and `Outlook Insight` measures | D | presentation |

`staff_available` and `staff_available_per_week` read availability as capped at 24 h per
carer per day (`int__workforce_available_hours`). Before the cap, one malformed window on
R2 PROD made the figure meaningless for the whole account.

### Weeks

DAX divides by `COUNTROWS(DIM_DATE) / 7`, the calendar days in the filter. A metric
belongs to one logical table, and a day count on `dim_date` could not be grouped by
location, which `dim_date` does not reach. So the per-week metrics count the distinct
dates that hold a capacity row for the group. The two agree wherever a contract runs:
`int__workforce_contracted_hours` gives a contract a row on every day, 0 on its days off,
so a location with one contracted carer has a row every day. They differ for a location
with no contract at all whose visits fall on weekdays only (its per-week figures read up
to 7/5 high), and for a range that starts before a location's first record, which counts
from that record.

### Headcount

`active_staff` and `active_customers` are end-of-day balances: they add up across
locations, never across days. `NON ADDITIVE BY` (Snowflake, March 2026) sorts the rows by
the named dimension and aggregates only the last ones, per group, so each month of a trend
shows its last day and each location its own. That is DAX's `Active Staff`, and unlike a
`CASE` on the maximum date it holds at any grouping. Every documented example names a
dimension of the metric's own table, so the metrics name `movement.headcount_date`, the
movement row's own date, not `dates.calendar_date`.

A series whose rows stop before the range ends is not undercounted. The fact drops a day
only when nobody is active and nothing moved, so the last row of a stopped series is the
day its balance reached 0.

No movement facts are declared, because a caller may sum a fact. Only a derived metric may
read a semi-additive one, which is one reason `avg_contracted_per_customer` is derived;
the other is that it spans two tables.

### `Unfilled hrs/wk` — not expressible

DAX clips `contracted - scheduled` at zero per carer per ISO week, then sums. That is an
aggregate of an aggregate, the shape of continuity's `Carers`, and a metric has no
iterator over carer × week. The nearest expressible figure, the net gap, lets one carer's
overtime fill another's empty contract and reads lower than the report. An absent measure
beats one that quietly under-reports.

### `Estimated Additional Customers` — not expressible, but answerable

`INT(Projected Headroom / Avg Contracted hrs per Customer)`, 0 when the headroom is not
positive. The headroom comes from the outlook (the three whole months after the current
one), the average from the selected past period: two date ranges in one figure, and a
metric sees one filter. As with the `Year …` family, a description closes the gap: the
view comment gives the model the recipe (two queries, divide, round down).

### The period

The report compares a rolling period ending yesterday (default: the last 6 months) with
the same length just before it. A semantic view has no slicer, so the view comment states
that default. Without a date range the per-week metrics would average the whole history
plus the outlook, which no question means.

### What stays out

- **The area.** The facts carry `area_id` for the embedded report's `TenantArea` role. It
  is an id with no name, so there is nothing to group by.
- **The carer.** The demand row's carer -1 matches no one, and `dim_carer` holds current
  carers only.
- **The job type.** Contracted and available hours carry none, so a job type filter would
  cut demand but not supply. The report has no Service Line slicer for the same reason.

## Plan & assessment dates — `plans_taken_report` + `assessments_report` + `skin_assessments_report`

What is due for review, one list per tab of the legacy Plan & Assessment Dates page
([powerbi_plan_assessment_dates_setup.md](powerbi_plan_assessment_dates_setup.md)): care
plans by review date, assessments by next assessment date, wounds by review date. One view
over the three, so a question can take plans, assessments and wounds together ("what is
due next week"). They share the location and the due date: one `dates` table with a
relationship from each list, as one date window covers the three tabs of the page.
Assessments and wounds also share the client (`report__dim_client`); plans cannot, since a
plan can be a carer's and holds no `client_key`, so they keep their own person dimensions.
`source` sits on the location, as in the workforce view.

| Measure | Bucket | Metric |
|---|---|---|
| `Plans Due` | A | `plans_due`, `count(plan_taken_key)` under the due-date filter |
| `Plans Not Completed` | A | `plans_due_not_completed`, `count_if(is_completed = false)` |
| `Assessments Due` | A | `assessments_due`, `count(assessment_key)` |
| `Wounds Due` | B | `wounds_due`, `count(distinct case when is_wound_healed = false then wound_key end)`: wounds, not entries |
| the three added up | B | `reviews_due`, a derived metric, each part `coalesce`d to 0 |
| `Reviews Overdue` (Plans Taken), `Assessments Overdue`, `Wounds Overdue` | **C → implemented as the `_latest` metrics** | `plans_due_latest` (`is_superseded = false`), `assessments_due_latest` (`is_latest_of_type`), `wounds_due_latest` (the latest entry, not healed), `reviews_due_latest`; over a range ending yesterday they are the draft overdue figures |
| `Days To Review` | D | a per-row display value; the due date is a dimension |
| `Person State Colour`, `Client State Colour` | D | Power BI formatting |

**A wound is not a row.** The skin table has one row per entry, the first assessment of a
wound and each review: 43k entries for 17.7k wounds in R2 care2. The page lists a wound
once, when any of its entries has a review date in the window, and drops it when its latest
entry is healed. `wounds_due` does both, and the relationship to `dates` runs on the
entry's review date for that reason. `wounds_due_latest` counts the latest entries only, so
under a date filter it counts the wounds whose current review is due in the range, and
with none every open wound.

**Every version is listed.** The page lists superseded plan versions and assessments that a
newer one of the same type replaced, and so do the three `_due` metrics. The `_latest`
metrics count the current one only. Over a range ending yesterday they are the overdue
figures the Power BI doc drafts; the definition is not confirmed, so the view comment tells
the model to say so. Many wounds are never marked healed: only 233 of care2's 8,750 open
wounds have a review date ahead (2026-10-28), so an overdue wound count includes abandoned
ones.

**Plans are clients' and carers'.** `person_type` splits them; assessments and wounds are
clients' only. The view comment lists which dimension goes with which metrics: the person
dimensions with plan metrics, the client ones with assessment and wound metrics, and the
location, `source` and the due date with all of them, which is why `reviews_due` breaks
down by those alone.

**The state is a filter, not a scope.** Every list keeps Active, Pending and Archived
people, as the Power BI model does, and the view comment makes Active the default, as the
page is. It has to be filtered twice, `person_state` for plans and `client_state` for the
other two. `client_state` is built from `report__dim_client.state_id` with the labels the
lists use; that table's `status_label` comes from the status lookup and is something else.

**Wound data is not in every care yet.** `cmSkinAssessments` was loaded into the R2 cares
in October 2026; R1 and R3 were not checked. Where it is missing, wound metrics are empty,
not zero, and the view comment says so.

**What stays out:** the assessment note and the wound entries' own names and dates (free
text and row detail, which can hold health details), who started and completed a plan and
when (the Plans Taken report's question), and the Work Group / Branch texts, which are
comma-joined names that would group by combinations.

## Task review — `task_review_report`

One row per scheduled task slot per day per result recorded on it, the full history and
the next 60 days ([powerbi_task_review_setup.md](powerbi_task_review_setup.md)), the port
of the legacy Digital Task Review list. Added on 2026-10-29 with the report. It answers
how many tasks were completed, missed or left unrecorded, and how many are due in the
coming days.

| Measure | Bucket | Metric |
|---|---|---|
| `Scheduled Slots` | B | `scheduled_tasks`, `count_if(is_latest_for_slot = true)` |
| `Expected Tasks` | B | `expected_tasks`, the same with `coalesce(status_id, 0) != 7` |
| `Completed`, `Partially Completed`, `Not Completed`, `Other`, `Missed`, `Due`, `Cancelled` | B | `completed_tasks` … `cancelled_tasks`: the slot count with `status_id` 1, 3, 4, 2, 5, 6, 7 |
| `Not Recorded` | B | `not_recorded_tasks`: no result, `scheduled_date <= current_date()` |
| `Rows` | A | `results_recorded`, the rows with a result, as the legacy page lists them |
| `% Completed` | **C — not implemented** | the definition is still a draft in the Power BI doc: whether Partially Completed counts, and whether today's slots not due yet do |
| `Has Data` | D | Power BI slicer plumbing |

**A row is a result, not a task.** A slot recorded twice, or marked Due and then
Completed, has a row per result, so a row count over-counts tasks. Every task metric
counts only the rows flagged `is_latest_for_slot`, one per slot, by its latest result.

**A slot after today is a forecast** from the current schedule with nothing recorded.
`not_recorded_tasks` stops at today, and the `outcome` dimension reads "Not due yet" for an
empty future slot and "Not recorded" for an empty past one, so neither a count nor a
grouping files a future task under a failure.

**An empty slot is not always a task left undone.** The app writes Missed for a slot
nobody completed, so `missed_tasks` is the figure for tasks not done. A slot with nothing
at all is often a location that schedules tasks but does not record them in the app: in
DEV care1 one location holds 1.24M of 2024's 2.34M empty slots, and at least six others
recorded nothing in 2024. The view comment tells the model to say so when the figure is
large.

**The client's state** is built from `report__dim_client.state_id`, as in the plan &
assessment dates view, and the view comment makes Active the filter for current clients.
The default grouping is per client, as the legacy list is, and per task for task
questions.

**What stays out:** the comment (free text, which can hold health details), the time
recorded and result created stamps (row detail, not a grouping), and the Work Group /
Branch texts (comma-joined names).

## All carers — `all_carers_report` + its two bridges

A list with no Power BI measures, so the metrics are defined here. Why a list earns a
view at all is under "Which facts earn a semantic view" below.

| Figure | Bucket | Metric |
|---|---|---|
| Carers on the list | A | `carer_count`, `count(carer_key)` on the carer table |
| Active carers | A | `active_carers`, `count_if(state = 'Active')` |
| Carers per workgroup / branch | B | `carers_by_workgroup`, `count(distinct carer_key)` on `report__bridge_carer_workgroup` |
| Carers per tag | B | `carers_by_tag`, `count(distinct carer_key)` on `report__bridge_carer_tag` |

**The breakdowns live on the bridges.** Both bridges reference the carer table, so their
metrics reach every carer dimension (state, status, area, location), but a metric on the
carer table cannot reach a bridge's dimensions. `carer_count` by branch is therefore not a
query the view accepts; `carers_by_workgroup` is. The bridge is at carer grain
(`mart__bridge_carer_workgroup`) for this reason: through an area-grain bridge no metric
could count carers per branch at all.

**Branch, workgroup and tag figures overlap.** An area can sit in several workgroups, and
a carer can hold several tags, so one carer counts under each, and the rows sum to more
than `carer_count`. It is the job type group trap on carers, and the distinct count is
what keeps each single figure right. Workgroup or branch and tag cannot be combined in one
question, since they sit on two bridges with no path between them.

**Nobody is left out for their area.** The list keeps every carer of the location, as
its legacy page does (`int__all_carers`, decided 2026-10-27). A carer whose area is in no
live workgroup counts in `carer_count` and `active_carers` but has no row in the
workgroup bridge, so the workgroup and branch figures can also add up to less than the
total. A workgroup with no live branch has a blank branch, as in the client view. The view comment sends staff-over-time questions to `workforce_capacity_sv` and
makes Active the default state here.

**Branch is not the location.** The workforce view gives the location the synonym
`branch`, because that report labels it so. Here `branch_name` is `cmLevelBranch`, a
grouping of workgroups inside a location, and the location keeps only `location` and
`office` as synonyms.

**What stays out:** phone, email, address and post code (personal data with no grouping
value); gender, nationality, transport type, pay cycle and the status change date, which
the legacy page hides by default, so they are hidden here too (decided 2026-10-23; the
area is hidden there as well, but it is the reason this view exists); the status comment
(free text), `known_as` and the two icon flags. With the status change date gone the view
has no dates table: it holds the current state only.

## All clients — `all_clients_report` + its three bridges

The all carers view on the client list, with one bridge more. Everything argued under
"All carers" above holds here with carer read as client; only the differences are below.

| Figure | Bucket | Metric |
|---|---|---|
| Clients on the list | A | `client_count`, `count(client_key)` on the client table |
| Active clients | A | `active_clients`, `count_if(state = 'Active')` |
| Clients per workgroup / branch | B | `clients_by_workgroup`, `count(distinct client_key)` on `report__bridge_client_workgroup` |
| Clients per tag | B | `clients_by_tag`, `count(distinct client_key)` on `report__bridge_client_tag` |
| Clients per job type | B | `clients_by_job_type`, `count(distinct client_key)` on `report__bridge_client_job_type` |

**Job type is the third overlapping breakdown.** `client.jobTypes` lists several job types
per client, so a client counts under each of them, the same trap as tags. It is the job
types on the client record, not the job type of a visit: hours by job type stay with
`client_hours_sv`, and the view comment says so. Workgroup or branch, tag and job type
sit on three bridges with no path between them, so no two of them combine in one question.

**As for carers, nobody is left out for their area.** The client list keeps every
client of the location, as its legacy page does (`int__all_clients`). A client whose area
is in no live workgroup counts in `client_count` and `active_clients` but has no row in
the workgroup bridge, so the workgroup and branch figures can also add up to less than the
total. A workgroup with no live branch has a blank branch, which the branch breakdown
shows as one more group. Customer numbers over time stay with `workforce_capacity_sv`.

**What stays out:** phone, email, address, post code and date of birth (personal data
with no grouping value); gender, council id and the status change, first contact and
service commenced dates, which the client page hides by default (the all carers rule);
the status comment (free text) and the three icon flags (private note, future status,
location not confirmed). The client page hides area and tags by default too, but both
are breakdowns the view exists for, so they stay in, as area does in the all carers view.
With every date out the view has no dates table: it holds the current state only.

## The four decisions (bucket C and E)

### 1. `Carers` — and therefore all continuity figures

Legacy, and the current DAX, is a per-client distinct count summed over clients:

```DAX
SUMX( VALUES(continuity_report[client_key]), CALCULATE(DISTINCTCOUNT(carer_key), …) )
```

so a carer serving two clients counts twice. That is an **aggregate of an aggregate**,
and a semantic view metric is a single aggregate expression over the fact — there is no
iterator over a grain. It also cannot be precomputed in a view, because the per-client
distinct must form *after* the date filter. Same non-additivity, one level up.

What *is* expressible is the global distinct, `count(distinct carer_id)` — but that is a
**different number**, systematically producing a higher continuity %.
`powerbi_continuity_report_measures.md` already records the choice between the two as an
open business decision.

**Recommendation: leave `Carers`, `Continuity` and `Continuity %` out of the semantic
view until that decision is made.** Better that MCP answers "I don't have that measure"
than that it returns a continuity figure disagreeing with the Power BI report, with
nothing on screen to say which is right. If the global distinct is later chosen, add it
under a name that says so.

### 2. `On Time %` and its three bucket measures

The tolerance is a Power BI what-if parameter the user drags (0–30 minutes). A semantic
view metric takes no runtime argument, so the tolerance has to be frozen.

**Careful with the default.** The four KPI measures default to
`SELECTEDVALUE('On-Time Tolerance'[Minutes], 0)` — exact punctuality. Only
`Punctuality Colour` defaults to 15. So freezing at 15 does *not* reproduce an
unsliced Power BI report; it answers a different question, and picking 15 because
"that's the default" is simply wrong about which default.

**Implemented as:** `on_time_calls_15`, `late_calls_15`, `early_calls_15`,
`on_time_pct_15` — the tolerance is in the identifier and in a `comment =` clause the
MCP server can read, so nothing about it is implicit. Publish further variants
(`on_time_pct_5`, `on_time_pct_30`) rather than re-pointing these. Still needs a
business call on which figure is "the" on-time number.

Keep the `NOT ISBLANK` guard when translating: `early_late_minutes between -15 and 15`
in SQL already excludes NULLs, but the denominator must stay the three buckets summed,
not `count(*)`, or unmatched calls drag the percentage down without belonging to a
bucket.

### 3. `Total Deliverable (hrs)`

**Not implemented** — the macro leaves it out, for two reasons rather than one.

The `Sched = 0` fallback branch reads `SELECTEDVALUE(dim_client[state_id])`, i.e. it
needs a single client in context. Translating that as `max(clients.state_id)` fails in
two ways: it is a **cross-table aggregate**, which needs `USING ( <relationship_name> )`
and therefore named relationships (the macro's are unnamed); and above client grain
`max()` is not equivalent to `SELECTEDVALUE` — since `state_id` is 1/2/3, `max() = 1`
holds only when *every* client in scope is active, so one pending client silently flips
the whole group to the else-0 branch, under-reporting. It also sees only clients joined
to fact rows, while `SELECTEDVALUE` sees clients with no rows in the range.

The report itself confirms the problem rather than excusing it. Its `Column Visibility`
field parameter puts this measure in `SharedFields`, crossjoined with *all four* views —
so it is shown in "Client Hours Area" and "Client Hours Branch" too, both of which sit
above client grain. There `SELECTEDVALUE(dim_client[state_id])` is blank and the `Sched = 0`
fallback simply never fires. A `max(clients.state_id)` translation would not reproduce that:
it returns a value, and the wrong one, in exactly the views where the measure is used most.

To bring it back: either restrict it to client-grain questions and say so in a
`comment =` clause, or rewrite the branch as a per-row condition
(`sum(case when clients.state_id = 1 then … end)`) so it aggregates honestly.

(`state_id` **is** on `report__dim_client` — [mart__dim_client.sql:50](../models/marts/mart__dim_client.sql#L50),
surfaced by the view's `select s.*`. It is now documented in `_mart__models.yml` too,
with the same 1/2/3 labels as `int__client_information`.)

### 4. The `Year …` family — not expressible

These re-apply the user's selection snapped out to whole calendar years:

```DAX
CALCULATE([Visits], REMOVEFILTERS(dim_date), TREATAS(SelYears, dim_date[year]))
```

A metric cannot rewrite its caller's filter, so this whole family is unavailable.

**In practice it does not matter.** The Year measures exist so both halves of the report
can sit on one row under one date slicer. An MCP caller has no such constraint — asking
"continuity for all of 2025" gives exactly the number `Year Continuity` would show. The
gap to close is a *description* on the date dimension telling the model to widen the
range to whole years when the question is about a year, not a metric.

## Job type group — a many-to-many dimension, on the three job-type facts

`report__dim_jobtype_group` + `report__bridge_jobtype_group` are now logical tables in
`client_hours_sv`, `carer_hours_sv` and `schedule_difference_sv` (not `continuity_sv` —
that fact has no job type), exposing `group_name` as a dimension.

This is the report's real grain, not an extra: the client hours `Report Grouping` field
parameter groups its "Client Hours Jobtype" view by `DIM_JOBTYPE_GROUP[GROUP_NAME]` — the
individual `JOB_TYPE_NAME` is not a grouping column there at all.

Two things about it are true and neither is a defect to fix:

**Group figures overlap.** The bridge explodes `jobtypeGroupName.jobTypeList`, so a job
type can sit in several groups — 13 do in care2. Its hours therefore count under every
group it belongs to, and the group rows sum to more than the overall total. Power BI does
exactly the same through the bidirectional cross-filter on the bridge, so this is fidelity,
not drift. Folding one group onto `dim_jobtype` to make it additive would be the drift:
a job type in two groups would show under one, understating that group.

**Group figures exclude the no-job-type rows.** The `NO_JOB_TYPE (-1)` bucket belongs to no
group, so client-level non-delivered hours parked there vanish from any group-level figure;
in carer hours the same rule removes *all* contracted hours, which sit only on the
no-job-type row. Power BI works around it with `CALCULATE([m], ALL(dim_jobtype_group),
ALL(bridge))`. A metric cannot rewrite its caller's filter, so there is no equivalent here
— only the `comment =` on the dimension, which the MCP server can read.

**Unverified:** reaching a group means fact → `job_types` → bridge → `job_type_groups`, and
the middle hop runs against the declared relationship direction (one-to-many). Whether
Snowflake resolves that at all is an open question that only executing the DDL answers. If
it is rejected, delete the two tables, the two relationships and the dimension from all
three views and say in the MCP tool description that grouping by job type group is
unavailable.

## What deliberately stays out

- **Every `HH:MM` measure.** A metric returning text is terminal — nothing can aggregate
  it further. Expose minutes or hours and let the caller format.
- **Every `… Colour` measure.** Power BI conditional formatting.
- **`Contracted (hrs, all job types)`.** It exists to defeat a slicer; SQL has no slicer.

## The grain of the answer needs a default

The Power BI report never leaves this implicit: its `Report View` table lists four views —
Client Hours, Client Hours Jobtype, Client Hours Area, Client Hours Branch — and the caller
has one selected, defaulting to the first. A semantic view has no such selector, so
"what were the scheduled hours in March" arrives with no grain at all and the model picks
one, or none, silently.

Each view therefore states its default grouping in its own `comment =`, and the same
sentence belongs in the MCP tool `description`, which is what the model reads *before* it
queries anything. Client hours defaults to per client, matching the report. Carer hours,
continuity and schedule difference default to the grain of their own subject. HR compliance
and workforce capacity default to no grouping, because their reports headline totals.

Two notes on why it is written as a default rather than as "ask the caller first":

- **A comment is a hint, not a constraint,** and models answer rather than ask. A stated
  default is something a model can simply follow; an instruction to interrogate the user
  depends on client behaviour nobody here controls.
- **Grain is not only presentation.** The non-additive metrics are evaluated per group, so
  `a_v_s_difference` and `billable_schedule` genuinely differ between a per-client and a
  per-branch answer — exactly as they do between two views of the report. Picking a grain
  silently is therefore picking a number silently.

## Which facts earn a semantic view

One semantic view per report, over its facts, and the views here are the ones whose
measures are **wrong if naively summed**. That is the bar, not coverage of the report
layer. Workforce capacity clears it on almost every figure: hours per week divide by the
length of the range, utilisation is a ratio, and a headcount is a balance.

`birthday_report` does not meet it: one row per person, no measures, nothing to get
arithmetically wrong. A semantic view over it would add access, not correctness — and a
list is what Cortex Analyst handles worst, since it answers with grouped aggregates, so
"whose birthday is in October" needs the name as a dimension and a token count metric to
return what is really just a list. `anniversary_report` is the same shape, one row per
carer and no measures, and stays out for the same reason.

`assessments_report` and `skin_assessments_report` are IN, as one view with
`plans_taken_report`, which had none of its own: its counts are additive. Together they
answer what is due for review, and the naive count is wrong in each list: a wound has a
row per entry, a healed wound is never due, and every list keeps the versions that a newer
one replaced. See "Plan & assessment dates" above.

`task_review_report` is IN: a row is a result, not a task, so a row count over-counts
slots recorded twice; slots after today are a forecast that a naive "nothing recorded"
counts as undone; and an empty slot often means a location that does not record tasks in
the app, not a task skipped. See "Task review" above.

`all_carers_report` is a list of the same shape and is IN, because of the breakdowns
people ask it for: carers per area, workgroup, branch or tag. Workgroups, branches and
tags overlap, so a naive count per group sums to more than the total, and a row count on
the workgroup bridge counts a carer twice under one branch. That is the bar. The list
itself (names, phones) is still not what the view is for; see "All carers" above.
`all_clients_report` is IN for the same reason, with job types as a fourth overlapping
breakdown; see "All clients" above.

### Why this fact flipped

`carer_qualification_report` used to fail the same test, and this document said so: "how
many carers have qualifications expiring next month" is `count_if(expire_date < …)`, which
is additive, so plain SQL would get it right too. That was accurate while the fact was a
flat export with no measures on it. The HR compliance dashboard put four KPI definitions
on the same rows, and the verdict flips — the naive query is now wrong in five ways, four
of them invisible in the result:

1. **Staff vs files.** Every non-compliant figure is a distinct count of carers. A row
   count answers with files and is silently larger.
2. **The no-record rows.** A carer holding no files still has a row, so `count(*)` counts
   them as files. `count(distinct qualification_record_id)` — null on exactly those rows
   — is what excludes them.
3. **`is_expiring` overlaps `valid`.** Summing the statuses double counts.
4. **The alert window is per file type** (`cmQualificationsType.alertBefore`). A caller
   writing SQL guesses 30 days and returns a plausible wrong number; the flag on the row
   is already resolved against the right window.
5. **The report's scope is a Power BI report-level filter.** `state_id in (1, 2)` exists
   nowhere in the warehouse, so an unscoped answer includes archived and deleted staff and
   silently disagrees with the dashboard's headline.

Only the fifth is a scope problem rather than a measure problem, and it is the one a
semantic view is uniquely placed to fix — which is why the scope is baked into every
metric rather than documented as a hint. This is the same reasoning as "the grain of the
answer needs a default" below: a comment is a hint, not a constraint, and the number is
wrong before anyone reads the comment.

Note what this fact does **not** need: none of its measures land in bucket C or E. The
staff counts are the continuity-`Carers` trap without the trap — a plain global distinct,
not an aggregate of an aggregate — so they translate exactly.

The consequence has to be stated, because it is easy to reopen by accident: a fact with no
semantic view is **not an MCP capability at all**, since raw SQL stays off the
client-facing server (see below). Do not add `SYSTEM_EXECUTE_SQL` "just for the birthday
list" — that hands back every bypass the next section is about.

## The omissions only hold if there is no SQL escape hatch

Everything above assumes that when a metric is absent, the MCP server answers "I don't
have that measure". That is only true if the model has nothing else to reach for.

A Snowflake-managed MCP server can also expose `SYSTEM_EXECUTE_SQL`, and the tool
specification has no notion of priority — the model picks a tool by its `description`,
which is a hint, not a constraint. Snowflake's own documentation warns that exposing
`SYSTEM_EXECUTE_SQL` on the same server lets the client bypass the semantic views, and
says to use a separate server if direct SQL is needed.

For this project the consequence is specific. Asked "what was continuity in March", a
model with a SQL tool will not decline: it will query `*_CONTINUITY_REPORT`, sum
`visit_count`, and take a global `count(distinct carer_id)` — producing exactly the number
this document refused to publish, without the comment that would have flagged it. The same
goes for `Total Deliverable`, the `Year …` family and `Unfilled hrs/wk`, whose net-gap
stand-in reads lower than the report. The absences stop being honest and
become a redirect to a worse path.

So the boundary has to be authorization, not wording:

- **Client-facing server** — `CORTEX_ANALYST_MESSAGE` tools only, `USAGE` for the reader
  roles, no SQL tool.
- **Internal server** — `SYSTEM_EXECUTE_SQL`, a separate object, `USAGE` only for an
  analyst role that can read a number critically.

Note that raw SQL over the `REPORT` views is not a data leak: the predicate is in the view
and RLS still applies. The harm is wrong figures, silently. Snowflake's recommended shape
for several tools is to configure a Cortex Agent and expose it as `CORTEX_AGENT_RUN`, which
moves tool selection inside the warehouse's governance instead of the client's model.

## Related

- `macros/create_semantic_views.sql` — the implementation of this plan. Where the two
  disagree, the macro is what actually runs; keep this file in step with it.
- `powerbi_client_hours_measures.md`, `powerbi_carer_hours_measures.md`,
  `powerbi_continuity_report_measures.md`, `powerbi_schedule_difference_measures.md`,
  `powerbi_carer_qualification_measures.md`, `powerbi_workforce_capacity_measures.md` —
  the DAX these translate from, and the legacy-fidelity notes behind each formula.
- `macros/source_topology.sql` — why no relation name carries a care token any more,
  and why the DDL must still resolve them through `ref()` rather than hardcoding.
  The semantic views follow: ONE set per account, unprefixed, because the report
  views they sit over hold every care with the care as a COLUMN. The old
  `care1_client_hours_sv` objects are not dropped by the macro — repoint the MCP
  server at the bare names and drop them by hand.

  **`source` (the care; `care` is a synonym) is a dimension in every view** (in the
  workforce view on `dim_location`, which both of its facts reach, and in the plan &
  assessment dates view, which all three of its lists reach),
  and it has to be: one view now
  answers for every tenant in the account, so "how many hours last month" spans
  all of them unless the question says otherwise. Values are `care1` / `care4` in
  R1, `care2` / `care3` / `care5` / **`beta`** in R2, and **`alpha` / `alpha2` in
  R3** — `beta` and the R3 tenants are not named `careN` at all, so an answer
  that assumes the `careN` shape is wrong there. Each view's comment states this, so
  the MCP tool description carries it to the model. It is also part of every
  primary key and every relationship: ids collide across cares within an account
  (care2 and care3 share 9025 client ids, none the same person), so a
  single-column reference would join one tenant's fact to another's dimension.
- `ci/bootstrap-wif.sql` — `CREATE SEMANTIC VIEW` is a privilege of its own, granted
  there; `CREATE VIEW` does not cover it.

## Mechanism — this should move to a model

The macro issues the DDL through `dbt run-operation` because the project has no
`packages.yml`. That is a stopgap, and the shape of the stopgap is visible in
`.gitlab-ci.yml`: because `dbt build` does not run run-operations, every build job
carries an explicit extra command, after the shared phase that builds the report
views. Four places to keep in step, and nothing but line order enforces that the
DDL runs after the report views it depends on.

`Snowflake-Labs/dbt_semantic_view` adds a
`materialized='semantic_view'` that takes the same
tables/relationships/facts/dimensions/metrics body, which would give real models, real
lineage, `dbt build`, and no hand-built object names — the exact class of bug that made
the first version of the macro name a database it does not own. Native dbt-snowflake
support is still only an open request (`dbt-labs/dbt-adapters#1260`). CI does not run
`dbt deps` yet (`.gitlab-ci.yml`, `.dbt_setup`), so adopting the package means adding
`packages.yml` and putting that call back.
