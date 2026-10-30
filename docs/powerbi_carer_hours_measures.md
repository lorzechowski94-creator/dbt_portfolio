# Carer Hours Report — Power BI setup

Star schema (import or DirectQuery):

- **Fact:** `mart__carer_hours_report` (grain: `carer_id` + `service_date` +
  `job_type_id`, all dates, additive only). One fact serves both the carer-level
  report (sum over all job types) and the job-type slicer.
- **Dim carer:** `mart__dim_carer` (grain: `carer_id`)
- **Dim job type:** `mart__dim_jobtype` (grain: `job_type_id`)
- **Dim date:** a Date table on `service_date` (mark as Date table). You can build it
  from `int__report_calendar` (`calendar_date`) or a native PBI calendar.

**ONE relation per ACCOUNT, and the names carry no care token.** Every care in the
account is stacked into the same table, with a `source` column saying which source
schema each row came from (`macros/union_cares.sql`); the names above are the real
ones in every account. The per-care `CARE1_` / `CARE2_` … relations are gone —
repoint the model at the bare names, and drop the per-tenant models that used to
exist one per care.

**`source` is part of every relationship.** Carer and job type ids are allocated per
care and collide across them, so relating on the bare id would join one care's
carer to another's — and Power BI refuses the relationship outright, because the
duplicate id breaks the "one" side.

The warehouse ships the composite key ready-made, as one integer (care and id,
`macros/source_key.sql`; Whole number / int64 in Power BI, on both sides): the fact
carries `carer_key` and `job_type_key`, `dim_carer` carries `carer_key` and
`dim_jobtype` carries `job_type_key`. Relate on those; no calculated column is
needed, and the bare ids should stay out of every relationship.

## Relationships
- `carer_hours_report[carer_key]` → `dim_carer[carer_key]` (many-to-one)
- `carer_hours_report[job_type_key]` → `dim_jobtype[job_type_key]` (many-to-one)
- `carer_hours_report[service_date]` → `DateDim[Date]` (many-to-one)

The date slicer filters `DateDim`; the job-type slicer filters `dim_jobtype`;
visuals put `dim_carer` attributes on rows. Each row shows the carer totals
**for the selected date range** (and job type, if sliced).

> **Contracted has no job type.** `cmContractsHours` carries no jobType, so
> contracted hours sit on a single `job_type_id = -1` ("no job type") row per
> carer/date. Summing over all job types gives the correct carer total, but with a
> job-type slicer active `contracted_hrs` drops out. To still show carer-level
> contracted alongside a job-type filter, use the `ALL(dim_jobtype)` variant below.

## Additive metrics — plain SUM (no special measure needed)
`scheduled_hrs`, `confirmed_payable_hrs`, `worked_hrs`, `contracted_hrs`,
`over_under_contracted_hrs`, `phone_admin_total_count`, `carer_confirmed_count`.

Round for display: e.g. `Scheduled (hrs) := ROUND(SUM(carer_hours_report[scheduled_hrs]), 2)`.

`Over/Under Contracted (hrs)` is additive too — it is `contracted_hrs -
confirmed_payable_hrs` per row, and `SUM` gives `SUM(contracted) - SUM(confirmed)`:

```DAX
Over/Under Contracted (hrs) = ROUND(SUM(carer_hours_report[over_under_contracted_hrs]), 2)
```

To keep contracted visible under a job-type slicer (ignores the -1 bucketing):

```DAX
Contracted (hrs, all job types) =
ROUND(CALCULATE(SUM(carer_hours_report[contracted_hrs]), ALL(dim_jobtype)), 2)
```

## Non-additive metrics — DAX measures (compute AFTER the date filter aggregates)

```DAX
Confirmed Phone vs Admin (%) =
VAR Total = SUM(carer_hours_report[phone_admin_total_count])
RETURN IF(Total > 0, ROUND(DIVIDE(SUM(carer_hours_report[carer_confirmed_count]), Total) * 100, 2))
```

```DAX
Scheduled (HH:MM) =
VAR Mins = SUM(carer_hours_report[scheduled_hrs]) * 60
RETURN IF(Mins >= 1, FORMAT(INT(Mins / 60), "00") & ":" & FORMAT(MOD(INT(Mins), 60), "00"))
```

```DAX
Confirmed (HH:MM) =
VAR Mins = SUM(carer_hours_report[confirmed_payable_hrs]) * 60
RETURN IF(Mins >= 1, FORMAT(INT(Mins / 60), "00") & ":" & FORMAT(MOD(INT(Mins), 60), "00"))
```

```DAX
Hrs Worked (HH:MM) =
VAR Mins = SUM(carer_hours_report[worked_hrs]) * 60
RETURN IF(Mins >= 1, FORMAT(INT(Mins / 60), "00") & ":" & FORMAT(MOD(INT(Mins), 60), "00"))
```

```DAX
Contracted (HH:MM) =
VAR Mins = SUM(carer_hours_report[contracted_hrs]) * 60
RETURN IF(Mins >= 1, FORMAT(INT(Mins / 60), "00") & ":" & FORMAT(MOD(INT(Mins), 60), "00"))
```

```DAX
Over/Under Contracted (HH:MM) =
VAR Mins = SUM(carer_hours_report[over_under_contracted_hrs]) * 60   -- can be negative
VAR AbsMins = ABS(Mins)
RETURN
IF(AbsMins >= 1,
   IF(Mins < 0, "-", "") & FORMAT(INT(AbsMins / 60), "00") & ":" & FORMAT(MOD(INT(AbsMins), 60), "00"))
```

## Why these are DAX (not fact columns)
They are non-linear — a ratio (`Phone vs Admin %`) or an HH:MM text format — so a
per-day value cannot be summed to a range total. They must be computed once, after
the date range is aggregated, which is exactly what a DAX measure does at query
time. Everything else is additive and summed by Power BI.

The original PHP computed Over/Under by subtracting two HH:MM **strings**
(`carersHoursRpt.php` §4.3, "string arithmetic (unreliable)"). Here it is stored
as a numeric difference of decimal hours, so it is additive and exact; only the
HH:MM presentation is a measure.
