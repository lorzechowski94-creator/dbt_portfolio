# All Clients — Power BI setup

A list report, the port of the legacy **All Clients** page (`cm/in/clientsTotalAll.php`,
the fourth tab after Active / Pending / Archived). One row per client, with no dates and
no totals: the current state of every Active, Pending and Archived client in the
location. All Carers is built the same way
([powerbi_all_carers_setup.md](powerbi_all_carers_setup.md)).

The rules behind every column are in the model descriptions (`int__all_clients` in
`models/intermediate/_int__models.yml`, the marts in `models/marts/_mart__models.yml`).
This page says how to put them on the canvas.

## Who is on the list

- State 1, 2 or 3 (Active, Pending, Archived). Deleted (4) never.
- **Every client of the location, whatever their area, workgroup or branch**, as on the
  page. A client with no area, or with an area in no live workgroup, is listed with
  blank Branch and Workgroup columns. All Carers works the same way.
- An admin restricted to some branches or workgroups (`TenantArea`) sees only the clients
  of their areas, so clients with no area are hidden from them, as on the page.
- Every build replaces the whole table. Nothing is historical.

## Tables

| Table | Grain | Role |
|---|---|---|
| `ALL_CLIENTS_REPORT` | client | The list: every column of the page, and the RLS keys. |
| `BRIDGE_CLIENT_TAG` | client + tag | Tags slicer. |
| `BRIDGE_CLIENT_WORKGROUP` | client + workgroup + branch | Branch and Workgroup slicers. |
| `BRIDGE_CLIENT_JOB_TYPE` | client + job type | Job Type slicer. |
| `AREA_SCOPE` | area–workgroup–branch link | Hidden. Read only by the `TenantArea` role. |

Import from `ANALYTICS_MART.CARE_MANAGEMENT` through the `Server` parameter, like the
other embedded models ([powerbi_embedded_setup.md](powerbi_embedded_setup.md)). Plain
Import: there is no date, so no range to keep cold in DirectQuery.

`DIM_LOCATION` is not needed. The app shows one location at a time, and the page has no
location column. `LOCATION_KEY` is there for the MCP semantic view; hide it. A model that
adds `DIM_LOCATION` anyway must give it a strict rule, since it carries `COMPANY_ID`.

`DIM_CLIENT` is not used either. It keeps every client of the client table for the hours
reports, deleted ones included, so it would not match this list.

## Relationships

Every bridge is many-to-one to the list, on the packed key (Whole number on both sides):

- `BRIDGE_CLIENT_TAG[CLIENT_KEY]` → `ALL_CLIENTS_REPORT[CLIENT_KEY]`
- `BRIDGE_CLIENT_WORKGROUP[CLIENT_KEY]` → `ALL_CLIENTS_REPORT[CLIENT_KEY]`
- `BRIDGE_CLIENT_JOB_TYPE[CLIENT_KEY]` → `ALL_CLIENTS_REPORT[CLIENT_KEY]`

Set two things on each:

- **Cross filter direction: Both.** A slicer on a bridge column then filters the list.
  Picking one tag keeps the clients holding it. Picking two keeps the clients holding
  either, each once: the legacy "has any of the selected".
- **Apply security filter in both directions: off.** With it on, the bridge's role rule
  would reach the list through the bridge, and every client with no tag, no job type or
  no workgroup would disappear from the list.

Three Both relationships on one table are fine here, because there is one path between
any two tables. A slicer on one bridge also narrows the slicers on the others: with a tag
picked, the Branch slicer lists only the branches of the clients holding it.
`AREA_SCOPE` has no relationships.

## RLS (embedded)

The same three roles as every other model, with the standard rules of
[powerbi_embedded_setup.md](powerbi_embedded_setup.md). The list and every bridge carry
`SOURCE`, `COMPANY_ID` and `LOCATION_ID` (a bridge row takes them from its client), so
each gets a rule. `AREA_SCOPE` gets none, as in every model. Every rule is strict: no
table here has a blank row to keep.

| Role | `ALL_CLIENTS_REPORT` matches | Each bridge matches |
|---|---|---|
| `Tenant` | source + company | source + company |
| `TenantLocation` | source + company + location | source + company |
| `TenantArea` | source + company + location + area | source + company |

For the list's `TenantArea` rule, copy the rule on `ANNIVERSARY_REPORT` from the
Anniversary model's `roles/TenantArea.tmdl` and replace the table name: four places, all
in the `RETURN`. The area block is identical in every model.

The list's rule also reaches the bridges, through the relationships (one to many). The
slicers therefore offer only the tags, branches, workgroups and job types of the clients
the role lets through. The bridge's own rule is the second line, as on every table with
`COMPANY_ID`. Under an area limit the `TenantArea` rule hides a client with a blank
`AREA_ID`, which is what the page does once an admin's scope has a value.

**The app's location filter** targets `ALL_CLIENTS_REPORT[LOCATION_ID]`. There is no
`Report Ready` gate, as in Birthday and Anniversary.

## Columns

The table visual shows the page's columns in the page's order: 1–4, then Branch and
Workgroup, then 5–18. Users show and hide them through a field parameter, as on the page.
Create it with Modeling → New parameter → Fields, add the fields below in this order, and
rename each one to its header. Then save the parameter's slicer with the **shown** ones
selected, which are the legacy defaults. The page remembers a user's choice in the
browser; the report starts from the defaults on every visit unless the app saves the
report state for the user. Hide every list column that is not in the parameter.

**Keep the key in the table.** A table visual groups rows by the values it shows. Two
clients with the same visible values would merge into one row, and with most columns
hidden that is common: two "Mary Smith, Active". Put `CLIENT_KEY` in the visual as a
fixed field outside the parameter, with a one-space header and the narrowest width, so
there is always one row per client.

| # | Header | Field | Format | Default |
|---|---|---|---|---|
| | Flags | `Client Flags` (measure, below) | | shown |
| 1 | No. | `CLIENT_NO` (residentId) | text | shown |
| 2 | Name | `FULL_NAME` | | shown |
| 3 | Gender | `GENDER` | | hidden |
| 4 | Address | `ADDRESS` | | shown |
| 19 | Branch | `BRANCH_NAMES` | | shown |
| 20 | Workgroup | `WORKGROUP_NAMES` | | shown |
| 5 | Area | `AREA_NAME` | | hidden |
| 6 | County | `COUNTY` | | shown |
| 7 | Post Code | `POST_CODE` | | hidden |
| 8 | E-mail | `EMAIL` | | hidden |
| 9 | Phone | `PHONE` | | shown |
| 10 | DOB | `DATE_OF_BIRTH` | `dd-mmm-yyyy` | shown |
| 11 | Job Type | `JOB_TYPES` | | shown |
| 12 | Tags | `TAGS` | | hidden |
| 13 | Status | `STATUS` | background from `STATUS_COLOUR` | shown |
| 14 | Status Change | `STATUS_CHANGE_AT` | `dd-mm-yyyy hh:nn` | hidden |
| 15 | Comment | `STATUS_COMMENT` | | shown |
| 16 | First Contact | `FIRST_CONTACT_DATE` | `dd-mm-yyyy` | hidden |
| 17 | Service Commenced | `SERVICE_COMMENCED_DATE` | `dd-mm-yyyy` | hidden |
| 18 | Council Id | `COUNCIL_ID` | | hidden |

`BRANCH_NAMES`, `WORKGROUP_NAMES`, `TAGS` and `JOB_TYPES` are comma-joined text for
display. Filter on them through the bridges, never on the text. Branch and Workgroup are
blank for a client whose area is in no workgroup. Job Type keeps the order of the
client's list and also names deleted job types, as the page does; the Job Type slicer
offers only the live ones.

Kept but not shown: `FIRST_NAME`, `SURNAME`, `ADDRESS_LINE_1`, `TOWN`, `PHONE_HOME` and
`PHONE_MOBILE`, all read by the search. `STATE` is read by its slicer and the count
measures. `HAS_PRIVATE_NOTE`, `HAS_FUTURE_STATUS_CHANGE`, `IS_LOCATION_CONFIRMED` and
`STATUS_COLOUR` are read by the measures. Hide the `*_KEY` and `*_ID` columns and
`SOURCE`, but keep them in the model: the roles and relationships read them. A hidden
column can still sit in a visual, so add the key to the table before you hide it.

**Sort** the table by Name, ascending. That is the page's own order (`fname, sname`). Do
not make `SURNAME` the Sort by column of `FULL_NAME`. Two clients can share a full name
split differently ("Mary Ann" + "Smith", "Mary" + "Ann Smith"), and Power BI then
refuses the sort.

## Slicers

Every slicer combines with every other one with AND, as the page's filters do.

| Slicer | Field |
|---|---|
| State | `ALL_CLIENTS_REPORT[STATE]` |
| Status | `ALL_CLIENTS_REPORT[STATUS]` |
| Branch | `BRIDGE_CLIENT_WORKGROUP[BRANCH_NAME]` |
| Workgroup | `BRIDGE_CLIENT_WORKGROUP[WORKGROUP_NAME]` |
| Area | `ALL_CLIENTS_REPORT[AREA_NAME]` |
| Tags | `BRIDGE_CLIENT_TAG[TAG_NAME]` |
| Job Type | `BRIDGE_CLIENT_JOB_TYPE[JOB_TYPE_NAME]` |

- **State** has no default selection. This report is the page's All tab.
- **Branch / Workgroup.** A client matches a workgroup when their area sits in it, and a
  branch when their area sits in one of its workgroups, as on the page. The Workgroup
  slicer also lists workgroups with no branch. Those rows have a blank `BRANCH_NAME`, so
  give the Branch slicer the visual filter `BRANCH_NAME is not blank`. A client whose
  area is in no workgroup drops out as soon as either slicer has a pick, as on the page.
  On the page a Workgroup pick overrode Branch, and Area was ignored when either was
  picked. Here every slicer narrows the list, together with the others.
- **Tags.** Filter the slicer to the tags the page offers: `IS_CLIENT_TAG` = True, as a
  filter **on the slicer visual only**. As a page or report filter it would filter the
  bridge for every visual, and through the Both relationship the table would keep only
  clients holding a client-side tag. Sort the slicer by name. `TAG_CATEGORY_ID` cannot
  be the Sort by column of `TAG_NAME`, because one name can carry two categories across
  the companies in the model.
- **Job Type** matches the job type exactly. The page matched the id as a substring of
  the client's list, so job type 1 also found 10, 11 and 21.

A slicer lists only values that some client on the list has. The page's dropdowns list
every live branch, workgroup, area and tag of the location, including empty ones.

Under `TenantArea`, the Workgroup slicer can list a workgroup outside the admin's list
when an allowed area also sits in it. Picking it shows only clients the role already lets
through, so nothing leaks.

## Search

As in the Anniversary model: a DAX column `Search Text` on the list, and Microsoft's
certified **Text Filter** visual on it. It replaces the page's one box per column with
one box over the same columns, and has no three-character minimum. `FIRST_NAME &
SURNAME` keeps the page's "JohnSmith finds John Smith". The dates are in the
`yyyy-MM-dd` form the page searches, so `1950-03` finds a client born in March 1950.

```dax
Search Text =
VAR Sep = " | "
RETURN
    ALL_CLIENTS_REPORT[CLIENT_NO] & Sep
        & ALL_CLIENTS_REPORT[FULL_NAME] & Sep
        & ALL_CLIENTS_REPORT[FIRST_NAME] & ALL_CLIENTS_REPORT[SURNAME] & Sep
        & ALL_CLIENTS_REPORT[ADDRESS_LINE_1] & Sep
        & ALL_CLIENTS_REPORT[TOWN] & Sep
        & ALL_CLIENTS_REPORT[COUNTY] & Sep
        & ALL_CLIENTS_REPORT[POST_CODE] & Sep
        & ALL_CLIENTS_REPORT[EMAIL] & Sep
        & ALL_CLIENTS_REPORT[PHONE_HOME] & Sep
        & ALL_CLIENTS_REPORT[PHONE_MOBILE] & Sep
        & FORMAT ( ALL_CLIENTS_REPORT[DATE_OF_BIRTH], "yyyy-MM-dd" ) & Sep
        & FORMAT ( ALL_CLIENTS_REPORT[FIRST_CONTACT_DATE], "yyyy-MM-dd" ) & Sep
        & FORMAT ( ALL_CLIENTS_REPORT[SERVICE_COMMENCED_DATE], "yyyy-MM-dd" ) & Sep
        & ALL_CLIENTS_REPORT[COUNCIL_ID]
```

Gender, Area, Branch, Workgroup, Job Type, Tags and the status columns are not in it.
The page has no text search on them, and those it filters at all have a slicer here.

## Measures

```dax
Clients = COUNTROWS ( ALL_CLIENTS_REPORT )
Active Clients = CALCULATE ( [Clients], ALL_CLIENTS_REPORT[STATE] = "Active" )
Pending Clients = CALCULATE ( [Clients], ALL_CLIENTS_REPORT[STATE] = "Pending" )
Archived Clients = CALCULATE ( [Clients], ALL_CLIENTS_REPORT[STATE] = "Archived" )
Has Data = IF ( ISEMPTY ( ALL_CLIENTS_REPORT ), 0, 1 )
```

The list has one row per client, so `COUNTROWS` counts clients. Under a tag, branch or
job type slicer, the Both relationship has already cut the list to distinct clients, so
nobody counts twice. `Has Data` goes on each slicer as the visual filter `Has Data is 1`,
as in Anniversary, so a slicer lists only values that still have clients under the other
slicers.

**Breakdowns overlap.** On a chart with tag, branch, workgroup or job type on the axis,
a client counts under every tag and job type they hold, and under every branch and
workgroup their area sits in, while a client with none of them is under no bar. The bars
therefore do not add up to `[Clients]`. A table's total row is right; a sum of the bars
is not.

**Flags in front of No.** stand in for the page's icons: a warning for a private note, a
clock for a status change that is still to run, and a pin for "location not confirmed",
the page's marker next to the post code.

```dax
Client Flags =
VAR PrivateNote = SELECTEDVALUE ( ALL_CLIENTS_REPORT[HAS_PRIVATE_NOTE], FALSE () )
VAR FutureStatus = SELECTEDVALUE ( ALL_CLIENTS_REPORT[HAS_FUTURE_STATUS_CHANGE], FALSE () )
VAR Located = SELECTEDVALUE ( ALL_CLIENTS_REPORT[IS_LOCATION_CONFIRMED], TRUE () )
RETURN
    IF ( PrivateNote, "⚠", "" ) & IF ( FutureStatus, "⏱", "" ) & IF ( Located, "", "📍" )
```

It returns an empty string, never BLANK. It is the table's only measure, so a BLANK
would drop every row without a flag.

**Status colour**, the page's coloured status label. `STATUS_COLOUR` holds a Bootstrap 3
class name, not a colour: `info`, `danger`, `primary`, `success` or `warning` (every
value on R2 PROD, 2026-10-25). Map it to the Bootstrap 3 label colours, the palette
Anniversary's `State Colour` already uses. Then apply the measure as Format → Cell
elements → Background colour → Field value on `STATUS`, with white text on that column:

```dax
Client Status Colour =
SWITCH (
    LOWER ( TRIM ( SELECTEDVALUE ( ALL_CLIENTS_REPORT[STATUS_COLOUR] ) ) ),
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

- Branch, Workgroup and Area slicers all narrow the list, and they narrow only inside
  the role. The page let a restricted admin pick any area of the location and see its
  clients.
- Deleted tags are gone from the Tags column and slicer alike; the page still shows them
  in its column. A client holding two of the selected tags is one row; the page listed
  them twice.
- A workgroup whose only branch link is deleted shows with a blank branch; the page
  drops that workgroup from its column.
- Gender reads Female / Male (`F` or `2`, `M` or `1`, or the word spelled out); any
  other code is blank. The page does not read the spelled-out words.

Not portable to a report with fixed headers:

- The company's own words: its label for client (`clientCall`, e.g. "Customer", "Service
  User") and its first-contact and service-commenced headers. The report uses the headers
  above.
- Tags as coloured labels. A cell holds one text, so tags are comma-joined.
- Name as a link to the client summary page. The report does not know the app's address.

## Testing

- DEV works as it is. It is a stale copy, but nothing here depends on the date.
- **Against the page.** For one location, compare the report with the legacy All tab
  after Reset Filters, as an unrestricted admin, soon after a build. Both must list the
  same clients, those with no area included, and the same Branch, Workgroup and Job
  Type values.
- **Roles**, as in [powerbi_embedded_setup.md](powerbi_embedded_setup.md#test-before-the-first-customer):
  *View as* `Tenant` and `TenantLocation`, and `TenantArea` in a scratch copy with a
  literal `customData`.
- **Slicers.** Two tags picked: each holder appears once. With nothing picked, a client
  with no tag, no job type and no area is still on the list; if not, "Apply security
  filter in both directions" is on. A branch picked: only clients whose area sits in one
  of its workgroups. A workgroup with no branch picked: its clients appear. A job type
  picked: only clients with that exact, live job type.

## Deploying

As for every model ([powerbi_embedded_setup.md](powerbi_embedded_setup.md#deploying-a-semantic-model)):
a `Server` parameter rule in each pipeline stage, credentials in each workspace, and a
refresh after each dbt deploy. The tables appear in an account with the first dbt deploy
that builds them. Publish the model after that deploy, or its first refresh fails on
missing tables.
