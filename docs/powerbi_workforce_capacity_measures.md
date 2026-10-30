# Workforce Capacity Report — Power BI setup

For Operations Managers: staff supply (headcount, contracted and available hours)
against customer demand (headcount, contracted hours), for a selectable period, with
a comparison to the prior period and a three-month capacity outlook.

This is a new report with no PHP original. The rules behind every number are in the
model descriptions (`models/intermediate/_int__models.yml`,
`models/marts/_mart__models.yml`); this page says how to put them on the canvas.

## Tables

| Table | Grain | Role |
|---|---|---|
| `WORKFORCE_CAPACITY` | location + carer + day | Fact: every hours figure. Full history plus the outlook, up to the end of the third whole month from the build date. |
| `WORKFORCE_MOVEMENT` | location + day | Fact: headcount, joiners and leavers, history up to the build date. |
| `DIM_LOCATION` | location | Branch slicer, and the tenant boundary of both facts. |
| `DIM_DATE` | day | Shared calendar. Mark it as the Date table. |
| `Period` | selectable period | Parameter table (below). Holds no customer data. |

Import from `ANALYTICS_MART.CARE_MANAGEMENT` like the other embedded models
(`docs/powerbi_embedded_setup.md`). Every relationship is many-to-one, single
direction:

- `WORKFORCE_CAPACITY[LOCATION_KEY]` → `DIM_LOCATION[LOCATION_KEY]`
- `WORKFORCE_CAPACITY[CALENDAR_DATE]` → `DIM_DATE[CALENDAR_DATE]`
- `WORKFORCE_MOVEMENT[LOCATION_KEY]` → `DIM_LOCATION[LOCATION_KEY]`
- `WORKFORCE_MOVEMENT[CALENDAR_DATE]` → `DIM_DATE[CALENDAR_DATE]`

`CARER_KEY` relates to nothing in this report. Hide it; the unfilled-capacity measure
iterates it. The demand columns (`CUSTOMER_CONTRACTED_HRS`, `UNASSIGNED_HRS`,
`INACTIVE_CARER_HRS`) sit on one row per location, client area and day whose `CARER_KEY` is
the key of carer id -1 (`source_key(source, -1)`). That row has 0 contracted and 0 scheduled
hours, so a plain `SUM` and the per-carer iteration both come out right. A carer sits in one
area, so the area split does not change the per-carer figures either.

**No Service Line slicer.** Contracted and available hours carry no job type, so a job
type filter would cut demand and roster hours but not supply, and every ratio on the
page would be wrong. Leave it off until the source records supply per service line.

## RLS (embedded)

Same `Tenant` / `TenantLocation` / `TenantArea` roles as the other models
(`docs/powerbi_embedded_setup.md`). Every customer table here carries `COMPANY_ID`,
so each gets a strict rule, with no blank row. `DIM_LOCATION` is the table the app's
location filter targets, so `TenantLocation` enforces the location there. The facts
stay company-level, which `DIM_LOCATION` narrows anyway. `TenantArea` adds the area
rule on both facts (`AREA_ID`: the carer's for staff hours and headcount, the client's
for demand and customers), reading the hidden `AREA_SCOPE` table.

## The period

**Period** parameter table (calculated, no customer data):

```dax
Period =
DATATABLE (
    "Period", STRING, "Unit", STRING, "Length", INTEGER, "Sort", INTEGER,
    {
        { "Last 4 Weeks", "Day", 28, 1 },
        { "Last 3 Months", "Month", 3, 2 },
        { "Last 6 Months", "Month", 6, 3 },
        { "Last 12 Months", "Month", 12, 4 }
    }
)
```

Sort `Period[Period]` by `Period[Sort]`, and make the slicer single-select with "Last 6
Months" as the default. The window is **rolling and ends yesterday**, the last complete
day before the overnight build, or on the last day the import holds if the dataset has
not been refreshed since: ending on a day with no headcount row would blank the headcount
cards. The prior period is the same length, immediately before it. "hrs / week" figures
are normalised by the days in the window, so a period of any length compares like for
like.

```dax
Period End =
VAR Yesterday = TODAY () - 1
VAR LastLoaded = CALCULATE ( MAX ( WORKFORCE_MOVEMENT[CALENDAR_DATE] ), ALL ( WORKFORCE_MOVEMENT ) )
RETURN IF ( ISBLANK ( LastLoaded ), Yesterday, MIN ( Yesterday, LastLoaded ) )

Period Start =
VAR PeriodEnd = [Period End]
VAR Unit = SELECTEDVALUE ( Period[Unit], "Month" )
VAR Length = SELECTEDVALUE ( Period[Length], 6 )
RETURN IF ( Unit = "Day", PeriodEnd - Length + 1, EDATE ( PeriodEnd, - Length ) + 1 )

Prior End = [Period Start] - 1

Prior Start =
VAR PriorEnd = [Prior End]
VAR Unit = SELECTEDVALUE ( Period[Unit], "Month" )
VAR Length = SELECTEDVALUE ( Period[Length], 6 )
RETURN IF ( Unit = "Day", PriorEnd - Length + 1, EDATE ( PriorEnd, - Length ) + 1 )

Weeks = DIVIDE ( COUNTROWS ( DIM_DATE ), 7 )
```

`Weeks` counts the days of `DIM_DATE` in the current filter context. Every hrs/week
measure divides by it.

## Base measures (evaluate in whatever date context they are given)

| Measure | DAX |
|---|---|
| `Staff Contracted hrs/wk` | `DIVIDE ( SUM ( WORKFORCE_CAPACITY[CONTRACTED_HRS] ), [Weeks] )` |
| `Staff Available hrs/wk` | `DIVIDE ( COALESCE ( SUM ( WORKFORCE_CAPACITY[AVAILABLE_HRS] ), 0 ), [Weeks] )` |
| `Customer Contracted hrs/wk` | `DIVIDE ( SUM ( WORKFORCE_CAPACITY[CUSTOMER_CONTRACTED_HRS] ), [Weeks] )` |
| `Scheduled hrs/wk` | `DIVIDE ( SUM ( WORKFORCE_CAPACITY[SCHEDULED_HRS] ), [Weeks] )` |
| `Booked hrs/wk` | `DIVIDE ( SUM ( WORKFORCE_CAPACITY[SCHEDULED_HRS] ) + SUM ( WORKFORCE_CAPACITY[UNASSIGNED_HRS] ) + SUM ( WORKFORCE_CAPACITY[INACTIVE_CARER_HRS] ), [Weeks] )` |
| `Capacity Utilisation %` | `DIVIDE ( SUM ( WORKFORCE_CAPACITY[SCHEDULED_HRS] ), SUM ( WORKFORCE_CAPACITY[CONTRACTED_HRS] ) )` |
| `Staff Joined` | `SUM ( WORKFORCE_MOVEMENT[STAFF_JOINED] )` |
| `Staff Left` | `SUM ( WORKFORCE_MOVEMENT[STAFF_LEFT] )` |
| `Customers Joined` | `SUM ( WORKFORCE_MOVEMENT[CUSTOMERS_JOINED] )` |
| `Customers Left` | `SUM ( WORKFORCE_MOVEMENT[CUSTOMERS_LEFT] )` |

Available hours default to 0 where a company records none (the `COALESCE`), and
nothing else reads them. Utilisation, unfilled capacity, headroom and additional
customers are all built on **contracted** hours, as the story requires. The
wireframe's "Scheduled hours as a % of available staff hours" subtitle should read
"of contracted staff hours".

**Unfilled capacity** is clipped at zero **per carer per ISO week**. A carer idle one
week and over-booked the next still lost the idle week's hours, and one carer's
overtime does not refill another's empty contract. That is why it is a measure: no
stored column can express the clip for an arbitrary period.

```dax
Unfilled hrs/wk =
VAR Lost =
    SUMX (
        SUMMARIZE ( WORKFORCE_CAPACITY, WORKFORCE_CAPACITY[CARER_KEY], DIM_DATE[ISO_YEAR_WEEK] ),
        MAX (
            0,
            CALCULATE ( SUM ( WORKFORCE_CAPACITY[CONTRACTED_HRS] ) - SUM ( WORKFORCE_CAPACITY[SCHEDULED_HRS] ) )
        )
    )
RETURN DIVIDE ( Lost, [Weeks] )
```

It visits one row per carer per week in the window, about 130k for a location of
5,000 carers over six months. Weeks cut by the window edge clip on their in-window
days.

**Headcount is a balance, not a sum.** `ACTIVE_STAFF` / `ACTIVE_CUSTOMERS` are the
count at the end of each day. They add up across locations, but over dates a period
shows its last day:

```dax
Active Staff =
VAR LastDay = MIN ( MAX ( DIM_DATE[CALENDAR_DATE] ), TODAY () - 1 )
RETURN CALCULATE ( SUM ( WORKFORCE_MOVEMENT[ACTIVE_STAFF] ), DIM_DATE[CALENDAR_DATE] = LastDay )

Active Customers =
VAR LastDay = MIN ( MAX ( DIM_DATE[CALENDAR_DATE] ), TODAY () - 1 )
RETURN CALCULATE ( SUM ( WORKFORCE_MOVEMENT[ACTIVE_CUSTOMERS] ), DIM_DATE[CALENDAR_DATE] = LastDay )
```

The cap at yesterday keeps the current, unfinished month of a trend chart on its last
loaded day instead of a blank month end. Movement reconciles with headcount:
`Active(end) − Active(day before start) = Joined − Left` for any window.

## Cards: current, prior, delta

Every card uses the same three-step template around one base measure. `X` below is
any row of the table above, or `Active Staff` / `Active Customers` / `Unfilled
hrs/wk`:

```dax
X (period) =
CALCULATE ( [X], DATESBETWEEN ( DIM_DATE[CALENDAR_DATE], [Period Start], [Period End] ) )

X (prior) =
CALCULATE ( [X], DATESBETWEEN ( DIM_DATE[CALENDAR_DATE], [Prior Start], [Prior End] ) )

X Δ = [X (period)] - [X (prior)]
X Δ % = DIVIDE ( [X Δ], [X (prior)] )
```

The wireframe shows `Δ %` on the hours and headcount cards and `Δ` on the joiner and
leaver counts. For `Staff Left`, `Customers Left` and `Unfilled hrs/wk`, an increase
is bad: invert the colour rule on those cards.

The four hours cards show more than that. Each is one SVG measure, `X Card`. It shows:
- `X (period)`;
- `X Δ %` as a coloured pill;
- a share as a progress bar, with its numerator and denominator under it;
- the prior period, `X Δ`, and the value per active carer or customer.

Values under 100 hrs/wk get one decimal. The report shows each card through `X Flip Card`, HTML for the HTML Content visual. Its front is the SVG; on hover or keyboard focus the card turns over to how its numbers are calculated, with the selected and prior dates. The shares are:

| Card | Share |
|---|---|
| Staff contracted | `Capacity Utilisation %`: scheduled ÷ contracted |
| Staff available | contracted ÷ available |
| Customer contracted | staff contracted ÷ customer contracted, i.e. demand covered by staff contracts |
| Unfilled | unfilled ÷ staff contracted |

## Trend charts (capacity vs demand, headcount, joiners vs leavers)

Axis `DIM_DATE[START_OF_MONTH]` on a continuous (date) axis. Each series is the base
measure over the whole import up to the end of the selected period, so the last month
only counts its days up to `Period End`:

```dax
X (trend) =
CALCULATE (
    [X],
    KEEPFILTERS ( DATESBETWEEN ( DIM_DATE[CALENDAR_DATE], BLANK (), [Period End] ) )
)
```

Two dashed x-axis reference lines, at `[Prior Start]` ("Prior period") and `[Period
Start]` ("Selected period"), mark where the two periods start. Each tints the chart to
its right, so the selected period is the darkest. Reference lines need a continuous
axis, which is why the axis is the first day of the month, not its label. Months after
`Period End` are blank and drop off the axis. Capacity vs Demand plots `Staff Available hrs/wk`, `Staff
Contracted hrs/wk` and `Customer Contracted hrs/wk`. `Active Staff` and `Active
Customers` get a chart each: customers run at about twice the staff count, so on one
axis a 2% change reads as a flat line. Next to each, a movement chart per entity draws
joiners above the axis, leavers below it (`Staff Left (trend, below axis)` = the negated
trend, formatted without a sign) and the net change as a line on the same axis (`Staff Net
Change (trend)`; the same for customers). A period without any movement draws no columns at
all, so the subtitle (`Staff Movement Subtitle`, `Customers Movement Subtitle`) then says so
with the date of the last change.

## Upcoming 3-month outlook

The three whole calendar months after the current one. The fact holds them because
the build expands roster rules, contracts and assigned hours to the end of the third
month (`macros/projection_horizon.sql`). It is a direct projection of the rules as
they stand at build time, not a forecast. Past the rules' own end dates there is
nothing to project, so a rule ending mid-window simply stops.

```dax
Outlook Start = EOMONTH ( TODAY (), 0 ) + 1
Outlook End = MIN ( EOMONTH ( TODAY (), 3 ), CALCULATE ( MAX ( WORKFORCE_CAPACITY[CALENDAR_DATE] ), ALL ( WORKFORCE_CAPACITY ) ) )

Projected Available hrs/wk =
CALCULATE ( [Staff Contracted hrs/wk], DATESBETWEEN ( DIM_DATE[CALENDAR_DATE], [Outlook Start], [Outlook End] ) )

Projected Scheduled hrs/wk =
CALCULATE ( [Booked hrs/wk], DATESBETWEEN ( DIM_DATE[CALENDAR_DATE], [Outlook Start], [Outlook End] ) )

Projected Headroom hrs/wk = [Projected Available hrs/wk] - [Projected Scheduled hrs/wk]

Avg Contracted hrs per Customer = DIVIDE ( [Customer Contracted hrs/wk (period)], [Active Customers (period)] )

Estimated Additional Customers =
VAR Headroom = [Projected Headroom hrs/wk]
RETURN IF ( Headroom > 0, INT ( DIVIDE ( Headroom, [Avg Contracted hrs per Customer] ) ), 0 )
```

- **Projected available = contracted hours**, per the story: the supply baseline is
  contracts, not availability. Contracts of carers who have left stop on their leave
  date, so they do not inflate it.
- **Projected scheduled = every booked visit**: hours booked to an active carer, plus
  unassigned hours, plus hours still booked to a carer who is no longer active. The
  last two still need a carer, so they eat into headroom. Utilisation, on the other
  hand, counts only the first: it measures how busy the workforce is.
- `Outlook End` is capped at the fact's last date. A dataset refreshed on the 1st
  from a build of the 30th would otherwise ask for a month the build did not
  expand.
- The average per customer comes from the selected period's actuals. The headroom
  is converted at today's mix, not at a projected one.

**Available vs Scheduled — next 3 months** chart: axis `MONTH_YEAR_LABEL`,
series `[Staff Contracted hrs/wk]` and `[Booked hrs/wk]`, each wrapped in
`KEEPFILTERS ( DATESBETWEEN ( …, [Outlook Start], [Outlook End] ) )` exactly like
the trend series.

An optional text measure for the Insight panel:

```dax
Outlook Insight =
VAR Headroom = [Projected Headroom hrs/wk]
RETURN
    IF (
        Headroom >= 0,
        "Based on current rosters and bookings, capacity is projected to run ~"
            & FORMAT ( Headroom, "#,0" ) & " hrs/week ahead of demand over the next 3 months — room for about "
            & FORMAT ( [Estimated Additional Customers], "#,0" ) & " more customers at "
            & FORMAT ( [Avg Contracted hrs per Customer], "0.0" ) & " contracted hrs each, without additional hiring.",
        "Based on current rosters and bookings, demand is projected to exceed contracted capacity by ~"
            & FORMAT ( - Headroom, "#,0" ) & " hrs/week over the next 3 months."
    )
```

## What the numbers mean — the rules in one place

- **Joined / left.** A person is active from their start date until the app moved them
  out of Active: Archived, or Pending (on hold). That date is `carer.deleted` /
  `client.deleted`. A reactivated person reads as never having left, because the
  app clears the stamp and the history cannot be rebuilt from the current state.
  Deleted records (state 4) are left out.
- **Start date.** Carer: `startDate`. Client: `inductionDate`, else `admissionDate`.
  In both cases the created date is used when the field is missing or implausible.
- **Location.** The carer's or client's current location. A move takes the history
  with it, as in every other report.
- **Contracted hours** use the contract history. The Carer Hours report uses only
  today's contract, so the two differ for dates before a contract change.
- **Scheduled hours** equal Carer Hours' Scheduled for an active carer: 99.6% of it
  on DEV for March 2025. The rest are visits to clients outside their service spell.
- **Utilisation above 100% means missing contracts, not overwork.** Many carers have
  no contract recorded (zero-hour or bank staff): on DEV only 5,653 of 24,348 Active
  carers have a current one. Their roster hours count as scheduled but add nothing
  to contracted, so account-wide utilisation on DEV is 222%. A location that keeps
  contracts current reads sensibly: care1 location 144 shows 81%. The same gap makes headroom
  negative wherever bank staff carry the load. That is correct against *contracted*
  capacity, which is what the story asks for, but it is worth saying on the page.

## Testing on DEV

DEV is a stale copy: timesheets stop in July 2026, and carer, client and
availability records stop in 2025. Movement runs at about 1,000 staff and 2,000
customer joiners and leavers a month until January 2025 and stops in February 2025 (last
carer joiner 27 Jun 2025, last leaver 9 Jul 2025, last customer joiner 18 Oct 2025).
Every period option ends yesterday, and the longest starts a year back, so on DEV the
movement cards read 0, the headcount charts are flat and the joiners chart is empty.
To see them with movement, build a test copy that ends the period on a fixed date:
`build_workforce_capacity.py --as-of 2025-01-31` (in the Power BI tooling repo;
never for the report that ships). Availability is sparse. Contracts and roster rules are
open-ended (a rule with no end date carries the app's 2030-02-02 sentinel), so
contracted, scheduled and outlook hours do fill in.
