# Plans Taken — Power BI setup

A list report, the port of the legacy **All Plans Taken** page
(`cm/in/plansTakenReport.php`, *Client* › All Plans Taken). One row per care plan
started for a client or a carer: who started and completed it, its review date and
whether it was signed off. No totals on the page.

The page shows one type (Client or Carer) and one date window at a time, and nothing
until the user presses Search. The model holds both types and the full history; the
page's inputs become slicers.

The rules behind every column are in the model descriptions (`int__plans_taken` in
`models/intermediate/_int__models.yml`, `mart__plans_taken_report` in
`models/marts/_mart__models.yml`). This page says how to put them on the canvas.

## Who is on the list

- Live plans (`cmFormsPlansTaken.deleted` is null) of the plan's own company and
  location.
- A **client plan** has a client and no carer; a **carer plan** a carer and no client.
- A plan whose template (`cmPlans`) is deleted is not listed, as on the page; a plan whose
  template row is missing is (its plan name is then blank unless it was renamed).
- **The person has to exist and not be deleted (state 4), for every viewer.** The page
  checks the person only for an area-restricted admin; an unrestricted admin also sees
  plans of deleted people and of ids with no person row. On R2 PROD (2026-10-25) that
  is 4,538 of care2's 1,150,412 rows, 223 of care3's 129,738, 9 in care5, none in beta.
- **Carer plans of care workers only** (`permissionId` = 4). Admin profiles live in the
  same table, and their plans are left out (decided 2026-10-27), as the page does for a
  restricted admin. That was 1,748 live plans in care3 and 28 in care2.
- Every build replaces the whole table.

Size on R2 PROD: care2 1.15M rows (126k people), care3 128k, care5 9k, beta 14k, plans
started from 2015 on.

## Tables

| Table | Grain | Role |
|---|---|---|
| `PLANS_TAKEN_REPORT` | plan taken | The list: every column of the page, and the RLS keys. |
| `DIM_DATE` | date | The date window. Mark it as the date table. |
| `SEARCH_BY` | 3 rows | The page's Search choice. A calculated table, below. |
| `AREA_SCOPE` | area–workgroup–branch link | Hidden. Read only by the `TenantArea` role. |

Import from `ANALYTICS_MART.CARE_MANAGEMENT` through the `Server` parameter, like the
other embedded models ([powerbi_embedded_setup.md](powerbi_embedded_setup.md)). Plain
Import: every date range of the page reads recent and old plans alike.

`DIM_LOCATION` is not needed: the app shows one location at a time, and the page has no
location column. `LOCATION_KEY` is there for it should a model want the name; hide it.
`DIM_CLIENT` and `DIM_CARER` are not used either. A row is a client's or a carer's plan,
the name is on the row, and `DIM_CARER` drops the archived carers this list keeps.

```dax
SEARCH_BY =
DATATABLE (
    "Search By", STRING,
    "Sort", INTEGER,
    { { "Started Dates", 1 }, { "Review Dates", 2 }, { "Completed Dates", 3 } }
)
```

It holds no customer data, so it needs no role (see "When you add a table" in
[powerbi_embedded_setup.md](powerbi_embedded_setup.md#the-tenant-role)). Sort
`Search By` by `Sort`.

## Relationships

Three, all from the list to `DIM_DATE[CALENDAR_DATE]`, many-to-one, single direction,
and **all three inactive**:

- `PLANS_TAKEN_REPORT[STARTED_DATE]`
- `PLANS_TAKEN_REPORT[REVIEW_DATE]`
- `PLANS_TAKEN_REPORT[COMPLETED_DATE]`

Power BI keeps at most one of them active. That one would filter the table rows by its
own date before any measure runs, so a plan started outside the window but reviewed
inside it would never reach the table. With all three inactive, the date slicer filters
nothing by itself, and `Plans In Window` (below) picks the date the user chose with
`USERELATIONSHIP`. `SEARCH_BY` and `AREA_SCOPE` have no relationships.

`DIM_DATE` runs to 31 December of the year the projection horizon falls in (2027 in
October 2026). A review date after that has no calendar row, so a date window never
reaches it: about 400 rows in care2 and 300 in care3 on 2026-10-25, typed years up to
2925.
The Review Date range slicer (below) reads the column itself and does reach them.

## RLS (embedded)

The same three roles as every other model, with the standard rules of
[powerbi_embedded_setup.md](powerbi_embedded_setup.md). Only the list carries
`SOURCE`, `COMPANY_ID` and `LOCATION_ID`, so only it gets a rule, and every rule on it is
strict: there is no blank row to keep. `DIM_DATE`, `SEARCH_BY` and `AREA_SCOPE` get none.

| Role | `PLANS_TAKEN_REPORT` matches |
|---|---|
| `Tenant` | source + company |
| `TenantLocation` | source + company + location |
| `TenantArea` | source + company + location + area |

For `TenantArea`, copy the rule on `ANNIVERSARY_REPORT` from the Anniversary model's
`roles/TenantArea.tmdl` and replace the table name: four places, all in the `RETURN`.
The area block is identical in every model.

`AREA_ID` is the area of the person the plan is for. Under an area limit, a row without
one is hidden (about 2,000 rows in care2), as the page hides people with no area from a
restricted admin. A residential care location scopes the page by the care home picked
in the top menu instead of the admin's areas; that is the backend's choice of
`customData`, not the model's.

**The app's location filter** targets `PLANS_TAKEN_REPORT[LOCATION_ID]`. There is no
`Report Ready` gate, as in Birthday and Anniversary: the date slicer opens on a window
of its own, where the page waits for Search.

## Columns

The table visual shows the page's columns in the page's order. Users show and hide them
through a field parameter, as on the page: Modeling → New parameter → Fields, the fields
below in this order, each renamed to its header, and the parameter's slicer saved with
the **shown** ones selected, the page's defaults. Hide every list column that is not in
the parameter.

**Keep the key in the table.** A table visual groups rows by the values it shows, so two
plans with the same visible values would merge into one row. Put `PLAN_TAKEN_KEY` in the
visual as a fixed field outside the parameter, with a one-space header and the narrowest
width.

| # | Header | Field | Format | Default |
|---|---|---|---|---|
| 0 | Name | `FULL_NAME` | font colour from `Person State Colour` | shown |
| 1 | Area | `AREA_NAME` | | hidden |
| 2 | Work Group | `WORKGROUP_NAMES` | | hidden |
| 3 | Branch | `BRANCH_NAMES` | | hidden |
| 4 | Plan Name | `PLAN_NAME` | | shown |
| 5 | Started | `STARTED_AT` | `dd-mm-yyyy hh:mm` | shown |
| 6 | Started By | `STARTED_BY` | | shown |
| 7 | Completed | `Completed` (measure) | | shown |
| 8 | Completed By | `COMPLETED_BY` | | hidden |
| 9 | Review Date | `REVIEW_DATE` | `dd-mm-yyyy` | shown |
| 10 | Sign Off | `Sign Off` (measure) | | shown |

The page's View Plan link and its State column are not here: the report does not know
the app's address, and the state is a slicer. Work Group and Branch are comma-joined
text, for display only.

**Sort** by Started, newest first: the page's default.

```dax
Completed =
VAR CompletedAt = SELECTEDVALUE ( PLANS_TAKEN_REPORT[COMPLETED_AT] )
RETURN
    IF ( ISBLANK ( CompletedAt ), "Pending", FORMAT ( CompletedAt, "dd-mm-yyyy hh:mm" ) )

Sign Off =
IF ( SELECTEDVALUE ( PLANS_TAKEN_REPORT[IS_SIGNED_OFF], FALSE () ), "Signed", "" )

Person State Colour =
SWITCH (
    SELECTEDVALUE ( PLANS_TAKEN_REPORT[PERSON_STATE] ),
    "Active", "#5cb85c",
    "Pending", "#f0ad4e",
    "Archived", "#d9534f"
)
```

`Completed` sorts as text, so sort the table on Started, not on it. `Sign Off` returns an
empty string, never BLANK, so a row without a signature stays in the table. The colours
are the page's: green Active, orange Pending, red Archived. The page paints every carer
name green; here a carer's name follows their state too.

## Slicers

Every slicer combines with every other one with AND, as the page's filters do.

| Slicer | Field | Setting |
|---|---|---|
| Type | `PERSON_TYPE_LABEL` | single select, default Client |
| Search | `SEARCH_BY[Search By]` | single select, default Started Dates |
| Dates | `DIM_DATE[CALENDAR_DATE]` | between; default today − 14 days to today |
| State | `PERSON_STATE` | multi-select, nothing selected |
| Area | `AREA_NAME` | multi-select |
| Plan | `PLAN_TEMPLATE_NAME` | multi-select, with search |
| Completed Date | `COMPLETED_DATE` | between |
| Next Review Date | `REVIEW_DATE` | between |

- **Dates** are both ends inclusive, as on the page. The page opens on today − 14 days to
  today; a relative date slicer keeps that window moving (check that it includes today).
- **The table needs the window as a visual filter**: `Plans In Window` is not blank. The
  date slicer filters no table by itself (see Relationships).
- **State.** Nothing selected shows every row, as the page's three ticked checkboxes do.
- **Plan** slices on the template, as the page's Plan filter does (`planId`), so every
  version of a renamed plan stays under its template. The page's dropdown lists only the
  plans visible in the location; that never narrowed its rows, so the slicer lists every
  template that has rows.
- **Completed Date** and **Next Review Date** stand in for the page's After / Before
  pairs. They read the list's own columns, independent of the Search choice. A narrowed
  Completed Date range drops pending plans; the page kept them when only After was set.
- **Branch and Workgroup** are not slicers. The page has none, and the columns are text:
  an area in two workgroups reads "A, B", so a slicer would list combinations. If the
  report wants them, a bridge at plan grain is needed in dbt, as All Carers has.

A slicer lists only values that some plan on the list has. `Has Data` goes on each
slicer as the visual filter `Has Data is 1`, as in Anniversary:

```dax
Has Data = IF ( ISBLANK ( [Plans In Window] ), 0, 1 )
```

## Search

Use Microsoft's certified **Text Filter** visual on `FULL_NAME`, and the Plan slicer's
own search for plan names. The page's search box reads every column; a concatenated
search column as in All Carers would hold a near-unique text per row, about a million
of them in care2, which costs far more memory than it is worth here.

## Measures

```dax
Plans In Window =
VAR SearchBy = SELECTEDVALUE ( SEARCH_BY[Search By], "Started Dates" )
RETURN
    SWITCH (
        SearchBy,
        "Review Dates",
            CALCULATE (
                COUNTROWS ( PLANS_TAKEN_REPORT ),
                USERELATIONSHIP ( PLANS_TAKEN_REPORT[REVIEW_DATE], DIM_DATE[CALENDAR_DATE] )
            ),
        "Completed Dates",
            CALCULATE (
                COUNTROWS ( PLANS_TAKEN_REPORT ),
                USERELATIONSHIP ( PLANS_TAKEN_REPORT[COMPLETED_DATE], DIM_DATE[CALENDAR_DATE] )
            ),
        CALCULATE (
            COUNTROWS ( PLANS_TAKEN_REPORT ),
            USERELATIONSHIP ( PLANS_TAKEN_REPORT[STARTED_DATE], DIM_DATE[CALENDAR_DATE] )
        )
    )

Plans Completed = CALCULATE ( [Plans In Window], PLANS_TAKEN_REPORT[IS_COMPLETED] = TRUE () )
Plans Pending = CALCULATE ( [Plans In Window], PLANS_TAKEN_REPORT[IS_COMPLETED] = FALSE () )
Plans Signed Off = CALCULATE ( [Plans In Window], PLANS_TAKEN_REPORT[IS_SIGNED_OFF] = TRUE () )
```

Every count goes through `Plans In Window`, so it follows the Search choice and the
date slicer. With no date picked, it counts every plan. With a window, "Completed Dates"
counts only completed plans, as the page's search does, so `Plans Pending` is empty
under it. For
people with a plan, the same `SWITCH` with `DISTINCTCOUNT ( PLANS_TAKEN_REPORT[PERSON_KEY] )`
in place of `COUNTROWS`.

**Reviews due is not on the page, and needs a definition before it is built.**
`REVIEW_DATE < TODAY ()` alone counts every older version of a reviewed plan: a review
starts the plan again as a new row, and the old row keeps its old review date. On R2
PROD care2, 430,845 live plans have a review date in the past, and 172,796 of them have
no next plan at all. `IS_SUPERSEDED` is there for this; a first draft for the business
to confirm:

```dax
Reviews Overdue =
CALCULATE (
    COUNTROWS ( PLANS_TAKEN_REPORT ),
    PLANS_TAKEN_REPORT[IS_SUPERSEDED] = FALSE (),
    PLANS_TAKEN_REPORT[REVIEW_DATE] < TODAY ()
)
```

It ignores the date window on purpose: overdue is as of today. Still open: whether
plans of Pending and Archived people count, and whether a pending plan can be overdue.
Many "current" plans are long-running logs rather than reviewed plans (one care2 person
has 1,243 current versions of one template), so the figure needs a look at the templates
too.

## What differs from the legacy page

Decided in the build (the model descriptions say more):

- One rule for every viewer: plans of deleted people and of ids with no person row are
  not listed (see the top). The page shows them to unrestricted admins.
- Plans of admin profiles are not listed for anyone. The page shows them to
  unrestricted admins.
- A restricted admin sees plans by the person's area alone. The page also requires the
  person's current location to be the plan's (care2: about 2,500 rows of people who
  moved).
- Work Group and Branch are filled for every viewer. The page fills them only for a
  restricted admin. They come from the mapping All Carers and All Clients use, so a
  deleted workgroup or branch is left out even where its link is still live; the page
  names it.
- No value leaks from the previous row. Started By and Completed By are blank when the
  user is not a carer row of the plan's company (care2: about 250 rows each); the page
  showed the previous row's name.
- Carer names are coloured by the carer's state; the page paints them all green.

Not portable to a report with fixed headers:

- The company's own words for client and carer in the Type labels and the column header.
- The name as a link to the summary page, View Plan, and View Signature. The report does
  not know the app's address.

## Testing

- DEV works as it is: a stale copy, so compare windows that DEV holds.
- **Against the page.** For one location, as an unrestricted admin, run the page's search
  (Client, Started Dates, a month) and compare its row count with the report's under
  the same Type, Search and window. They differ only by plans of deleted people and of
  ids with no person row. Then the same for Review Dates and Completed Dates, and for
  Carer.
- **Roles**, as in [powerbi_embedded_setup.md](powerbi_embedded_setup.md#test-before-the-first-customer):
  *View as* `Tenant` and `TenantLocation`, and `TenantArea` in a scratch copy with a
  literal `customData`.
- **Window.** A plan started before the window but reviewed inside it must appear under
  Review Dates; if not, a date relationship is still active.

## Deploying

As for every model ([powerbi_embedded_setup.md](powerbi_embedded_setup.md#deploying-a-semantic-model)):
a `Server` parameter rule in each pipeline stage, credentials in each workspace, and a
refresh after each dbt deploy. The table appears in an account with the first dbt deploy
that builds it. Publish the model after that deploy, or its first refresh fails on a
missing table.
