# Cross-column search — per-report setup

Paste-ready Power Query and DAX for wiring `SEARCH_INDEX` into each report. The
design and the reasons behind every choice live in
[powerbi_client_hours_measures.md](powerbi_client_hours_measures.md#cross-column-search);
this file is only the code.

## What every report does the same way

1. Add the query below — they differ only in the filter and the columns dropped.
   None of them drops `SOURCE`: the roles filter the index on it, together with
   `COMPANY_ID` ([powerbi_embedded_setup.md](powerbi_embedded_setup.md)).
2. Connect the index as listed for that report. A report that searches **one**
   entity gets one relationship: **1:\*, Single, entity on the "one" side**. A report
   that searches **several** gets **none**, and its measure matches each key with
   `TREATAS`. Through a relationship, the dimension's RLS rule would hide every
   other entity's rows
   ([why](powerbi_client_hours_measures.md#cross-column-search)).
3. Hide every column of `SEARCH_INDEX`.
4. Put Microsoft's certified **Text Filter** on `SEARCH_INDEX[VALUE_TEXT]`,
   operator **Contains**. Build the slicer before hiding the columns.
5. Add the `Search Hit` measure and set the table visual's filter to
   `Search Hit is 1`.

The measure references the table, so the query has to exist first.

### Two things to confirm per model before debugging anything

**The field parameter's `NAMEOF` column is named differently in each file.** The
names below were read out of the model definitions and are correct as of this
writing, but a parameter rebuilt through the wizard gets new ones. A wrong name
either refuses to save or yields an empty `SearchableRefs`, which looks exactly
like "search does nothing".

**Columns pinned into the visual outside the parameter** have to be listed in
`FixedRefs`. Entries marked *confirm* are inferred — check the visual's Columns
well. A missing entry means that column is visible but unsearchable, and it is
usually the column people type into first.

### Query folding

After pasting, right-click the **last** step → **View Native Query**. It should
show a `where` with `like`. Greyed out means the filter runs locally and the whole
table crosses the network; it can be rewritten as `Value.NativeQuery` if so.

### `invalid identifier` after the index changes shape

`Table.RemoveColumns` names what to drop and takes everything else from the
editor's cached copy of the source schema. When a column disappears from the mart,
that cache can still list it, the folded `SELECT` asks for it, and Snowflake
answers `invalid identifier`. Clearing it — Options → Global → Data Load → Clear
Cache, then Refresh Preview — is the direct fix; deleting and re-adding the query
also works.

Swapping to `Table.SelectColumns` with the list of columns to KEEP sidesteps it
entirely: the projection is then driven by the names you wrote, so a column the
cache still believes in cannot reach the query. The trade is maintenance — a new
key column has to be added by hand, and until it is, that entity's search fails
silently. Worth preferring while the index is still changing shape.

---

## Client Hours

Relationships: **none**. The measure matches `CLIENT_KEY` and `GROUP_KEY` with
`TREATAS`.

```m
let
    Source = Snowflake.Databases(Server,"WH_ANALYTICS_REPORTING_XS",[Implementation="2.0"]),
    ANALYTICS_MART_Database = Source{[Name="ANALYTICS_MART",Kind="Database"]}[Data],
    CARE_MANAGEMENT_Schema = ANALYTICS_MART_Database{[Name="CARE_MANAGEMENT",Kind="Schema"]}[Data],
    SEARCH_INDEX_Table = CARE_MANAGEMENT_Schema{[Name="SEARCH_INDEX",Kind="Table"]}[Data],
    Scoped = Table.SelectRows(SEARCH_INDEX_Table, each
        Text.StartsWith([COLUMN_REF], "DIM_CLIENT[")
        or Text.StartsWith([COLUMN_REF], "DIM_JOBTYPE_GROUP[")),
    Trimmed = Table.RemoveColumns(Scoped,
        {"CARER_KEY", "JOB_TYPE_KEY", "QUALIFICATION_KEY", "OCCURRENCE_KEY"})
in
    Trimmed
```

No `FixedRefs` — both columns of the table visual come from parameters.

```DAX
Search Hit =
VAR VisibleRefs =
    UNION (
        SELECTCOLUMNS (
            ALLSELECTED ( 'Report Grouping'[Parameter Fields] ),
            "@ref", SUBSTITUTE ( UPPER ( 'Report Grouping'[Parameter Fields] ), "'", "" )
        ),
        SELECTCOLUMNS (
            ALLSELECTED ( 'Column Visibility'[Value2] ),
            "@ref", SUBSTITUTE ( UPPER ( 'Column Visibility'[Value2] ), "'", "" )
        )
    )
VAR SearchableRefs =
    INTERSECT ( ALL ( SEARCH_INDEX[COLUMN_REF] ), VisibleRefs )
VAR Searching = ISFILTERED ( SEARCH_INDEX[VALUE_TEXT] )
VAR Scoped = TREATAS ( SearchableRefs, SEARCH_INDEX[COLUMN_REF] )
VAR ClientHits =
    CALCULATE ( COUNTROWS ( SEARCH_INDEX ), Scoped,
        TREATAS ( DISTINCT ( DIM_CLIENT[CLIENT_KEY] ), SEARCH_INDEX[CLIENT_KEY] ) )
VAR GroupHits =
    CALCULATE ( COUNTROWS ( SEARCH_INDEX ), Scoped,
        TREATAS ( DISTINCT ( DIM_JOBTYPE_GROUP[GROUP_KEY] ), SEARCH_INDEX[GROUP_KEY] ) )
RETURN
    IF (
        NOT Searching || ISEMPTY ( SearchableRefs ),
        1,
        IF ( ClientHits > 0 || GroupHits > 0, 1, 0 )
    )
```

Two keys, so two branches. A single `COUNTROWS` would demand both keys on one row
and no row carries two, so the result would always be zero and the table would
blank. `DISTINCT`, not `VALUES`: the dimension's blank row would match every row
of the other entity.

`GroupHits` is structurally zero on the Client Hours view. `Value4` narrows the
parameter to that view, so only client refs reach `Scoped`, and client rows carry no
`GROUP_KEY`. The group name becomes searchable only on the Jobtype view, which shows
it.

---

## Carer Hours

Relationships: `DIM_CARER[CARER_KEY]`

```m
    Scoped = Table.SelectRows(SEARCH_INDEX_Table, each
        Text.StartsWith([COLUMN_REF], "DIM_CARER[")),
    Trimmed = Table.RemoveColumns(Scoped,
        {"CLIENT_KEY", "JOB_TYPE_KEY", "GROUP_KEY",
         "QUALIFICATION_KEY", "OCCURRENCE_KEY"})
```

```DAX
Search Hit =
VAR FixedRefs =                                  -- confirm against the Columns well
    { "DIM_CARER[CARER_NO]", "DIM_CARER[FIRST_NAME]", "DIM_CARER[SURNAME]" }
VAR VisibleRefs =
    UNION (
        SELECTCOLUMNS (
            ALLSELECTED ( 'Column Visibility'[Value2] ),
            "@ref", SUBSTITUTE ( UPPER ( 'Column Visibility'[Value2] ), "'", "" )
        ),
        FixedRefs
    )
VAR SearchableRefs =
    INTERSECT ( ALL ( SEARCH_INDEX[COLUMN_REF] ), VisibleRefs )
VAR Searching = ISFILTERED ( SEARCH_INDEX[VALUE_TEXT] )
VAR Hits =
    CALCULATE (
        COUNTROWS ( SEARCH_INDEX ),
        TREATAS ( SearchableRefs, SEARCH_INDEX[COLUMN_REF] )
    )
RETURN
    IF ( NOT Searching || ISEMPTY ( SearchableRefs ), 1, IF ( Hits > 0, 1, 0 ) )
```

One relationship, so no split. If you also relate `DIM_JOBTYPE_GROUP`, add its
prefix to the query, keep `GROUP_KEY`, and split the measure as Client Hours does.

---

## Continuity

Relationships: `DIM_CLIENT[CLIENT_KEY]`

No field parameter at all, so the visible set is fixed and the query filters to an
exact list — 4 of the 26 client attributes.

```m
    Scoped = Table.SelectRows(SEARCH_INDEX_Table, each List.Contains(
        { "DIM_CLIENT[AREA_NAME]", "DIM_CLIENT[FULL_NAME]",
          "DIM_CLIENT[CLIENT_NO]", "DIM_CLIENT[BRANCH]" },
        [COLUMN_REF])),
    Trimmed = Table.RemoveColumns(Scoped,
        {"CARER_KEY", "JOB_TYPE_KEY", "GROUP_KEY",
         "QUALIFICATION_KEY", "OCCURRENCE_KEY"})
```

```DAX
Search Hit =
VAR VisibleRefs =
    {
        "DIM_CLIENT[AREA_NAME]",
        "DIM_CLIENT[FULL_NAME]",
        "DIM_CLIENT[CLIENT_NO]",
        "DIM_CLIENT[BRANCH]"
    }
VAR SearchableRefs =
    INTERSECT ( ALL ( SEARCH_INDEX[COLUMN_REF] ), VisibleRefs )
VAR Searching = ISFILTERED ( SEARCH_INDEX[VALUE_TEXT] )
VAR Hits =
    CALCULATE (
        COUNTROWS ( SEARCH_INDEX ),
        TREATAS ( SearchableRefs, SEARCH_INDEX[COLUMN_REF] )
    )
RETURN
    IF ( NOT Searching || ISEMPTY ( SearchableRefs ), 1, IF ( Hits > 0, 1, 0 ) )
```

The refs are spelled as the index stores them — physical Snowflake names. In this
model the column is renamed to `DIM_CLIENT[Area]`, which does not matter because
the list is written by hand rather than read from a parameter.

The visual is a **matrix**, and the filter is evaluated per hierarchy level: an
Area row survives if any client under it matches, and expanding shows only the
matching clients. Expect more evaluations than a flat table — four levels, four
passes.

If this report ever gains a field parameter, replace the literal list with the
`ALLSELECTED` union and nothing else changes.

---

## Carer Qualification

Relationships: `CARER_QUALIFICATION_REPORT[QUALIFICATION_KEY]` — one, and only one.

The fact is the "one" side, which is deliberate: this export searches columns that
sit on the fact, not on a dimension.

`HR File` and `HR File Type` are keyed on the fact too, even though their values
come from `dim_hrfile`. A second relationship from the index to that dimension
would close a loop — the fact is already related to `dim_hrfile` for the HR File
slicer — and Power BI refuses it as an ambiguous path. `USERELATIONSHIP` is no
escape either: it cannot activate a relationship that would be ambiguous against
the active ones. Their `column_ref` still reads `DIM_HRFILE[...]`, because that is
what the field parameter names; only the key differs.

```m
    Scoped = Table.SelectRows(SEARCH_INDEX_Table, each
        Text.StartsWith([COLUMN_REF], "CARER_QUALIFICATION_REPORT[")
        or Text.StartsWith([COLUMN_REF], "DIM_HRFILE[")),
    Trimmed = Table.RemoveColumns(Scoped,
        {"CLIENT_KEY", "CARER_KEY", "JOB_TYPE_KEY", "GROUP_KEY",
         "OCCURRENCE_KEY"})
```

```DAX
Search Hit =
VAR FixedRefs =                                  -- confirm against the Columns well
    {
        "CARER_QUALIFICATION_REPORT[CARER_NO]",
        "CARER_QUALIFICATION_REPORT[FIRST_NAME]",
        "CARER_QUALIFICATION_REPORT[SURNAME]"
    }
VAR VisibleRefs =
    UNION (
        SELECTCOLUMNS (
            ALLSELECTED ( 'Column Visibility'[Value2] ),
            "@ref", SUBSTITUTE ( UPPER ( 'Column Visibility'[Value2] ), "'", "" )
        ),
        FixedRefs
    )
VAR SearchableRefs =
    INTERSECT ( ALL ( SEARCH_INDEX[COLUMN_REF] ), VisibleRefs )
VAR Searching = ISFILTERED ( SEARCH_INDEX[VALUE_TEXT] )
VAR Hits =
    CALCULATE (
        COUNTROWS ( SEARCH_INDEX ),
        TREATAS ( SearchableRefs, SEARCH_INDEX[COLUMN_REF] )
    )
RETURN
    IF ( NOT Searching || ISEMPTY ( SearchableRefs ), 1, IF ( Hits > 0, 1, 0 ) )
```

Only 10 of the report's 22 columns are indexed. Dates, comments, `file_uploaded`
and `expire_status` were left out — each costs ~1.7M index rows and each already
has its own slicer. Both pages have a search box. `Search Hit is 1` sits on the
*Carer qualifications* table and, on *Staff compliance*, on the three tables and
the two charts. The cards carry no filter
([why](powerbi_client_hours_measures.md#model)). *Staff compliance* has no
column-visibility slicer, so there every indexed column is searched.

---

## Schedule Difference

Relationships: **none**. The measure matches the fact's `CLIENT_KEY`,
`CARER_KEY`, `JOB_TYPE_KEY` and `OCCURRENCE_KEY` with `TREATAS`, as the model does.

```m
    Scoped = Table.SelectRows(SEARCH_INDEX_Table, each
        Text.StartsWith([COLUMN_REF], "DIM_CLIENT[")
        or Text.StartsWith([COLUMN_REF], "DIM_CARER[")
        or Text.StartsWith([COLUMN_REF], "DIM_JOBTYPE[")
        or Text.StartsWith([COLUMN_REF], "SCHEDULE_DIFFERENCE_REPORT[")),
    Trimmed = Table.RemoveColumns(Scoped,
        {"GROUP_KEY", "QUALIFICATION_KEY"})
```

`"DIM_JOBTYPE["` does not match `DIM_JOBTYPE_GROUP[` — the group has an underscore
where the bracket would be. Convenient here, easy to forget when you want the
opposite.

```DAX
Search Hit =
VAR FixedRefs =
    {
        "DIM_CLIENT[CLIENT_NO]",
        "DIM_CARER[FULL_NAME]",
        "DIM_JOBTYPE[JOB_TYPE_NAME]"
    }
VAR VisibleRefs =
    UNION (
        SELECTCOLUMNS (
            ALLSELECTED ( 'Column Visibility'[Parameter Fields] ),
            "@ref", SUBSTITUTE ( UPPER ( 'Column Visibility'[Parameter Fields] ), "'", "" )
        ),
        FixedRefs
    )
VAR SearchableRefs =
    INTERSECT ( ALL ( SEARCH_INDEX[COLUMN_REF] ), VisibleRefs )
VAR Searching = ISFILTERED ( SEARCH_INDEX[VALUE_TEXT] )
VAR Scoped = TREATAS ( SearchableRefs, SEARCH_INDEX[COLUMN_REF] )
VAR ClientKeys  = VALUES ( SCHEDULE_DIFFERENCE_REPORT[CLIENT_KEY] )
VAR CarerKeys   = VALUES ( SCHEDULE_DIFFERENCE_REPORT[CARER_KEY] )
VAR JobTypeKeys = VALUES ( SCHEDULE_DIFFERENCE_REPORT[JOB_TYPE_KEY] )
VAR CallKeys    = VALUES ( SCHEDULE_DIFFERENCE_REPORT[OCCURRENCE_KEY] )
VAR ClientHits =
    CALCULATE ( COUNTROWS ( SEARCH_INDEX ), Scoped,
        TREATAS ( ClientKeys, SEARCH_INDEX[CLIENT_KEY] ) )
VAR CarerHits =
    CALCULATE ( COUNTROWS ( SEARCH_INDEX ), Scoped,
        TREATAS ( CarerKeys, SEARCH_INDEX[CARER_KEY] ) )
VAR JobTypeHits =
    CALCULATE ( COUNTROWS ( SEARCH_INDEX ), Scoped,
        TREATAS ( JobTypeKeys, SEARCH_INDEX[JOB_TYPE_KEY] ) )
VAR CallHits =
    CALCULATE ( COUNTROWS ( SEARCH_INDEX ), Scoped,
        TREATAS ( CallKeys, SEARCH_INDEX[OCCURRENCE_KEY] ) )
RETURN
    IF (
        NOT Searching || ISEMPTY ( SearchableRefs ),
        1,
        IF ( ClientHits > 0 || CarerHits > 0 || JobTypeHits > 0 || CallHits > 0, 1, 0 )
    )
```

Four keys, four branches. There are no relationships, so there is nothing to
remove. The keys come from the fact's own columns, so `VALUES` carries no
dimension blank row here.

`DIM_JOBTYPE[JOB_TYPE_NAME]` in `FixedRefs` assumes the "Job Type" column has been
fixed. It is currently bound to `CountNonNull(SCHEDULE_DIFFERENCE_REPORT.JOB_TYPE_ID)`
— a count of ids under a name that promises the job type name — and that column no
longer exists on the fact.

Only two fact columns are searchable here: `CANCELLATION_COMMENT` and
`CANCELLATION_REASON`. `TIMESHEET_STATUS` and `EARLY_LATE` are populated on all
112M rows and have their own slicers; `SYSTEM_COMMENTS` is populated on 21.9% —
24.5M index rows for machine-generated text nobody searches by phrase.

**`OCCURRENCE_KEY` must be non-null before this works.** It is a new column on an
incremental model, so the first deploy needs one `--full-refresh` (or a targeted
backfill) — otherwise the history outside the 60-day window keeps a NULL key and
drops out of the match silently.

**`OCCURRENCE_KEY` is an integer, in the fact and in the index.** It used to be the
string `'care1|123|20260805'`, unique on every row, and as text it was the largest
column of the model twice over (the layout is in `models/marts/_mart__models.yml`).
The switch needed a `--full-refresh` of `mart__schedule_difference_report`, because an
incremental run cannot convert the history's type. In Power BI give the column
`dataType: int64` in both `SCHEDULE_DIFFERENCE_REPORT` and `SEARCH_INDEX` (the two
must match for `TREATAS`) and `isAvailableInMdx: false`, since nothing groups by it.
The DAX above is unchanged.

Every other key in the index is an integer too (`macros/source_key.sql`), so each
`*_KEY` column is `int64` in `SEARCH_INDEX` and on the entity it is matched against;
`TREATAS` and relationships need the same type on both sides.

---

## Birthday

Not wired. The report has no field parameter and its columns are not indexed —
`person_key` is not a `source_key`, so it needs its own source block in
`mart__search_index` before anything here applies.

---

## Anniversary

Not wired, same as Birthday: no field parameter, and the search runs on the
report's own DAX `Search Text` column. Its `carer_key` is a `source_key`, so a
relationship to the `mart__dim_carer` block would work, but that block indexes
dim_carer's attributes rather than the list's own columns (state, email, days to
go). Wiring it would need a source block over `mart__anniversary_report`.
