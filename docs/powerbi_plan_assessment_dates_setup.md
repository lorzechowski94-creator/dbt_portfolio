# Plan & Assessment Dates — Power BI setup

A list report, the port of the legacy **Plan & Assessment Dates** page
(`cm/in/plansAssesmentRpt.php`, the *Plan & Assessments Reports* button on the
Assessments calendar). Three tabs, each a list of what is due for review in a date
window: care **plans** by review date, **assessments** by next assessment date, and
open **wounds** by review date. No totals on the page.

The page shows one Type (Client or Carer, plans only), one Status (Active or Pending)
and one date window at a time, and nothing until the user presses Search. The model
holds every state and the full history; the page's inputs become slicers.

The rules behind every column are in the model descriptions: `int__plans_taken`,
`int__assessments` and `int__skin_assessments` in
`models/intermediate/_int__models.yml`, their marts in `models/marts/_mart__models.yml`.
This page says how to put them on the canvas.

## Who is on the lists

- **Plans** are `PLANS_TAKEN_REPORT`, the Plans Taken table as it stands, with its rules
  ([Plans Taken](powerbi_plans_taken_setup.md#who-is-on-the-list)). This page lists the
  plans whose review date falls in the window; a plan without one never shows.
- **Assessments**: live assessments of the location whose type and client exist. A
  deleted type keeps its assessments, as on the page; a deleted client (state 4) does
  not. Every assessment whose next date is in the window shows, even one that a newer
  assessment of the same type has replaced, as on the page. `IS_LATEST_OF_TYPE` is
  there to drop those.
- **Wounds**: a wound is a first skin assessment and its reviews. The page lists a wound
  when any of its live entries has a review date in the window, shows it by its latest
  entry, and drops it when that entry is healed. The table has one row per entry, with
  the wound's latest-entry values on each.

Checked on R2 PROD on 2026-10-28: the page's default view (Active, the last 14 days)
counts the same as the legacy SQL in every source, on all three tabs. In care2 that is
5,530 client plans, 2,037 carer plans, 1,116 assessments and 361 wounds.

Size on R2 PROD: assessments 258k rows in care2 (53% of Archived clients), 6k in care3,
3k in care5, 1k in beta; wound entries 43k in care2 (17.7k wounds), 6k in care3, 3.5k in
care5. Plans as in Plans Taken.

## Tables

| Table | Grain | Role |
|---|---|---|
| `PLANS_TAKEN_REPORT` | plan taken | The Plans list. |
| `ASSESSMENTS_REPORT` | assessment | The Assessments list. |
| `SKIN_ASSESSMENTS_REPORT` | entry of a wound | The Wound / Skin list. |
| `DIM_DATE` | date | The date window. Mark it as the date table. |
| `DIM_LOCATION` | location | The app's location filter, one for all three lists. |
| `AREA_SCOPE` | area–workgroup–branch link | Hidden. Read only by the `TenantArea` role. |

Import from `ANALYTICS_MART.CARE_MANAGEMENT` through the `Server` parameter, like the
other embedded models ([powerbi_embedded_setup.md](powerbi_embedded_setup.md)). Plain
Import. `PLANS_TAKEN_REPORT` can keep only the rows with a `REVIEW_DATE` (a Power Query
filter): no other row reaches this report.

`DIM_CLIENT` and `DIM_CARER` are not used. The names and states are on the rows.

## Relationships

All many-to-one, single direction and active:

- `PLANS_TAKEN_REPORT[REVIEW_DATE]` → `DIM_DATE[CALENDAR_DATE]`
- `ASSESSMENTS_REPORT[NEXT_ASSESSMENT_DATE]` → `DIM_DATE[CALENDAR_DATE]`
- `SKIN_ASSESSMENTS_REPORT[REVIEW_DATE]` → `DIM_DATE[CALENDAR_DATE]`
- `LOCATION_KEY` of each list → `DIM_LOCATION[LOCATION_KEY]`

One date slicer then filters all three lists, as the page's one From / To does. The
plans need none of Plans Taken's inactive relationships: this page has no Search choice.
`AREA_SCOPE` has no relationships.

`DIM_DATE` runs to 31 December of the year the projection horizon falls in (2027 in
October 2026), and a date window never reaches a later date. On R2 PROD that leaves out
246 care2 assessments, with next dates typed up to 2064; plan and wound review dates are
typed up to 2925 and 3026.

## RLS (embedded)

The same three roles as every other model, with the standard rules of
[powerbi_embedded_setup.md](powerbi_embedded_setup.md). The three lists carry `SOURCE`,
`COMPANY_ID`, `LOCATION_ID` and `AREA_ID`; `DIM_LOCATION` carries the first three. Every
rule is strict: no table here keeps a blank row. `DIM_DATE` and `AREA_SCOPE` get none.

| Role | Each list matches | `DIM_LOCATION` matches |
|---|---|---|
| `Tenant` | source + company | source + company |
| `TenantLocation` | source + company | source + company + location |
| `TenantArea` | source + company + area | source + company + location |

The location rule sits on `DIM_LOCATION` and reaches the lists through their
relationships, as in Workforce Capacity. For `TenantArea`, copy the area block from the
Anniversary model's `roles/TenantArea.tmdl` onto each list: it is identical in every
model.

`AREA_ID` is the area of the person the plan is for, and the client's on assessments and
wounds. Under an area limit, a row without one is hidden, as the page hides people with
no area from a restricted admin. The page's Wound / Skin tab has no area scope at all;
this one has, on purpose. A residential care location narrows the page by the care home
picked in the top menu, but only in its Area filter options, never in its rows; here
the token's areas decide, which is the backend's choice of `customData`.

**The app's location filter** targets `DIM_LOCATION[LOCATION_ID]`. There is no
`Report Ready` gate: the date slicer opens on a window of its own, where the page waits
for Search.

## Pages

One page per tab: Plans, Assessments, Wound / Skin.

**Dates**: `DIM_DATE[CALENDAR_DATE]`, a between slicer, both ends inclusive, default
today − 14 days to today, the window the page opens on. A relative date slicer keeps that
window moving (check that it includes today). Sync it across the three pages (View → Sync
slicers): the page has one window for all tabs. The page's date picker stops at
01-03-2020, while the lists go back further. To stop the slicer there too, give it the
visual filter `CALENDAR_DATE` is on or after 01-03-2020.

**Type** sits on the Plans page only, unsynced. The page fills Assessments and
Wound / Skin only when Type is Client and leaves both empty for Carer; here those lists
hold clients only and always show.

**Search.** The page's search box reads every column of its tab, hidden ones included.
Use Microsoft's certified **Text Filter** visual on `FULL_NAME` on each page, and a second
one on `NOTE` on the Assessments page; the Plan and Assessment slicers search their own
values. As in Plans Taken, a concatenated search column would hold a near-unique text per
row, which costs more memory than it is worth.

No Branch or Workgroup slicer: the page has none, and the columns are comma-joined text,
so a slicer would list combinations ([Plans Taken](powerbi_plans_taken_setup.md#slicers)).

Each list shows and hides columns through a field parameter, as in
[Plans Taken](powerbi_plans_taken_setup.md#columns): the fields in the order below, each
renamed to its header, the slicer saved with the **shown** ones selected. Keep the key
column in each table as a fixed field outside the parameter, with a one-space header and
the narrowest width, so two rows with the same visible values never merge.

### Plans

Key: `PLAN_TAKEN_KEY`. Sort by Started, newest first: the page's default.

| # | Header | Field | Format | Default |
|---|---|---|---|---|
| 0 | Name | `FULL_NAME` | font colour from `Person State Colour` | shown |
| 1 | Area | `AREA_NAME` | | hidden |
| 2 | Work Group | `WORKGROUP_NAMES` | | hidden |
| 3 | Branch | `BRANCH_NAMES` | | hidden |
| 4 | Plan Name | `PLAN_NAME` | | shown |
| 5 | Started | `STARTED_AT` | `dd-mm-yyyy hh:mm` | hidden |
| 6 | Started By | `STARTED_BY` | | hidden |
| 7 | Completed | `COMPLETED_AT` | `dd-mm-yyyy hh:mm` | hidden |
| 8 | Completed By | `COMPLETED_BY` | | hidden |
| 9 | Review Date | `REVIEW_DATE` | `dd-mm-yyyy` | shown |

The defaults are the page's (its second `columnDefs` hides columns 1–3 and 5–8).
Completed is blank while the plan is pending, as on the page.

| Slicer | Field | Setting |
|---|---|---|
| Type | `PERSON_TYPE_LABEL` | single select, default Client |
| Status | `PERSON_STATE` | single select, default Active |
| Area | `AREA_NAME` | multi-select |
| Plan | `PLAN_TEMPLATE_NAME` | multi-select, with search |

### Assessments

Key: `ASSESSMENT_KEY`. Sort by Assessment Date, newest first: the page's default.

| # | Header | Field | Format | Default |
|---|---|---|---|---|
| 0 | Client | `FULL_NAME` | font colour from `Client State Colour` | shown |
| 1 | Area | `AREA_NAME` | | hidden |
| 2 | Work Group | `WORKGROUP_NAMES` | | hidden |
| 3 | Branch | `BRANCH_NAMES` | | hidden |
| 4 | Assessment Name | `ASSESSMENT_TYPE_NAME` | | shown |
| 5 | Assessment Date | `ASSESSMENT_DATE` | `dd-mm-yyyy` | shown |
| 6 | Next Assessment Date | `NEXT_ASSESSMENT_DATE` | `dd-mm-yyyy` | shown |
| 7 | Note | `NOTE` | | shown |

| Slicer | Field | Setting |
|---|---|---|
| Status | `CLIENT_STATE` | single select, default Active |
| Area | `AREA_NAME` | multi-select |
| Assessment | `ASSESSMENT_TYPE_NAME` | multi-select, with search; visual filter `IS_ASSESSMENT_TYPE_DELETED` is False |
| Latest only | `IS_LATEST_OF_TYPE` | default all rows, as the page |

The Assessment slicer filters this list only. On the page the same filter also filtered
the Plans table, matching plan ids against assessment type ids. The page's dropdown leaves
out deleted types, and the visual filter does the same; their assessments still show while
nothing is picked, as on the page.

### Wound / Skin

Key: `WOUND_KEY`, not the entry key. The table groups the entries in the window by
wound, so it shows one row per wound. Visual filter: `IS_WOUND_HEALED` is False. Sort by
Assessment Name, descending: the page's default.

| # | Header | Field | Format |
|---|---|---|---|
| 0 | Client | `FULL_NAME` | font colour from `Client State Colour` |
| 1 | Assessment Name | `WOUND_NAME` | |
| 2 | Assessment Date | `WOUND_ASSESSMENT_DATE` | `dd/mm/yyyy` |
| 3 | Next Assessment Date | `WOUND_REVIEW_DATE` | `dd/mm/yyyy` |

All four columns are the wound's latest entry, as on the page, so a wound listed for an
older entry reviewed inside the window can show a next date outside it (36 of care2's
361 in the default view). The page has no hidden columns and no area columns here;
`AREA_NAME`, `WORKGROUP_NAMES` and `BRANCH_NAMES` are there if the report wants them.

| Slicer | Field | Setting |
|---|---|---|
| Status | `CLIENT_STATE` | single select, default Active |

The page appends "(N days)" to the next date: the gap to the previous entry's review
date, wrong past a month (it reads the day part of the interval only). It is not ported;
`Days To Review` below is the figure a user can act on.

## Measures

```dax
Plans Due = COUNTROWS ( PLANS_TAKEN_REPORT )
Plans Not Completed = CALCULATE ( [Plans Due], PLANS_TAKEN_REPORT[IS_COMPLETED] = FALSE () )
Assessments Due = COUNTROWS ( ASSESSMENTS_REPORT )
Wounds Due =
CALCULATE (
    DISTINCTCOUNT ( SKIN_ASSESSMENTS_REPORT[WOUND_KEY] ),
    SKIN_ASSESSMENTS_REPORT[IS_WOUND_HEALED] = FALSE ()
)

Days To Review =
VAR NextReview = SELECTEDVALUE ( SKIN_ASSESSMENTS_REPORT[WOUND_REVIEW_DATE] )
RETURN
    IF ( NOT ISBLANK ( NextReview ), DATEDIFF ( TODAY (), NextReview, DAY ) )

Person State Colour =
SWITCH (
    SELECTEDVALUE ( PLANS_TAKEN_REPORT[PERSON_STATE] ),
    "Active", "#5cb85c",
    "Pending", "#f0ad4e",
    "Archived", "#d9534f"
)
```

Under the date slicer, each `Due` measure counts what its tab lists, and
`Plans Not Completed` the plans among them that nobody has completed yet. `Days To Review` is
negative once the review is overdue. `Client State Colour` is `Person State Colour` on
`ASSESSMENTS_REPORT[CLIENT_STATE]`; on the wound page use
`SKIN_ASSESSMENTS_REPORT[CLIENT_STATE]`. The colours are the page's.

**Overdue is not on the page, and needs a definition before it is built.** Drafts for the
business to confirm. They ignore the date window on purpose, since overdue is as of today:

```dax
Assessments Overdue =
CALCULATE (
    COUNTROWS ( ASSESSMENTS_REPORT ),
    REMOVEFILTERS ( DIM_DATE ),
    ASSESSMENTS_REPORT[IS_LATEST_OF_TYPE] = TRUE (),
    ASSESSMENTS_REPORT[NEXT_ASSESSMENT_DATE] < TODAY ()
)

Wounds Overdue =
CALCULATE (
    DISTINCTCOUNT ( SKIN_ASSESSMENTS_REPORT[WOUND_KEY] ),
    REMOVEFILTERS ( DIM_DATE ),
    SKIN_ASSESSMENTS_REPORT[IS_LATEST_ENTRY] = TRUE (),
    SKIN_ASSESSMENTS_REPORT[IS_WOUND_HEALED] = FALSE (),
    SKIN_ASSESSMENTS_REPORT[WOUND_REVIEW_DATE] < TODAY ()
)
```

On R2 PROD care2 for Active clients, these count 24,832 assessments and 5,717 wounds. Many
wounds look abandoned rather than open (only 233 of care2's 8,750 open wounds have a
review date ahead), so the wound figure needs a look with the business. For plans, see
`Reviews Overdue` in [Plans Taken](powerbi_plans_taken_setup.md#measures).

## What differs from the legacy page

Decided in the build (the model descriptions say more):

- The plans follow Plans Taken's rules for every viewer, and so do the assessments: a
  person who moved keeps their plans and assessments at the location they were made in.
  The page drops them everywhere, because it also needs the person's current location
  (care2: 38 assessments).
- Each slicer filters its own tab. The page's Assessment filter also filtered the Plans
  table.
- No value leaks from the previous row: a person with no area has blank Area, Work Group
  and Branch, and an unknown Started By is blank. The page showed the previous row's.
- Archived people can be reported. The page has Archived commented out of its Status
  dropdown; the Status slicers default to Active.
- The Wound / Skin tab applies the client's area under `TenantArea`. The page applies no
  area there, or another page's client list when the session happens to hold one.
- Wound names are coloured by the client's own state; the page paints them all in the
  colour of the picked status.
- Sorting by name works. The page sorts its name columns by a variable it never sets.
- A location whose areas hold no carers shows no carer plans. The page's SQL broke there
  (`IN ()`) and showed an empty tab.
- Assessments and wounds show whatever the Type. The page leaves both tabs empty when
  Type is Carer.
- The Area and Plan slicers pick by name, the page's filters by id: two areas, or two plan
  templates, with the same name are one slicer item here.
- A wound entry with no location belongs to its client's location. The page shows it in
  every location of the company (no such entry on R2 PROD, 2026-10-28).
- A wound is shown by its latest live entry. Whether the page's chain lookup also sees
  deleted entries is not in its description; on R2 PROD (2026-10-29) one care2 wound has a
  deleted latest entry, and its live entry is due on 01-01-1970, so no window differs.
- Names keep their double quotes. The page strips them from the Plans tab's names: 121
  care2 plan rows, of 39 clients and 2 carers (2026-10-29). Stripping them here would
  change Plans Taken too, which shares the table.

Not portable to a report with fixed headers:

- The company's own words for client, carer and assessment in the headers.
- The links: the name to the summary page, View Completed Plan, View Assessment and the
  wound Log. The report does not know the app's address.

## Testing

- **Against the page.** For one location, run the page's search for a month, Active and
  then Pending, and compare each tab's row count with the report's under the same window
  and Status. Plans differ only by the plans Plans Taken differs on; assessments only by
  clients who moved.
- **Roles**, as in [powerbi_embedded_setup.md](powerbi_embedded_setup.md#test-before-the-first-customer):
  *View as* `Tenant` and `TenantLocation`, and `TenantArea` in a scratch copy with a
  literal `customData`.
- **Wound window.** A wound whose older entry was reviewed inside the window and whose
  latest entry is due later must appear, showing the later date.

## Deploying

As for every model ([powerbi_embedded_setup.md](powerbi_embedded_setup.md#deploying-a-semantic-model)):
a `Server` parameter rule in each pipeline stage, credentials in each workspace, and a
refresh after each dbt deploy. `ASSESSMENTS_REPORT` and `SKIN_ASSESSMENTS_REPORT` appear
in an account with the first dbt deploy that builds them. Publish the model after that
deploy, or its first refresh fails on a missing table.

**The Wound / Skin page needs `cmSkinAssessments` in the account.** On 2026-10-28 it was
in all four R2 sources; R1 (care1, care4), R3 (alpha, alpha2) and DEV were not checked. A
source without it has no rows in `SKIN_ASSESSMENTS_REPORT`, and the dbt deploy job is red
on its raw_access view (a step that holds nothing else back). Before publishing in R1 or
R3, run `SHOW TABLES LIKE 'CMSKINASSESSMENTS' IN DATABASE ANALYTICS_RAW` there; without
the table, publish the report without the Wound / Skin page.
