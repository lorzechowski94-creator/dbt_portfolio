# Power BI Embedded (app owns data) — tenancy, embed token, deployment

The reports are delivered through **Power BI Embedded, "app owns data"**,
on an F SKU capacity. This page is the contract between the semantic models and the
backend that embeds them, plus what has to be true before the first customer sees a
report.

The seven report projects (PBIP) live outside this repo; see the team's Power BI
folder. Each semantic model carries two roles, **`Tenant`** and
**`TenantLocation`**, one per kind of care admin.

## How tenancy works

Every embedded query authenticates as **one** identity, the backend's service
principal. Snowflake's `current_role()` therefore cannot tell customers apart, so the
`report__*` secure views (`customer_access_filter`) are not the boundary for these
reports. Per-user SSO to Snowflake is not an option either: with app owns data, SSO
supports only Azure SQL Database as a DirectQuery source.

So the models are **Import**. Power BI RLS works the same on Import as on
DirectQuery, so the RLS gives no reason to switch. The models read
`ANALYTICS_MART.CARE_MANAGEMENT`, which holds every customer in the account. The
model's roles are the only thing that separates customers. They follow the care
app's admin permission model (`carer.permissionId`), which is the same in every
care:

> Between 2026-10-05 and 2026-10-20 the models ran on usernames without the source
> (`"2"`, `"2|35"`). Every model is back on the source-aware usernames below, and the
> old care-less ones now see **no rows**.

| permissionId | Behaviour in the care app | Role | Username |
|---|---|---|---|
| 2 or 3, with a branch or workgroup restriction for the active location | As below, limited to some areas | `TenantArea` | `"<source>\|<company_id>\|<location_id>"`, plus `customData` (see [Branch and workgroup restrictions](#branch-and-workgroup-restrictions-tenantarea)) |
| 2, company admin | Picks any location of the company and can switch | `Tenant` | `"<source>\|<company_id>"`, e.g. `"care2\|2"` |
| 3, local admin | Locked to `carer.location`, no switching | `TenantLocation` | `"<source>\|<company_id>\|<location_id>"`, e.g. `"care2\|2\|35"` |
| 4, carer | No reports | none | **Do not issue a token** |
| anything else | — | none | **Do not issue a token** |

The rows are checked top to bottom. A company admin with a restriction in **any**
location never gets `Tenant`: `Tenant` covers the whole company, and the location is
then only a filter that the browser can change, which would open the restricted
location in full. Such an admin gets a token for the active location instead:
`TenantArea` where that location restricts them, `TenantLocation` where it does not.
The token is re-issued when they switch.

`<source>` is the source schema the user's care database is loaded into, written as
the models' `SOURCE` column holds it: `care1` … `care5`, `alpha`, `alpha2`. It is the same
token that prefixes the Snowflake reader roles (`ANALYTICS__CARE2_02_READER`).

For a company admin, `carer.location` is only a placeholder for where the admin was
created. It never goes into their token: `TenantLocation` with that value would lock
them into one location they are free to leave.

- **Tokens are per account.** DEV, R1, R2 and R3 are separate Snowflake accounts.
  Each account gets its **own copy of every semantic model**, repointed with the
  `Server` parameter, in its own workspace. A token names only datasets of the
  customer's own account. The same number can be a different company in another
  account.
- Workspaces keep **accounts** apart, not cares. The R2 models hold care2, care3 and
  care5 together, and location ids repeat across them. What keeps tenants apart
  inside one model is that **every rule matches `SOURCE` and `COMPANY_ID`**,
  including the location rule. Never scope by `location_id` alone, and never drop
  the source.
- **A token reaches one care.** The username starts with the source, so a company
  admin sees their company in that care only, and a local admin sees one location
  of one care: the same scope as `ANALYTICS__<SOURCE>_<NN>_READER` and
  `ANALYTICS__<SOURCE>_<NN>_L<id>_READER` in Snowflake. This matters for locations:
  on R2 prod, care2 and care5 share 103 (company, location) pairs, and 25 of them
  carry different names, e.g. id 1 is "Demo" in care2 and "Aged Care" in care5.
  Until 2026-10 the username carried no care and a local admin of such an id saw
  both. A customer present in two cares gets one token per care.
- Each rule reads `USERNAME()`. A username of the wrong shape resolves to an empty
  source and 0, and sees no rows, so the model fails closed on garbage — including a
  username in the old care-less format (`"2"`, `"2|35"`).

The `report__*` views stay as they are. They still serve anything that queries
Snowflake as a reader role, such as the MCP semantic views. Those roles carry the
care too (`ANALYTICS__CARE2_02_READER`, see `models/access/_access__models.yml`).

## Embed token contract (backend)

Generate the token with a **service principal**, never a master user.

**`identities` is mandatory, and that is the safety net.** The service principal is
a workspace Member, so in the service itself it sees everything: deployment,
refresh, XMLA. RLS does not apply to it there. An *embed token* is different. For a
model with roles, a service principal's `GenerateToken` without an identity
**fails**, so no code path can mint an unscoped customer token by accident. A master
user's request would succeed and return **every customer's data**, which is one more
reason not to use one.

If internal staff ever need every company in an embedded report, that takes a third,
filterless role, passed deliberately and only for internal users. No such role
exists today.

```http
POST https://api.powerbi.com/v1.0/myorg/GenerateToken
Authorization: Bearer <service principal token for https://analysis.windows.net/powerbi/api/.default>

{
  "reports":  [ { "id": "<report id>" } ],
  "datasets": [ { "id": "<dataset id>" } ],
  "identities": [
    {
      "username": "care2|2",
      "roles":    [ "Tenant" ],
      "datasets": [ "<dataset id>" ],
      "auditableContext": "user:<carer.id>"
    }
  ],
  "lifetimeInMinutes": 15
}
```

### Why the scope rides in `username`, not `customData`

Both are valid for a Power BI (cloud) model. `username` + `USERNAME()` was chosen for
three reasons:

- It is Microsoft's documented pattern for dynamic RLS in app owns data. The
  `CUSTOMDATA()` walkthrough exists only for Azure Analysis Services.
- **It can be tested in Desktop.** *View as → Other user* sets `USERNAME()`, but
  nothing in Desktop sets `CUSTOMDATA()`. That would push every RLS test out to the
  service.
- It is long enough: up to 256 ASCII characters with no spaces, and the scope is at
  most `"care2|2|35"`.

Every request reaches Power BI as the same service principal, so the audit trail
needs the application user. Without `auditableContext`, the `GenerateToken` audit
record leaves the effective identity out entirely. With it, the API reference says
its value is recorded as the username. Check what actually lands in the activity log
on the first test token before you rely on it. The one thing that does not fit
`username` is a restricted admin's branch and workgroup lists (up to about 500
characters), so those ride in `customData` (1,024 characters) for `TenantArea`
only.

### Who decides the role

Power BI never authenticates the end user. It enforces whatever the token says. The
decision is made in the care app's backend, every time it issues or renews a token:

1. The user logs in to the care app as today, against their `carer` row. That is
   the only authentication.
2. The session holds **who** they are: `carer.id`, written once at login.
3. On every token request the backend reads **what they may see now** from the
   care database by that id: `permissionId`, `companyId`, `location`, and whether
   the row is deleted. The care comes from the backend's own configuration: which
   care database it is connected to. It then picks the role and username from the
   table above. Anything that maps to no role gets a 403, and no token is
   requested.
4. The backend calls `GenerateToken` as the service principal. Power BI signs the
   token, with the role and username inside it. The browser can't change either
   without breaking the signature. All it can change is report filters, and those
   never reach past the role.
5. On every query, Power BI runs the role's DAX with `USERNAME()` set to the token's
   username.

Re-reading the row on each request, not caching it in the session, is what makes
a demotion (2 → 3), a transfer or a deletion take effect within one token lifetime
instead of at the next login.

Rules:

- **Never take any part of `username` or `roles` from the browser or a request
  parameter.** The session supplies the user id, the backend's configuration
  supplies the care, and the database supplies the rest.
- **`roles` holds exactly one role.** Roles are additive: `["Tenant",
  "TenantLocation"]` would give a local admin the whole company.
- A company admin's *selected* location does not go into the token. It is a filter
  (see below), because they may switch locations without a new token.
- List every dataset in the token under that one identity. For example, a token for
  two reports on two datasets names both datasets in `datasets` and in the
  identity's `datasets`.
- View only: no `allowEdit`, and no workspace in `targetWorkspaces`.
- **Short life:** set `lifetimeInMinutes` to 10–15. The frontend renews through the
  backend before expiry (`report.setAccessToken`). Each renewal repeats steps 2–4
  above, so a logout or permission change lands within minutes.
- An embed token can't outlive the Entra token that created it. Cache the Entra
  token in the backend and reuse it while it has more life left than the embed TTL
  plus a margin. Fetching a new one per report adds latency and invites throttling.
  The Entra token never goes to the browser.
- The session's user id must be written once, at login, and be impossible to
  overwrite from request data. `session_regenerate_id(true)` belongs right after a
  successful login. A session an attacker can plant or overwrite mints tokens for
  whoever they choose.

### The filters the app still sets

Every report in the care app is scoped to one active location at a time. The app sets that
location, plus the date range, as report filters through `powerbi-client`, exactly
as today. The active location is:

- for a **company admin**, the location they entered from the picker. It changes
  when they switch, with no new token.
- for a **local admin**, always `carer.location`, the same value as in their token.
  A different value would show an empty report.

The app sets these filters for both admin kinds. RLS is invisible to `ISFILTERED`,
so the `Report Ready` gates need the filters even when `TenantLocation` has already
cut the model to the same location. A location that belongs to another company
returns nothing.

| Report | Filters the app sets |
|---|---|
| Client Hours | `DIM_DATE[CALENDAR_DATE]`, `DIM_CLIENT[LOCATION_ID]` |
| Continuity | `DIM_DATE[CALENDAR_DATE]`, `DIM_CLIENT[LOCATION_ID]` |
| Carer Hours | `DIM_DATE[CALENDAR_DATE]`, `DIM_CARER[LOCATION_ID]` |
| Schedule Difference | `DIM_DATE[CALENDAR_DATE]`, `SCHEDULE_DIFFERENCE_REPORT[LOCATION_ID]` |
| Carer Qualification | `CARER_QUALIFICATION_REPORT[LOCATION_ID]` |
| Plans Taken (not built yet) | `PLANS_TAKEN_REPORT[LOCATION_ID]` (no gate) |
| Birthday, Anniversary | the report table's `LOCATION_ID` (no gate) |
| All Carers, All Clients (not built yet) | the report table's `LOCATION_ID` (no gate) |
| Plan & Assessment Dates (not built yet) | `DIM_LOCATION[LOCATION_ID]`, one filter for its three lists (no gate) |
| Task Review (not built yet) | `TASK_REVIEW_REPORT[LOCATION_ID]` (no gate) |

Client Hours, Carer Hours and Schedule Difference keep recent rows in memory and read
older ones from Snowflake (DirectQuery). Their date filter must target `DIM_DATE[CALENDAR_DATE]`,
not the fact's date column: only a filter on that date table lets the Power BI service
answer a recent range from memory without querying Snowflake. A filter on the fact's
date leaves the `Report Ready` gate closed, so the report stays empty.

Continuity is Import only, but its date filter targets `DIM_DATE[CALENDAR_DATE]` too. Its
date slicer moved there in 2026-10 for two reasons. A slicer on the fact's date ignores the
`dd/mm/yyyy` format and shows dates month first. And the Year columns clear `DIM_DATE` to widen
the period to whole years, which a filter on the fact's date survives. Its `Report Ready` gate
still accepts `CONTINUITY_REPORT[SERVICE_DATE]`, so an app that filters there keeps working,
but its Year columns then show the period instead of whole years.

A user can change these filters from the browser with the JavaScript API:

- A **company admin** would reach other locations of their own company. They may see
  those anyway by switching, so it is not a leak.
- A **local admin** gets nothing new, because `TenantLocation` enforces their
  location in the model itself.

**There is no Source filter in the reports any more.** Each report used to carry a
hidden Source slicer on the care column, shown and hidden by two icons in the top-right
corner and a pair of bookmarks. Since the role cuts the model to one source, the
slicer would only ever list one value, so the slicer, both icons and their bookmarks
were removed (2026-10). `Text Search`, which shared that slot, is now always visible.

### Branch and workgroup restrictions (`TenantArea`)

The care app can restrict an admin to some branches or workgroups of a location
(`cmLevelAccess`), and the legacy reports apply that as `area IN (...)`. `Tenant` and
`TenantLocation` stop at company + location, so until the backend sends `TenantArea`
such an admin sees the whole location (a live exposure, 2026-10).

The legacy area list comes from `getAccessList()` in `menu.php`. It holds
the areas of the admin's **workgroup** list (`cmLevelAreaWorkgroup`). The branch list
counts only when no workgroup was picked, and then it supplies the workgroups of
those branches (`cmLevelWorkgroupBranch`). The two lists are never combined, neither
as a union nor as an intersection. A workgroup belongs to one branch at most, and an
area can sit in several workgroups.

The fix is a third role, `TenantArea`, in every model:

- The token keeps `"<source>|<company_id>|<location_id>"` in `username` and carries
  the admin's branch and workgroup ids in `customData`, as
  `"<branch ids>/<workgroup ids>"` (e.g. `"12,14/7,9"`). The area list itself does
  not fit any token field: over 1,000 characters for some admins. A backend that
  sends the workgroup list already filled in from the branches leaves the branch
  part empty (`"/7,9"`), and the same role works.
- The role applies the legacy rule through the hidden `AREA_SCOPE` table
  (`mart__area_scope`, no relationships, no rule of its own): the workgroups of the
  token, or, when that part is empty, the workgroups whose `BRANCH_ID` is in the
  branch part; then the areas of those workgroups. Those areas are matched against a
  hidden `AREA_ID`. Every other table keeps its `TenantLocation` rule.
- **Lists that give no area mean no area limit**, as in the legacy app, where an
  empty area list is full access (confirmed 2026-10-20). Both lists empty (`"/"`), or
  ids that match no area, show the whole location: the `TenantLocation` scope.
- Under an area limit, a row whose `AREA_ID` is blank (an area held as free text) is
  hidden. A `customData` without the `/` (or none at all) and a username of another
  shape show no rows: those are backend errors, not a legacy state.

**What the backend puts in `customData`.** Read every `cmLevelAccess` row of the
admin for the active location, **ignore deleted rows**, and give the admin everything
those rows allow (confirmed 2026-10-20):

1. For each live row, take its workgroups. When the row has none, take the
   workgroups of its branches (`cmLevelWorkgroupBranch`, live links only).
2. If any live row has neither list, that row allows the whole location: send
   `TenantLocation` (or `Tenant`, per the role table) instead of `TenantArea`.
3. Otherwise send the union of the workgroups as `"/<workgroup ids>"`.

The backend resolves branches row by row because a single
`"<branches>/<workgroups>"` cannot say "branch 12 from one row, workgroup 7 from
another": with both parts filled, the role reads the workgroups only.

| Model | Area matched on |
|---|---|
| Anniversary, Birthday | the report table, with the location rule |
| Carer Hours | `DIM_CARER`, with the location rule |
| Carer Qualification | `CARER_QUALIFICATION_REPORT`, with the location rule |
| Client Hours, Continuity | `DIM_CLIENT`, with the location rule |
| Plans Taken (not built yet) | the report table, with the location rule. The area is that of the person the plan is for; a row without one is hidden under an area limit, as on the legacy page ([Plans Taken](powerbi_plans_taken_setup.md)). |
| Schedule Difference | `DIM_CLIENT`, as the legacy report does (confirmed 2026-10-20). Strict under an area limit (no blank row), so a call reaches the admin only through a client in an allowed area; with no area limit it is the `TenantLocation` rule. The fact keeps its location rule. |
| Workforce Capacity | both facts, which carry the area since 2026-10-20: the carer's for staff hours and headcount, the client's for demand and customers. `DIM_LOCATION` keeps the location rule. |
| All Carers, All Clients (not built yet) | the report table, with the location rule. A carer or client without an area is hidden under an area limit: as on the All Clients page, while the All Carers page shows such carers to every admin (that difference was decided 2026-10-27). The bridges keep the company rule and are cut through the report table ([All Carers](powerbi_all_carers_setup.md), [All Clients](powerbi_all_clients_setup.md)). |
| Plan & Assessment Dates (not built yet) | each of its three lists: the area of the person the plan is for, and the client's on assessments and wounds. A row without one is hidden under an area limit. The legacy Wound / Skin tab limits no rows by area, so that list is stricter on purpose. `DIM_LOCATION` keeps the location rule ([Plan & Assessment Dates](powerbi_plan_assessment_dates_setup.md)). |
| Task Review (not built yet) | the report table, with the location rule. The area is the client's; a row without one is hidden under an area limit. The legacy page limits no rows by area at all, so this is stricter on purpose ([Task Review](powerbi_task_review_setup.md)). The two dimensions keep the company rule. |

The role is in every model so that one token naming several datasets can carry it.

An area with no workgroup link never reaches a restricted admin, in the legacy app
or here, although carers and clients sit on such areas. On R2 PROD on 2026-10-12
that was 16,387 of CARE2's 78,137 active clients and 10,017 of its 50,128 active
carers, 197 active clients in CARE5, and a few dozen in CARE3 and BETA. How many of
them sit in a location that has restricted admins was not measured.

The dbt side (`area_id` on those marts, `mart__area_scope`) and the role in every
semantic model are built (2026-10-20). The backend change is not. The area on the
two Workforce Capacity facts changes their grain, so the first dbt deploy of it is a
`--full-refresh` of `mart__workforce_capacity`, and the Workforce Capacity model is
published after it.

Desktop cannot set `CUSTOMDATA()`, so *View as* shows `TenantArea` empty. Test it with
a real embed token, or in a scratch copy of the model where `CUSTOMDATA ()` is
replaced by a literal such as `"/7,9"`. The hybrid models (Client Hours, Carer Hours,
Schedule Difference) also need a date range old enough to be read from Snowflake,
because their dimensions are Dual and the rule then has to reach DirectQuery.

## The `Tenant` role

Every table that carries `COMPANY_ID` has a rule, and every such table also carries
`SOURCE`. The three facts without a company column (`CONTINUITY_REPORT`,
`CLIENT_HOURS_REPORT`, `CARER_HOURS_REPORT`) are cut through the dimension that the
matching `report__*` view joins for its RLS keys.

`SEARCH_INDEX` used to drop the care column at import. It now keeps `SOURCE`: the
index has no relationships, so its own rule is the only thing that cuts it, and that
rule needs the source.

| Model | Strict rule | Blank row kept |
|---|---|---|
| Anniversary | `ANNIVERSARY_REPORT` | — |
| Birthday | `BIRTHDAY_REPORT` | — |
| Carer Hours | `DIM_CARER`, `BRIDGE_JOBTYPE_GROUP`, `SEARCH_INDEX` | `DIM_JOBTYPE`, `DIM_JOBTYPE_GROUP` |
| Carer Qualification | `CARER_QUALIFICATION_REPORT`, `SEARCH_INDEX` | `DIM_HRFILE` |
| Client Hours | `DIM_CLIENT`, `BRIDGE_JOBTYPE_GROUP`, `SEARCH_INDEX` | `DIM_JOBTYPE`, `DIM_JOBTYPE_GROUP` |
| Continuity | `DIM_CLIENT`, `SEARCH_INDEX` | `DIM_CARER` |
| Plans Taken (not built yet) | `PLANS_TAKEN_REPORT` | — |
| Schedule Difference | `SCHEDULE_DIFFERENCE_REPORT`, `SEARCH_INDEX` | `DIM_CLIENT`, `DIM_CARER`, `DIM_JOBTYPE` |
| Workforce Capacity (not built yet) | `DIM_LOCATION`, `WORKFORCE_CAPACITY`, `WORKFORCE_MOVEMENT` | — |
| All Carers (not built yet) | `ALL_CARERS_REPORT`, `BRIDGE_CARER_TAG`, `BRIDGE_CARER_WORKGROUP` | — |
| All Clients (not built yet) | `ALL_CLIENTS_REPORT`, `BRIDGE_CLIENT_TAG`, `BRIDGE_CLIENT_WORKGROUP`, `BRIDGE_CLIENT_JOB_TYPE` | — |
| Plan & Assessment Dates (not built yet) | `PLANS_TAKEN_REPORT`, `ASSESSMENTS_REPORT`, `SKIN_ASSESSMENTS_REPORT`, `DIM_LOCATION` | — |
| Task Review (not built yet) | `TASK_REVIEW_REPORT`, `DIM_TASK_SCHEDULE`, `DIM_CLIENT` | — |

**Strict** keeps only rows whose `SOURCE` and `COMPANY_ID` equal the username's:

```dax
VAR TokenScope = USERNAME ()   -- not "Scope": that name is reserved in DAX
VAR IsValid = PATHLENGTH ( TokenScope ) = 2
VAR SourceId = IF ( IsValid, PATHITEM ( TokenScope, 1 ), "" )
VAR CompanyId = IF ( IsValid, IFERROR ( VALUE ( PATHITEM ( TokenScope, 2 ) ), 0 ), 0 )
RETURN
    SourceId <> "" && CompanyId > 0
        && DIM_CLIENT[SOURCE] = SourceId
        && DIM_CLIENT[COMPANY_ID] = CompanyId
```

**Blank row kept** does the same, and also lets the dimension's blank row through:

```dax
VAR TokenScope = USERNAME ()
VAR IsValid = PATHLENGTH ( TokenScope ) = 2
VAR SourceId = IF ( IsValid, PATHITEM ( TokenScope, 1 ), "" )
VAR CompanyId = IF ( IsValid, IFERROR ( VALUE ( PATHITEM ( TokenScope, 2 ) ), 0 ), 0 )
RETURN
    ISBLANK ( DIM_CARER[CARER_KEY] )
        || ( SourceId <> "" && CompanyId > 0
            && DIM_CARER[SOURCE] = SourceId
            && DIM_CARER[COMPANY_ID] = CompanyId )
```

DAX compares text case-insensitively, so `"CARE2|2"` works as well as `"care2|2"`.
A care-less `"2"` has one path item and sees nothing; `"2|35"` reads as source `"2"`,
which no row has, and sees nothing either.

A role on a dimension also filters every fact below it. Fact rows whose key has no
row in that dimension belong to its blank row: a `-1` sentinel, a deleted carer, or a
carer with no qualification. A strict rule would silently drop those rows. They are
exactly the ones these reports exist to show: contracted hours sit on job type `-1`,
and visits with no carer recorded sit on carer `-1`.

Keeping the blank row is safe **only** where every table below the dimension is
already cut to the tenant by another rule. In practice that means a fact with its own
strict rule, or a fact whose tenant boundary is a different dimension. The tenant
boundaries (`DIM_CLIENT` in Continuity and Client Hours, `DIM_CARER` in Carer Hours)
must stay strict: their facts carry no company of their own.

When you add a table:

- If it carries `COMPANY_ID`, give it a rule.
- If it is a fact without `COMPANY_ID`, make sure a strict dimension filters it.
- If it is a calculated table, it must hold no customer data. A calculated table is
  materialised at refresh with every tenant in it, and no rule filters it after that.

> Carer Hours had a wrong relationship until 2026-09-25:
> `CARER_HOURS_REPORT[CARER_KEY]` → `DIM_JOBTYPE[JOB_TYPE_KEY]`. Both keys are
> care + id, so carer 45 matched job type 45. The job-type slicer filtered carers.
> Under RLS, a carer whose id matched another company's job type would have
> disappeared. It now joins on `JOB_TYPE_KEY`.

> Client Hours' `SEARCH_INDEX` was related to `DIM_CLIENT` and `DIM_JOBTYPE_GROUP`
> until 2026-09-28. Under RLS, `DIM_CLIENT`'s strict rule reached the index and hid
> every group row, which carries no `CLIENT_KEY`. The measure's `REMOVEFILTERS` can't
> lift a security filter, so group search found nothing. The index now has no
> relationships, and `Search Hit` matches keys with `TREATAS ( DISTINCT ( … ) )`,
> the pattern Schedule Difference already used. Any report whose index covers more
> than one entity must work this way.

## The `TenantLocation` role

Same tables and the same strict / blank-row split as `Tenant`, with one difference.
The table whose `LOCATION_ID` the app filters (the table under
[The filters the app still sets](#the-filters-the-app-still-sets)) also has to match
the username's location:

```dax
VAR TokenScope = USERNAME ()
VAR IsValid = PATHLENGTH ( TokenScope ) = 3
VAR SourceId = IF ( IsValid, PATHITEM ( TokenScope, 1 ), "" )
VAR CompanyId = IF ( IsValid, IFERROR ( VALUE ( PATHITEM ( TokenScope, 2 ) ), 0 ), 0 )
VAR LocationId = IF ( IsValid, IFERROR ( VALUE ( PATHITEM ( TokenScope, 3 ) ), 0 ), 0 )
RETURN
    SourceId <> "" && CompanyId > 0 && LocationId > 0
        && DIM_CLIENT[SOURCE] = SourceId
        && DIM_CLIENT[COMPANY_ID] = CompanyId
        && DIM_CLIENT[LOCATION_ID] = LocationId
```

The company-level rules of this role parse the same three items and match `SOURCE`
and `COMPANY_ID` only.

| Model | Location enforced on |
|---|---|
| Anniversary, Birthday | the report table |
| Carer Hours | `DIM_CARER` |
| Carer Qualification | `CARER_QUALIFICATION_REPORT` |
| Client Hours, Continuity | `DIM_CLIENT` |
| Plans Taken (not built yet) | the report table |
| Schedule Difference | `SCHEDULE_DIFFERENCE_REPORT` |
| Workforce Capacity | `DIM_LOCATION` |
| All Carers, All Clients (not built yet) | the report table |
| Plan & Assessment Dates (not built yet) | `DIM_LOCATION` |
| Task Review (not built yet) | the report table |

That is exactly what "the report is scoped to the location" means in the care app: the
column the legacy report filtered on. Every other table stays company-level on
purpose. If `DIM_CARER` in Continuity were cut to the location, visits by carers from
another branch to this branch's clients would drop out of the totals. The same goes
for a Schedule Difference call at this location for a client homed elsewhere.

A username without exactly two `|` (`"care2|2"`, the old `"2|35"`, or
`"care2|2|35|36"`) sees nothing in this role.

## Deploying a semantic model

1. **Workspaces and pipeline:** one workspace per Snowflake account, promoted
   through a Fabric deployment pipeline: … → `Production_R1`
   (`analytics-embedded-prod_r1`) → `Production_R2` (`analytics-embedded-prod_r2`) →
   `Production_R3` (`analytics-embedded-prod_r3`). Each workspace sits on the F
   capacity, and the service principal is a **Member or Admin** of every one. The
   roles travel with the model on each deployment.
2. **`Server` parameter:** it already exists in every model, and every table reads
   it. Its default in the files is the DEV host. The pipeline still has to be told
   which value each stage uses. Without a rule, a deployment carries the source
   stage's value, so R2 would read R1's (or DEV's) Snowflake.

   Add a **parameter rule** in each target stage, **for each of the 7 semantic
   models** (rules are per model). The model's owner creates them, and they take
   effect from the next deployment. Snowflake is not among the data sources that
   *data source rules* support, which is why the models use a parameter.

   | Stage | `Server` |
   |---|---|
   | Production_R1 | `MYORG-PROD_R1.snowflakecomputing.com` |
   | Production_R2 | `MYORG-PROD_R2.snowflakecomputing.com` |
   | Production_R3 | `MYORG-PROD_R3.snowflakecomputing.com` |

   Use exactly the *Account/Server URL* that Snowsight shows under **Account
   Details**. Snowflake also answers on a hyphenated alias
   (`MYORG-PROD-R2...`). That alias exists for features that reject
   underscores; Snowflake's example is Okta SSO/SCIM. Switch to it only if the Power
   BI connection fails on the host name.

   Data source credentials do **not** deploy. Set them once in each workspace
   (step 3), or the first refresh after a promotion fails.
3. **Data source credentials:** use Snowflake **key-pair** authentication (GA for
   semantic models) with a dedicated read-only service user, not a person's login:

   ```sql
   -- per account; roles and users are created by hand, like the reader roles
   USE ROLE SECURITYADMIN;
   CREATE ROLE IF NOT EXISTS POWERBI_READER;
   GRANT USAGE ON WAREHOUSE WH_ANALYTICS_REPORTING_XS TO ROLE POWERBI_READER;
   GRANT USAGE ON DATABASE ANALYTICS_MART TO ROLE POWERBI_READER;
   GRANT USAGE ON SCHEMA ANALYTICS_MART.CARE_MANAGEMENT TO ROLE POWERBI_READER;
   GRANT SELECT ON ALL TABLES IN SCHEMA ANALYTICS_MART.CARE_MANAGEMENT TO ROLE POWERBI_READER;
   GRANT SELECT ON ALL VIEWS  IN SCHEMA ANALYTICS_MART.CARE_MANAGEMENT TO ROLE POWERBI_READER;
   -- Database-level FUTURE grants, NOT schema-level. A schema-level future grant
   -- makes Snowflake ignore every database-level future grant for that schema,
   -- including the ones ci/bootstrap-wif.sql gives DBT_TRANSFORMER.
   GRANT SELECT ON FUTURE TABLES IN DATABASE ANALYTICS_MART TO ROLE POWERBI_READER;
   GRANT SELECT ON FUTURE VIEWS  IN DATABASE ANALYTICS_MART TO ROLE POWERBI_READER;

   CREATE USER IF NOT EXISTS SVC_POWERBI
       TYPE = SERVICE
       DEFAULT_ROLE = POWERBI_READER
       DEFAULT_WAREHOUSE = WH_ANALYTICS_REPORTING_XS
       RSA_PUBLIC_KEY = '<public key>';
   GRANT ROLE POWERBI_READER TO USER SVC_POWERBI;
   ```

   Before relying on the future grants, run `SHOW FUTURE GRANTS IN SCHEMA
   ANALYTICS_MART.CARE_MANAGEMENT;` It must return nothing. If that schema has any
   schema-level future grant on tables, the database-level ones above are ignored for
   it. dbt rebuilds table models with `CREATE OR REPLACE`, which drops the one-off
   `GRANT ... ON ALL TABLES`. So the first dbt run after setup would silently lock
   the model out, and the next refresh would fail.

   Never refresh with `SYSADMIN` or `DBT_TRANSFORMER`. The model only needs to
   read one schema, and those roles can rewrite the whole warehouse.
4. **Refresh** after each dbt deploy to that account. A dbt change that renames or drops a
   column the models import breaks that refresh until the updated models are
   published, so ship both in the same window. The `care` -> `source` rename
   (2026-10) is one: the models now read `SOURCE`, and a model published before it
   fails on a column the mart no longer has, and the other way round.
5. **Tenant settings:**
   - *Service principals can call Fabric public APIs* (formerly *Allow service
     principals to use Power BI APIs*), limited to the service principal's
     security group.
   - *Embed content in apps*.
   - *Allow visuals created using the Power BI SDK*. The search box is the certified
     Text Filter visual, and it shows an error tile when this setting is off.
6. **Size on F2 (the starting SKU):** F2 allows **3 GB per semantic model**, and
   that cap includes refresh. A full Import refresh holds the old copy for queries
   while it builds the new one, so it needs **more than twice** the model's size. In
   practice a model has to stay under roughly **1.3 GB** to refresh on F2. Each query
   also gets 1 GB at most, and the capacity runs **one refresh at a time**.

   One model holds every customer in its account. The only sizes measured so far are
   the Desktop data caches (`cache.abf`, roughly the in-memory size). They come from
   **DEV**, which holds care1, the same care as R1 but not necessarily the same
   volume:

   | Model | DEV (care1) cache |
   |---|---|
   | Client Hours | ~0.83 GB |
   | Schedule Difference | ~0.54 GB |
   | Carer Hours | ~0.43 GB |
   | Continuity | ~0.39 GB |
   | Carer Qualification | ~0.10 GB |
   | Birthday | ~0.02 GB |
   | Anniversary | not loaded yet |

   R1 should fit if its volume is close to DEV's, with Client Hours closest to the
   edge. **R2** holds care2, care3 and care5 in each model, so check each model's
   size there before the first refresh; Client Hours and Schedule Difference are the
   likely failures. If a model does not fit:
   - trim history with incremental refresh or a date-bounded view;
   - drop the free-text columns of Schedule Difference to a drill-through;
   - or move that workspace to a larger SKU.

   Schedule the refreshes one after another after the dbt deploy, not all at once.

## Test before the first customer

In Power BI Desktop, use **Modeling → View as → Other user = `<source>|<company id>`**
(e.g. `care1|2`) and tick **Tenant**. The banner then reads *Now viewing as: Tenant,
care1|2*. If you tick the role without **Other user**, the model is empty. That is
expected: `USERNAME()` is then your own login, which has no `|`, so the rule fails
closed. Compare against the same source and company with no role:

1. **Totals match.** Each report's headline numbers equal the unfiltered model
   filtered to that source and company.
2. **Unknown and invalid tenants see nothing.** Use `care1|999999`, `care9|2`, `abc`,
   the old care-less `2`, and an empty username. Every visual, slicer and search box
   must be empty.
3. **The blank rows survived.** Check that these still show under the role:
   - Carer Hours: the Contracted column. It lives on job type `-1`.
   - Continuity: visits with no carer recorded. Visits must not drop.
   - Client Hours: the "no job type" hours.
   - Carer Qualification: carers with no qualification.
   - Client Hours: search finds both a client name and a job type group name.
     Group search does not depend on a blank row: the index has no relationships
     (see the note under [The `Tenant` role](#the-tenant-role)). If it fails, look
     at the `Search Hit` measure.

   If any of these are missing, the engine is hiding the blank row despite the rule.
   The fix is then an unknown-member row in the affected dimensions: one row per care
   for key `-1`, with a null `COMPANY_ID` that the rule lets through. Do not
   loosen the strict rules instead.
4. **Local admin:** view as `<source>|<company id>|<location id>` with
   **TenantLocation** ticked. Each report shows exactly what `Tenant` shows for the
   same source and company with that location filter set. Setting a different
   location filter shows nothing. `care1|2`, the old `2|35` and `care1|2|35|36` show
   nothing.
5. **A shared location stays in its source.** For a (company, location) pair that
   care2 and care5 share (R2), `care2|2|1` shows only care2's rows and `care5|2|1`
   only care5's. Check the `SOURCE` column on the fact or dimension, and that the
   search box offers no value from the other care.
6. **Embedded:** generate a token for company A, then set a location filter that
   belongs to company B from the browser console. Nothing must appear. Repeat with
   a local admin token and another location of the same company.
7. **No identity, no token.** A `GenerateToken` call without `identities` must fail
   for every dataset. If one succeeds, that model was published without its roles.

## Not done yet

- **One model per customer** instead of one per account. Consider it only if the
  shared model does not fit the capacity. Each customer's copy would filter
  `company_id` at the source through a parameter. Keep both roles in it: `Tenant`
  as a second line of defence, and `TenantLocation` for local admins.
