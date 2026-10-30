# Task Review — Power BI setup

A list report, the port of the legacy **Digital Task Review** page
(`cm/in/task/companyTaskRpt.php`, Reports › Digital Task Review, "Digital Task Reports
and Records"; also linked from the Compliance / Audit tab). One row per scheduled task
slot per day, with what was recorded on it, or blanks when nothing was. No totals on the
page. It is the task twin of the Medication Review page (`med/companyMedRpt.php`), and
the model follows the rules decided for that report on 2026-10-28.

The page shows one location and one date window at a time, and nothing until the user
presses Search. The model holds every location, the full history and the next 60 days;
the page's window becomes a date slicer. The days ahead show the tasks still to come,
as in Medication Review.

The rules behind every row and column are in the model descriptions
(`int__task_review` in `models/intermediate/_int__models.yml`,
`mart__task_review_report` and `mart__dim_task_schedule` in
`models/marts/_mart__models.yml`). This page says how to put them on the canvas.

## What is on the list

- **Slots.** Every live schedule (`cmdailyTasksAssign`) of a client who is not deleted
  is expanded into its dates up to 60 days ahead, and each date into one slot per live
  time of the schedule, or a single "Any" slot when it has none. On its last day a
  schedule ends at its effective stop time.
- **Slots after today are a forecast** of the schedules as they stood at the last
  build. They carry nothing recorded, except a task cancelled in advance.
- **Results.** A slot carries every live result recorded on it, one row each, as on
  the page: a Due row and a later Completed row both show. A timed slot takes the
  results recorded for its time, an "Any" slot the results recorded with no time. A
  slot with nothing recorded is one blank row. `IS_LATEST_FOR_SLOT` marks one row per
  slot, the latest result or the blank row, for counting.
- **Every client, not only Active ones.** The page lists clients whose status row is 1
  ("Active"). The model keeps every client and their history, and the State slicer
  (below) opens on Active, which comes close to the page: it also includes active
  clients on any other status, such as Temp Cover.
- **A client who left has no empty slots after leaving.** The app keeps the schedules
  of archived clients open, so they would otherwise read "not recorded" for every day
  since. A slot with a result always shows. On DEV care1 this cut 2024 from 7.28M slots
  to 6.22M.
- **Many empty slots remain, as on the page.** In DEV care1, 38% of 2024's slots have
  nothing recorded. Most belong to locations that schedule tasks but do not record them
  in the app: one location holds 1.24M of the 2.34M empty slots, and at least six
  others recorded nothing in 2024. Every result of 2017–2020 was saved without a time
  on schedules that have times, so those years are blank slots only, as on the page.
- Each build replaces every date from 60 days back to 60 days ahead. Older history
  changes only with a full refresh of the dbt model.

Size on DEV care1 (a stale copy: results stop on 2025-01-15), 2026-10-29, history up to
60 days ahead: 27.8M rows, 6.2M of them in 2024; 2,691 clients and 105 locations in 2024.
Rows from 2025 on are almost all blank, because DEV holds no newer results. In Snowflake
the table takes about 625 MB. Production R1 and R2 are not measured yet.

## Tables

| Table | Grain | Role |
|---|---|---|
| `TASK_REVIEW_REPORT` | slot × date × result | The list: the result columns, the slot, and the RLS keys. |
| `DIM_TASK_SCHEDULE` | schedule | Task name, schedule pattern, mandatory flag. |
| `DIM_CLIENT` | client | Client name, Area, Work Group, Branch, state. |
| `DIM_DATE` | date | The date window. Mark it as the date table. |
| `AREA_SCOPE` | area–workgroup–branch link | Hidden. Read only by the `TenantArea` role. |

Import from `ANALYTICS_MART.CARE_MANAGEMENT` through the `Server` parameter, like the
other embedded models ([powerbi_embedded_setup.md](powerbi_embedded_setup.md)).
Check the model size after the first refresh on each account before relying on F2
(roughly 1.3 GB per model, see *Size on F2* in that page). If it does not fit, keep
recent months in memory and older ones in DirectQuery, as Schedule Difference does
([powerbi_schedule_difference_measures.md](powerbi_schedule_difference_measures.md)).
Its date filter must then target `DIM_DATE[CALENDAR_DATE]`.

Leave these columns out of the import; nothing on the page needs them:
`RESULT_ID` (a different value on almost every row, so it costs as much memory as a
row key), `TIME_PERIOD_ID` (no names until `timePeriods` is loaded), `CLIENT_ID`,
`TASK_ASSIGN_ID`, `RECORDED_BY_ID`, `SUB_STATUS_ID`, `LOCATION_KEY`. Keep
`TASK_ASSIGN_TIMES_ID`, `TASK_SCHEDULE_KEY` and `RESULT_NUMBER`: the table visual needs
them (see Columns). In `DIM_TASK_SCHEDULE`, `CLIENT_KEY` stays unrelated: the fact
relates to `DIM_CLIENT` itself.

`DIM_LOCATION` is not needed: the app shows one location at a time, and the page has
no location column.

## Relationships

All many-to-one, single direction, active:

- `TASK_REVIEW_REPORT[SCHEDULED_DATE]` → `DIM_DATE[CALENDAR_DATE]`
- `TASK_REVIEW_REPORT[TASK_SCHEDULE_KEY]` → `DIM_TASK_SCHEDULE[TASK_SCHEDULE_KEY]`
- `TASK_REVIEW_REPORT[CLIENT_KEY]` → `DIM_CLIENT[CLIENT_KEY]`

`AREA_SCOPE` has none.

## RLS (embedded)

The same three roles as every other model, with the standard rules of
[powerbi_embedded_setup.md](powerbi_embedded_setup.md). Every fact row has its
schedule and its client (dbt tests both relationships), so no rule needs a blank row.

| Table | `Tenant` | `TenantLocation` | `TenantArea` |
|---|---|---|---|
| `TASK_REVIEW_REPORT` | source + company | source + company + location | source + company + location + area |
| `DIM_TASK_SCHEDULE` | source + company | source + company | source + company |
| `DIM_CLIENT` | source + company | source + company | source + company |

`DIM_DATE` and `AREA_SCOPE` get none.

For `TenantArea`, copy the rule on `PLANS_TAKEN_REPORT` from the Plans Taken model
(or `ANNIVERSARY_REPORT` from Anniversary) and replace the table name. The area block
is identical in every model.

`AREA_ID` is the client's area. **The legacy page limits no rows by area at all**: an
admin restricted to some workgroups sees every client of the location; only its Area
Search dropdown is limited. Here such an admin sees only clients in their areas, and a
row whose client has no area is hidden under an area limit (1.3% of the rows on DEV
care1). This is stricter than the page on purpose.

**The app's location filter** targets `TASK_REVIEW_REPORT[LOCATION_ID]`, the
schedule's location. There is no `Report Ready` gate, as in Plans Taken: the date
slicer opens on a window of its own, where the page waits for Search.

## Columns

The table visual shows the page's columns in the page's order. Users show and hide them
through a field parameter, as on the page: Modeling → New parameter → Fields, the fields
below in this order, each renamed to its header, and the parameter's slicer saved with
the **shown** ones selected.

| # | Header | Field | Format | Default |
|---|---|---|---|---|
| 0 | Client | `DIM_CLIENT[FULL_NAME]` | | shown |
| 1 | Carer | `RECORDED_BY` | | shown |
| 2 | Area | `DIM_CLIENT[AREA_NAME]` | | shown |
| 3 | Work Group | `DIM_CLIENT[WORKGROUP]` | | hidden |
| 4 | Branch | `DIM_CLIENT[BRANCH]` | | hidden |
| 5 | Task | `DIM_TASK_SCHEDULE[TASK_NAME]` | | **shown** |
| 6 | Date | `SCHEDULED_DATE` | `dd-mm-yyyy` | shown |
| 7 | Assigned Time | `ASSIGNED_TIME` | sort by `ASSIGNED_TIME_MINUTES` | shown |
| 8 | Status | `STATUS_NAME` | | shown |
| 9 | Sub Status | `SUB_STATUS_NAME` | | shown |
| 10 | Time Recorded | `TIME_RECORDED` | | shown |
| 11 | Comment | `COMMENT` | | shown |
| 12 | Result Created | `RESULT_CREATED_AT` | `dd mmm yyyy hh:nn:ss` | hidden |

**Task is shown by default.** The page hides it, together with Work Group, Branch and
Result Created. The Medication Review page hides Area, Work Group and Branch instead,
so the task page's hidden list looks shifted by one column; a task list without its
task is not useful.

**Keep the slot and the result in the table.** A table visual groups rows by the values
it shows, so two rows with the same visible values would merge into one: two schedules
of the same task at the same time, or two equal results on one slot. Put
`TASK_SCHEDULE_KEY`, `TASK_ASSIGN_TIMES_ID` and `RESULT_NUMBER` in the visual as fixed
fields outside the parameter, each with a one-space header and the narrowest width.
Each has far fewer distinct values than the table has rows (a schedule, a time of day, a
result's position on its slot), so they cost little memory.

**The table needs `Rows` as a visual filter** (`Rows` is not blank). It mixes columns of
three tables, and without a measure Power BI would combine values across them instead
of listing the rows that exist.

**Sort** by Date, newest first. The page sorts by the Client column, descending, as
text, so it lists clients Z to A by first name; that order is not kept. Set
`ASSIGNED_TIME` to sort by `ASSIGNED_TIME_MINUTES` in the model, so 'Any' comes first
and times run in clock order.

## Slicers

Every slicer combines with every other one with AND.

| Slicer | Field | Setting |
|---|---|---|
| Dates | `DIM_DATE[CALENDAR_DATE]` | between; relative, last 1 week including today |
| State | `DIM_CLIENT[Client State]` (calculated column, below) | multi-select, default Active |
| Area | `DIM_CLIENT[AREA_NAME]` | multi-select |
| Client | `DIM_CLIENT[FULL_NAME]` | multi-select, with search |
| Task | `DIM_TASK_SCHEDULE[TASK_NAME]` | multi-select, with search |
| Status | `TASK_REVIEW_REPORT[Status Label]` (calculated column, below) | multi-select |

```dax
Client State =
SWITCH ( DIM_CLIENT[STATE_ID], 1, "Active", 2, "Pending", 3, "Archived" )

Status Label =
IF (
    TASK_REVIEW_REPORT[IS_RECORDED],
    IF ( ISBLANK ( TASK_REVIEW_REPORT[STATUS_NAME] ), "No status", TASK_REVIEW_REPORT[STATUS_NAME] ),
    "Not recorded"
)
```

Both are calculated columns, not tables, so they need no role. `Status Label` has a
handful of values, so it costs little memory on the fact. "No status" is a result whose
status no category holds (138 old results in DEV care1); the page shows it with a blank
Status.

- **Dates** are both ends inclusive. The page opens on today − 1 week to today.
- **State** opens on Active to stay close to the page (see What is on the list). Pick
  Archived as well to see the history of clients who have left.
- **Status** can pick "Not recorded" here. On the page a blank row matches no status
  pick, so its Status Search can only list slots that have a result.
- **Branch and Workgroup** are not slicers, as in Plans Taken. The columns are text: an
  area in two workgroups reads "A, B", so a slicer would list combinations. The page
  has an Area filter only.

A slicer lists only values that some row in the window has. `Has Data` goes on each
slicer as the visual filter `Has Data is 1`, as in Anniversary:

```dax
Has Data = IF ( ISBLANK ( [Rows] ), 0, 1 )
```

## Search

Use Microsoft's certified **Text Filter** visual on `DIM_CLIENT[FULL_NAME]`, and the
Task slicer's own search for tasks. The page's search box reads every column; a search
column over the fact would hold a near-unique text per row, which costs far more memory
than it is worth.

## Measures

```dax
Rows = COUNTROWS ( TASK_REVIEW_REPORT )

Scheduled Slots =
CALCULATE ( COUNTROWS ( TASK_REVIEW_REPORT ), TASK_REVIEW_REPORT[IS_LATEST_FOR_SLOT] = TRUE () )

Completed = CALCULATE ( [Scheduled Slots], TASK_REVIEW_REPORT[STATUS_ID] = 1 )
Partially Completed = CALCULATE ( [Scheduled Slots], TASK_REVIEW_REPORT[STATUS_ID] = 3 )
Not Completed = CALCULATE ( [Scheduled Slots], TASK_REVIEW_REPORT[STATUS_ID] = 4 )
Other = CALCULATE ( [Scheduled Slots], TASK_REVIEW_REPORT[STATUS_ID] = 2 )
Missed = CALCULATE ( [Scheduled Slots], TASK_REVIEW_REPORT[STATUS_ID] = 5 )
Due = CALCULATE ( [Scheduled Slots], TASK_REVIEW_REPORT[STATUS_ID] = 6 )
Cancelled = CALCULATE ( [Scheduled Slots], TASK_REVIEW_REPORT[STATUS_ID] = 7 )

Not Recorded =
CALCULATE (
    [Scheduled Slots],
    TASK_REVIEW_REPORT[IS_RECORDED] = FALSE (),
    KEEPFILTERS ( DIM_DATE[CALENDAR_DATE] <= TODAY () )
)

Expected Tasks =
CALCULATE ( [Scheduled Slots], TASK_REVIEW_REPORT[STATUS_ID] <> 7 )
```

Every slot figure counts a slot once, by its latest result. `Rows` counts what the page
lists, one row per result. The same definitions are the metrics of `task_review_sv`,
which the MCP server reads ([mcp_semantic_view_metrics.md](mcp_semantic_view_metrics.md)),
so the report and the MCP give the same numbers.

The ids are the global statuses: 1 Completed, 2 Other, 3 Partially Completed, 4 Not
Completed, 5 Missed, 6 Due, 7 Cancelled. Missed and Due are written by the app, not by a
carer; a slot whose latest row is Due has no outcome yet. A company's renamed status
keeps its id, so these measures still count it; a status a company adds as a category
of its own has an id of its own and is in none of them (one in DEV care1, deleted).

**Expected Tasks** are the slots due in the window, past or future, not cancelled. For
the coming week set the window to today + 1 to today + 7; the days after today are a
forecast from the current schedule. `TASK_REVIEW_REPORT[STATUS_ID] <> 7` keeps the blank
rows, because DAX compares a blank as 0.

**Not Recorded** stops at today, so a future slot never counts as not recorded. Missed
is the commonest outcome: the app writes it for a slot nobody completed, and in DEV
care1 1.97M of 2024's 6.22M slots end as Missed, 1.41M as Completed and 2.34M with
nothing recorded.

**% Completed needs a definition before it is built.** A draft for the business to
confirm:

```dax
% Completed =
DIVIDE (
    CALCULATE ( [Completed], KEEPFILTERS ( DIM_DATE[CALENDAR_DATE] <= TODAY () ) ),
    CALCULATE ( [Expected Tasks], KEEPFILTERS ( DIM_DATE[CALENDAR_DATE] <= TODAY () ) )
)
```

It leaves out cancelled slots and every day after today. Still open: whether Partially
Completed counts as completed, and whether today's slots that are not due yet count.
Until it is settled, `task_review_sv` has no percentage either.

## What differs from the legacy page

Decided in the build (the model descriptions say more):

- Clients of every state are kept, with State defaulting to Active. The page lists
  clients with status row 1 only (see What is on the list).
- Empty slots after a client left are not listed; slots with a result are.
- Dates run to 60 days ahead. The page takes any date range, however far ahead.
- Rows are limited by area for a restricted admin (see RLS). The page shows them the
  whole location.
- Status names follow the company's own live name for the location in the column and
  the slicer alike. The page shows the category's own name in the column and the
  company's name in its Status Search dropdown, so a company that renamed "Completed"
  sees one name in the filter and another in the table.
- The Status slicer can pick "Not recorded" (see Slicers).
- Task is shown by default, and the list sorts by Date (see Columns).

Like the page:

- Results the page cannot see are not here either: one recorded without a time on a
  schedule that has times (265k in DEV care1, every result of 2017–2020 among them), on
  a date the schedule does not have or outside its dates, on a deleted time slot or a
  deleted schedule. Their slots read as not recorded. 6.97M of care1's 7.28M live
  results are on the list.
- A time of a schedule can carry its own weekdays, week and dates in the app
  (`cmdailyTasksAssignTimes.day` and the rest). The page does not read them, and
  neither does the model: a slot shows on every day of the schedule. In DEV care1, 2024
  has 451k slots on a weekday outside the time's own list and 239k after the time's own
  end date, almost all blank or Missed.
- A deleted task type still shows its schedules.
- `stoppedDate` ends nothing; only `dateFinish` and, on that day, the effective stop
  time do.

Not ported:

- The named time period in Assigned Time: `timePeriods` is not loaded into Snowflake.
  Add it to the Airbyte connection to get it; the slot already carries its id.
- Today's placeholder row on an "Any" slot: an extra row in front of the first result
  that is not Due or Cancelled, with no carer and no status but that result's time,
  comment and created stamp (so the comment shows twice). It is a carer-screen device.
- The page's heading label (`defaultNames.taskSheets`): the report has its own title.

## Testing

- DEV works as it is: a stale copy, so compare windows that DEV holds (results stop on
  2025-01-15).
- **Against the page.** For one location, as an unrestricted admin, run the page's
  search for a past week and compare its row count with the report's under State =
  Active and the same window. Expect the report to have rows for active clients on other
  statuses than "Active", fewer rows where a client left during the window, and no
  placeholder row on today's "Any" slots.
- **Two results on one slot** show as two rows, and `Scheduled Slots` counts the slot
  once.
- **Roles**, as in [powerbi_embedded_setup.md](powerbi_embedded_setup.md#test-before-the-first-customer):
  *View as* `Tenant` and `TenantLocation`, and `TenantArea` in a scratch copy with a
  literal `customData`.

## Deploying

As for every model ([powerbi_embedded_setup.md](powerbi_embedded_setup.md#deploying-a-semantic-model)):
a `Server` parameter rule in each pipeline stage, credentials in each workspace, and a
refresh after each dbt deploy. The tables appear in an account with the first dbt deploy
that builds them, which builds the full history. Publish the model after that deploy,
or its first refresh fails on a missing table.
