# All Carers — Power BI setup

A list report, the port of the legacy **All Carers** page
(`cm/in/carer/carersTotalAll.php`, the fourth tab after Active / Pending / Archived). One
row per carer, with no dates and no totals: the current state of every Active, Pending
and Archived care worker in the location. All Clients is built the same way
([powerbi_all_clients_setup.md](powerbi_all_clients_setup.md)).

The rules behind every column are in the model descriptions (`int__all_carers` in
`models/intermediate/_int__models.yml`, the marts in `models/marts/_mart__models.yml`).
This page says how to put them on the canvas.

## Who is on the list

- State 1, 2 or 3 (Active, Pending, Archived). Deleted (4) never. Care workers only
  (`permissionId` = 4); office users live in the same table.
- **Every carer of the location, whatever their area, workgroup or branch**, as on the
  page.
- An admin restricted to some branches or workgroups (`TenantArea`) sees only the carers
  of their areas, so carers with no area are hidden from them (decided 2026-10-27). The
  page shows those carers to every admin. The app no longer lets anyone save a carer
  without an area, so they are old records.
- Every build replaces the whole table. Nothing is historical.

## Tables

| Table | Grain | Role |
|---|---|---|
| `ALL_CARERS_REPORT` | carer | The list: every column of the page, and the RLS keys. |
| `BRIDGE_CARER_TAG` | carer + tag | Tags slicer. |
| `BRIDGE_CARER_WORKGROUP` | carer + workgroup + branch | Branch and Workgroup slicers. |
| `AREA_SCOPE` | area–workgroup–branch link | Hidden. Read only by the `TenantArea` role. |

Import from `ANALYTICS_MART.CARE_MANAGEMENT` through the `Server` parameter, like the
other embedded models ([powerbi_embedded_setup.md](powerbi_embedded_setup.md)). Plain
Import: there is no date, so no range to keep cold in DirectQuery.

`DIM_LOCATION` is not needed. The app shows one location at a time, and the page has no
location column. `LOCATION_KEY` is there for the MCP semantic view; hide it. A model that
adds `DIM_LOCATION` anyway must give it a strict rule, since it carries `COMPANY_ID`.

`DIM_CARER` is not used either. It holds current carers only (`deleted` is null), so it
would drop the Pending and Archived carers this list keeps.

## Relationships

Every bridge is many-to-one to the list, on the packed key (Whole number on both sides):

- `BRIDGE_CARER_TAG[CARER_KEY]` → `ALL_CARERS_REPORT[CARER_KEY]`
- `BRIDGE_CARER_WORKGROUP[CARER_KEY]` → `ALL_CARERS_REPORT[CARER_KEY]`

Set two things on each:

- **Cross filter direction: Both.** A slicer on a bridge column then filters the list.
  Picking one tag keeps the carers holding it. Picking two keeps the carers holding
  either, each once: the legacy "has any of the selected".
- **Apply security filter in both directions: off.** With it on, the bridge's role rule
  would reach the list through the bridge, and every carer with no tag or no workgroup
  would disappear from the list.

Two Both relationships on one table are fine here, because there is one path between any
two tables. A slicer on one bridge also narrows the slicers on the other: with a tag
picked, the Branch slicer lists only the branches of the carers holding it.
`AREA_SCOPE` has no relationships.

## RLS (embedded)

The same three roles as every other model, with the standard rules of
[powerbi_embedded_setup.md](powerbi_embedded_setup.md). The list and both bridges carry
`SOURCE`, `COMPANY_ID` and `LOCATION_ID` (a bridge row takes them from its carer), so
each gets a rule. `AREA_SCOPE` gets none, as in every model. Every rule is strict: no
table here has a blank row to keep.

| Role | `ALL_CARERS_REPORT` matches | Each bridge matches |
|---|---|---|
| `Tenant` | source + company | source + company |
| `TenantLocation` | source + company + location | source + company |
| `TenantArea` | source + company + location + area | source + company |

For the list's `TenantArea` rule, copy the rule on `ANNIVERSARY_REPORT` from the
Anniversary model's `roles/TenantArea.tmdl` and replace the table name: four places, all
in the `RETURN`. The area block is identical in every model.

The list's rule also reaches the bridges, through the relationships (one to many). The
slicers therefore offer only the tags, branches and workgroups of the carers the role
lets through. The bridge's own rule is the second line, as on every table with
`COMPANY_ID`. Under an area limit the `TenantArea` rule hides a carer with a blank
`AREA_ID`, the decision of 2026-10-27 above.

**The app's location filter** targets `ALL_CARERS_REPORT[LOCATION_ID]`. There is no
`Report Ready` gate, as in Birthday and Anniversary.

## Columns

The table visual shows the page's columns in the page's order. Users show and hide them
through a field parameter, as on the page. Create it with Modeling → New parameter →
Fields, add the fields below in this order, and rename each one to its header. Then save
the parameter's slicer with the **shown** ones selected, which are the legacy defaults.
The page remembers a user's choice in the browser; the report starts from the defaults on
every visit unless the app saves the report state for the user. Hide every list column
that is not in the parameter.

**Keep the key in the table.** A table visual groups rows by the values it shows. Two
carers with the same visible values would merge into one row, and with most columns
hidden that is common: two "Mary Smith, Active". Put `CARER_KEY` in the visual as a fixed
field outside the parameter, with a one-space header and the narrowest width, so there is
always one row per carer.

| # | Header | Field | Format | Default |
|---|---|---|---|---|
| | Flags | `Carer Flags` (measure, below) | | shown |
| 1 | No. | `CARER_NO` (carerNum in R3, carerId elsewhere) | text | shown |
| 2 | Name | `FULL_NAME` | | shown |
| 3 | Gender | `GENDER` | | hidden |
| 4 | Address | `ADDRESS` | | shown |
| 5 | Area | `AREA_NAME` | | hidden |
| 6 | County | `COUNTY` | | shown |
| 7 | Post Code | `POST_CODE` | | hidden |
| 8 | Phone | `PHONE` | | hidden |
| 9 | E-Mail | `EMAIL` | | shown |
| 10 | Tags | `TAGS` | | shown |
| 11 | Status | `STATUS` | background from `STATUS_COLOUR` | shown |
| 12 | Status Change | `STATUS_CHANGE_DATE` | `dd-mm-yyyy` | hidden |
| 13 | Comment | `STATUS_COMMENT` | | shown |
| 14 | Transport Type | `TRANSPORT_TYPE` | | hidden |
| 15 | Known As | `KNOWN_AS` | | shown |
| 16 | Pay Cycle | `PAY_CYCLE` | | hidden |
| 17 | Nationality | `NATIONALITY` | | hidden |

`TAGS` is comma-joined text for display. Filter on it through the bridge, never on the
text. The page has no Branch or Workgroup column; those are slicers only.

Kept but not shown: `FIRST_NAME`, `SURNAME`, `ADDRESS_LINE_1`, `TOWN` and `PHONE2`, all
read by the search. `STATE` is read by its slicer and the count measures.
`HAS_PRIVATE_NOTE`, `HAS_FUTURE_STATUS_CHANGE`, `IS_PAY_CYCLE_LOADED` and `STATUS_COLOUR`
are read by the measures. Hide the `*_KEY` and `*_ID` columns and `SOURCE`, but keep
them in the model: the roles and relationships read them. A hidden column can still sit
in a visual, so add the key to the table before you hide it.

**Sort** the table by Name, ascending. That is the page's own order (`fname, sname`). Do
not make `SURNAME` the Sort by column of `FULL_NAME`. Two carers can share a full name
split differently ("Mary Ann" + "Smith", "Mary" + "Ann Smith"), and Power BI then
refuses the sort.

## Slicers

Every slicer combines with every other one with AND, as the page's filters do.

| Slicer | Field |
|---|---|
| State | `ALL_CARERS_REPORT[STATE]` |
| Status | `ALL_CARERS_REPORT[STATUS]` |
| Branch | `BRIDGE_CARER_WORKGROUP[BRANCH_NAME]` |
| Workgroup | `BRIDGE_CARER_WORKGROUP[WORKGROUP_NAME]` |
| Area | `ALL_CARERS_REPORT[AREA_NAME]` |
| Tags | `BRIDGE_CARER_TAG[TAG_NAME]` |
| Transport Type | `ALL_CARERS_REPORT[TRANSPORT_TYPE]` |
| Pay Cycle | `ALL_CARERS_REPORT[PAY_CYCLE]` |

- **State** has no default selection. This report is the page's All tab.
- **Branch / Workgroup.** A carer matches a workgroup when their area sits in it, and a
  branch when their area sits in one of its workgroups. Every live workgroup is offered,
  also one with no branch, as in All Clients (decided 2026-10-27; the page offers only
  the workgroups of the picked branches). Leave the blank branch out of the Branch
  slicer. A carer whose area is in no workgroup drops out as soon as either slicer has a
  pick. On the page these two filters never
  narrowed the rows (a PHP bug). Here every slicer narrows the list, together with the
  others.
- **Tags.** Filter the slicer to the tags the page offers: `IS_CARER_TAG` = True, as a
  filter **on the slicer visual only**. As a page or report filter it would filter the
  bridge for every visual, and through the Both relationship the table would keep only
  carers holding a carer-side tag. Sort the slicer by name. `TAG_CATEGORY_ID` cannot be
  the Sort by column of `TAG_NAME`, because one name can carry two categories across the
  companies in the model.
- **Pay Cycle** is filled only in sources that have `cmCarerBank` (R2 care2, care3,
  care5 and beta on 2026-10-25). Elsewhere `IS_PAY_CYCLE_LOADED` is False on every row, and the blank means
  "not loaded", not "no pay cycle". A token reaches one source, so the flag is the same on
  every row a user sees. Give the slicer the visual filter `Pay Cycle Loaded is 1`, so it
  stays empty where nothing is loaded:

  ```dax
  Pay Cycle Loaded =
  IF ( SELECTEDVALUE ( ALL_CARERS_REPORT[IS_PAY_CYCLE_LOADED], FALSE () ), 1, 0 )
  ```

A slicer lists only values that some carer on the list has. The page's dropdowns list
every live branch, workgroup, area and tag of the location, including empty ones.

Under `TenantArea`, the Workgroup slicer can list a workgroup outside the admin's list
when an allowed area also sits in it. Picking it shows only carers the role already lets
through, so nothing leaks.

## Search

As in the Anniversary model: a DAX column `Search Text` on the list, and Microsoft's
certified **Text Filter** visual on it. It replaces the page's one box per column with
one box over the same columns, and has no three-character minimum. `FIRST_NAME &
SURNAME` keeps the page's "JohnSmith finds John Smith", and `PHONE2` the page's search
on the second phone, which it never shows.

```dax
Search Text =
VAR Sep = " | "
RETURN
    ALL_CARERS_REPORT[CARER_NO] & Sep
        & ALL_CARERS_REPORT[FULL_NAME] & Sep
        & ALL_CARERS_REPORT[FIRST_NAME] & ALL_CARERS_REPORT[SURNAME] & Sep
        & ALL_CARERS_REPORT[ADDRESS_LINE_1] & Sep
        & ALL_CARERS_REPORT[TOWN] & Sep
        & ALL_CARERS_REPORT[COUNTY] & Sep
        & ALL_CARERS_REPORT[POST_CODE] & Sep
        & ALL_CARERS_REPORT[PHONE] & Sep
        & ALL_CARERS_REPORT[PHONE2] & Sep
        & ALL_CARERS_REPORT[EMAIL]
```

Gender, Area, Tags, the status columns, Known As, Pay Cycle, Nationality and Transport
Type are not in it. The page has no text search on them, and those it filters at all
have a slicer here.

## Measures

```dax
Carers = COUNTROWS ( ALL_CARERS_REPORT )
Active Carers = CALCULATE ( [Carers], ALL_CARERS_REPORT[STATE] = "Active" )
Pending Carers = CALCULATE ( [Carers], ALL_CARERS_REPORT[STATE] = "Pending" )
Archived Carers = CALCULATE ( [Carers], ALL_CARERS_REPORT[STATE] = "Archived" )
Has Data = IF ( ISEMPTY ( ALL_CARERS_REPORT ), 0, 1 )
```

The list has one row per carer, so `COUNTROWS` counts carers. Under a tag or branch
slicer, the Both relationship has already cut the list to distinct carers, so nobody
counts twice. `Has Data` goes on each slicer as the visual filter `Has Data is 1`, as in
Anniversary, so a slicer lists only values that still have carers under the other
slicers.

**Breakdowns overlap.** On a chart with tag, branch or workgroup on the axis, a carer
counts under every tag they hold, and under every branch and workgroup their area sits
in, while a carer with none of them is under no bar. The bars therefore do not add up to
`[Carers]`. A table's total row is right; a sum of the bars is not.

**Flags in front of No.** stand in for the page's icons: a warning for a private note and
a clock for a status change that is still to run.

```dax
Carer Flags =
VAR PrivateNote = SELECTEDVALUE ( ALL_CARERS_REPORT[HAS_PRIVATE_NOTE], FALSE () )
VAR FutureStatus = SELECTEDVALUE ( ALL_CARERS_REPORT[HAS_FUTURE_STATUS_CHANGE], FALSE () )
RETURN
    IF ( PrivateNote, "⚠", "" ) & IF ( FutureStatus, "⏱", "" )
```

It returns an empty string, never BLANK. It is the table's only measure, so a BLANK
would drop every row without a flag.

**Status colour**, the page's coloured status label. `STATUS_COLOUR` holds a Bootstrap 3
class name, not a colour: `info`, `danger`, `primary`, `success` or `warning` (every
value on R2 PROD, 2026-10-25). Map it to the Bootstrap 3 label colours, the palette
Anniversary's `State Colour` already uses. Then apply the measure as Format → Cell
elements → Background colour → Field value on `STATUS`, with white text on that column:

```dax
Carer Status Colour =
SWITCH (
    LOWER ( TRIM ( SELECTEDVALUE ( ALL_CARERS_REPORT[STATUS_COLOUR] ) ) ),
    "primary", "#337ab7",
    "success", "#5cb85c",
    "info", "#5bc0de",
    "warning", "#f0ad4e",
    "danger", "#d9534f"
)
```

A status with no colour gets no background. To colour whole rows by state as Birthday
and Anniversary do, reuse Anniversary's `State Colour` measure.

## What differs from the legacy page

Decided in the build (the model descriptions say more):

- A restricted admin does not see carers with no area; the page shows them to every
  admin (see the top).
- Branch and Workgroup slicers narrow the list; the page's never did.
- The Workgroup slicer also offers workgroups with no branch, as in All Clients; the
  page offers only the workgroups of the picked branches.
- A carer whose area was deleted, but still has live workgroup links, is always listed.
  On the page it was hidden on first load and shown after Reset Filters.
- Pay Cycle takes the newest `cmCarerBank` row; the page took whichever row MySQL
  returned.

Not portable to a report with fixed headers:

- The company's own words: its label for carer (`carerCall`, e.g. "Staff", "Care
  Worker") and "Agent Ref" for Known As in company 164. The report uses the headers above.
- Tags as coloured labels. A cell holds one text, so tags are comma-joined.
- Name as a link to the carer summary page. The report does not know the app's address.

## Testing

- DEV works as it is. It is a stale copy, but nothing here depends on the date.
- **Against the page.** For one location, compare the report with the legacy All tab
  after Reset Filters, as an unrestricted admin, soon after a build. Both must list the
  same carers, those with no area included. As a restricted admin, the report shows the
  page's carers less those with no area.
- **Roles**, as in [powerbi_embedded_setup.md](powerbi_embedded_setup.md#test-before-the-first-customer):
  *View as* `Tenant` and `TenantLocation`, and `TenantArea` in a scratch copy with a
  literal `customData`.
- **Slicers.** Two tags picked: each holder appears once. With nothing picked, a carer
  with no tag and no area is still on the list; if not, "Apply security filter in both
  directions" is on. A branch picked: only carers whose area sits in one of its workgroups.

## Deploying

As for every model ([powerbi_embedded_setup.md](powerbi_embedded_setup.md#deploying-a-semantic-model)):
a `Server` parameter rule in each pipeline stage, credentials in each workspace, and a
refresh after each dbt deploy. The tables appear in an account with the first dbt deploy
that builds them. Publish the model after that deploy, or its first refresh fails on
missing tables.
