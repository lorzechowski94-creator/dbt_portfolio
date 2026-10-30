# HR Compliance Report (Carer Qualifications) — Power BI setup

One fact serves both carer-qualification reports: the flat **Carer Qualification
Export** and the **HR compliance dashboard** (KPI tiles + drill-downs). No new
model was added for the dashboard — the compliance columns sit on the export's own
rows, so every tile and its drill-down table read the same grain and cannot
disagree.

Star schema (import or DirectQuery):

- **Fact:** `report__carer_qualification_report` (grain: `carer_id` +
  qualification record). One row per HR file; a carer with no files still appears
  once, with `qualification_record_id` blank and `qualification_type_id` = -1.
- **Dim HR file:** `report__dim_hrfile` (grain: `qualification_type_id`) — file
  name, category label, alert window.
- **Dim date (optional):** `report__dim_date` on `calendar_date`, related to the
  fact's `expired`, only if you want an expiry-date slicer. None of the measures
  below need it.

`report__dim_carer` is **not** used here. It filters `deleted is null` while this
fact keeps deleted carers, so slicing position/area through it would push those
rows into Power BI's blank member. `position` and `area` are already denormalised
on the fact — slice them there.

**ONE relation per ACCOUNT, and the names carry no care token.** Every care in the
account is stacked into the same table, with a `source` column saying which source
schema each row came from (`macros/union_cares.sql`); the names above are the real
ones in every account. The per-care `CARE1_` / `CARE2_` … relations are gone —
repoint the model at the bare names.

**`source` is part of every relationship**, because qualification type and carer ids
are allocated per care and collide across them — relating on a bare id would join
one care's row to another's, and Power BI refuses the relationship outright because
the duplicate id breaks the "one" side.

The warehouse ships the composite key ready-made, as one integer (care and id,
`macros/source_key.sql`; Whole number / int64 in Power BI, on both sides): the fact
carries `hr_file_key` and `carer_key`, `dim_hrfile` carries `hr_file_key` and
`dim_carer` carries `carer_key`. Relate on those; no calculated column is needed,
and the bare ids should stay out of every relationship.

## Relationships
- `carer_qualification_report[hr_file_key]` → `dim_hrfile[hr_file_key]` (many-to-one)
- `carer_qualification_report[carer_key]` → `dim_carer[carer_key]` (many-to-one, optional — this export denormalises the carer columns it displays)
- `carer_qualification_report[expired]` → `DateDim[calendar_date]` (many-to-one, optional)

Slice on `dim_hrfile[hr_file_name]`, **not** the id: `cmQualificationsType` is per
tenant, so one name exists once per company/location and a name slicer selects
every id behind it. Do not filter `dim_hrfile` on `is_deleted` — that propagates
to the fact and drops the history of retired file types.

## Report-level filter — the dashboard's scope

Two filters, both set once at report level:

| Filter | Value | Why |
|---|---|---|
| `state_id` | `is 1 or 2` | Active / pending carers only. Archived and other states are out of scope for compliance. |
| `qualification_record_id` | `is not blank` | Drops the "carer holds no files" row, which is not an HR file. |

The mart deliberately does **not** apply these: the export needs every carer,
deleted ones included. Keep them on the report.

## The definition of expired

`expireDate <= today` — a file expiring **today** is already expired. It is settled
in SQL, in `expire_status`, so no DAX should re-test a date against `TODAY()` and
risk a different boundary.

`expire_status` is one column serving both reports — the flat export searches it as
a keyword, this dashboard splits by it. Mutually exclusive and exhaustive, every
file is exactly one of:

| Value | Meaning |
|---|---|
| `valid` | Expires after today, **or** has an award date and no expiry |
| `not_actioned` | Neither award date nor expiry date filled |
| `expired` | Expiry date today or earlier |

> **`is_expiring` is an overlay, not a fourth state.** An expiring file is a
> `valid` file inside its type's alert window. `alertBefore` is a calendar interval
> typed in the app (`4 week`, `1 month`), so the window runs from the expiry date
> minus that interval to the day before expiry; the expiry date itself counts as
> expired. Adding Valid + Not Actioned +
> Expired + Expiring counts those rows twice — that total is the File Types
> table's five columns, not a sum. Files whose type configures no
> `alertBefore` never flag.

## Headline KPI tiles

```DAX
Total HR Files = DISTINCTCOUNT(carer_qualification_report[qualification_record_id])
```

Count files on the record id, never `COUNTROWS` — the no-file rows would inflate it
(the report-level filter above removes them, but the measure should stand on its
own).

```DAX
Non-Compliant Staff (Expired) =
CALCULATE(
    DISTINCTCOUNT(carer_qualification_report[carer_id]),
    carer_qualification_report[expire_status] = "expired"
)
```

```DAX
Expiring Staff (Alert Window) =
CALCULATE(
    DISTINCTCOUNT(carer_qualification_report[carer_id]),
    carer_qualification_report[is_expiring] = TRUE()
)
```

Staff, not files — a carer with three expired files counts once in each. The alert
window is per file type and is already resolved on the row; `dim_hrfile[alert_before]`
is there for display, not to re-derive the flag.

```DAX
Renewed (Last 30 Days) =
CALCULATE(
    DISTINCTCOUNT(carer_qualification_report[qualification_record_id]),
    carer_qualification_report[is_renewal] = TRUE(),
    carer_qualification_report[awarded] >= TODAY() - 30
)
```

Rolling 30 days, which is what the tile spec asked for. Calendar-month variant if
that is ever preferred:

```DAX
Renewed (Last Calendar Month) =
VAR MonthStart = EOMONTH(TODAY(), -2) + 1
VAR MonthEnd = EOMONTH(TODAY(), -1)
RETURN
CALCULATE(
    DISTINCTCOUNT(carer_qualification_report[qualification_record_id]),
    carer_qualification_report[is_renewal] = TRUE(),
    carer_qualification_report[awarded] >= MonthStart,
    carer_qualification_report[awarded] <= MonthEnd
)
```

## File Types table (`dim_hrfile[hr_file_name]` on rows)

Five file-count measures. `Expiring` is a subset of `Valid`; the other three add
up to the type's total.

```DAX
Valid Files =
CALCULATE([Total HR Files], carer_qualification_report[expire_status] = "valid")
```

```DAX
Not Actioned Files =
CALCULATE([Total HR Files], carer_qualification_report[expire_status] = "not_actioned")
```

```DAX
Expired Files =
CALCULATE([Total HR Files], carer_qualification_report[expire_status] = "expired")
```

```DAX
Expiring Files =
CALCULATE([Total HR Files], carer_qualification_report[is_expiring] = TRUE())
```

```DAX
Renewed Files (Last 30 Days) = [Renewed (Last 30 Days)]
```

Put `dim_hrfile[hr_file_type]` in the Category column of that table — the label is
defined once, in the dimension.

## HR File Categories — the seven tiles

Same measures, `dim_hrfile[hr_file_type]` on rows. It has exactly seven values
(Additional / Registrational / Company / Legal / Training / Private / Confidential
Requirement), so a card visual per category or one small multiple works; the
stacked bar under each number is `Valid Files`, `Not Actioned Files`,
`Expired Files` — which is why those three are exhaustive and `Expiring Files`
stays out of that bar.

## Breakdown by Area & Position

- **Total Files by Area** (pie): `carer_qualification_report[area]` with
  `[Total HR Files]`.
- **Non-Compliant Staff by Position** (bar): `carer_qualification_report[position]`
  with `[Non-Compliant Staff (Expired)]`.

Both come off the fact, so clicking a slice or bar cross-filters every other
visual on the page with no extra relationships.

## Drill-down tables

Both tables are at record grain, so the fact's columns can be used directly:
`first_name` / `surname`, `position`, `area`, `start_date`, `state`,
`dim_hrfile[hr_file_type]` (Category), `qualification_name` (File), `expired`
(Expiry Date).

Filter the expired table on `expire_status = "expired"` and the expiring one
on `is_expiring = TRUE()` (visual-level filters), then:

```DAX
Days Overdue = -MIN(carer_qualification_report[days_to_expiry])
```

```DAX
Days Remaining = MIN(carer_qualification_report[days_to_expiry])
```

`MIN` only because a measure needs an aggregate — at record grain there is one
value per row. Use the measures rather than the raw column so the sign reads
right in each table. A file expiring today shows as **0 days overdue** in the
expired table and does not appear in the expiring one, which is the `<=` boundary
being consistent.

> **`days_to_expiry` is as-of the build date, not query time.** It is a SQL column
> computed with `current_date()`, the same way `expire_status` always has been, and
> it is correct only while the daily refresh runs. If the model ever refreshes less
> often than daily, swap the two measures for
> `DATEDIFF(TODAY(), MIN(carer_qualification_report[expired]), DAY)` — and then the
> status columns are stale too, so recompute them the same way rather than mixing
> build-date and query-date logic in one visual.

## Why these are DAX (not fact columns)

Every tile is a count or a distinct count over the same rows, and each one is
counted under a different filter (by area, by position, by type, by category).
That is exactly what a measure does at query time; storing them would mean one
pre-aggregated table per breakdown, and the drill-down tables need the row-level
detail anyway.

What is NOT in DAX, deliberately: the expired boundary, the alert window and the
renewal flag. All three are row-level facts about a file, they are shared by the
tiles and the drill-downs, and the alert window needs a join to the file type —
so they are resolved once in `int__carer_qualifications` and travel on the row.
