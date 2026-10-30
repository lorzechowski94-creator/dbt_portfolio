-- Mart (SEARCH INDEX): every searchable value in the account, in long format —
-- one row per entity per attribute. Backs the Power BI "search every column at
-- once" box in all reports (docs/powerbi_client_hours_measures.md#cross-column-search).
--
-- Grain: one row per (entity key, column_ref).
--
-- ONE TABLE, NOT ONE PER ENTITY, because a text slicer filters ONE column. Every
-- searchable value therefore has to share a single value_text, and a report that
-- shows attributes of several entities — schedule difference draws on dim_client,
-- dim_carer, dim_jobtype and its own fact — could not be served by separate index
-- tables without a slicer each.
--
-- HOW THE KEY COLUMNS WORK. There is one key column per entity and exactly ONE is
-- populated on any row; the rest are null. A report that searches one entity
-- relates it 1:* to this table. A report that searches several relates none: its
-- Search Hit measure matches each key with TREATAS, one branch per key, and ORs
-- them — an unsplit COUNTROWS over two keys intersects to nothing, because no row
-- carries both keys (docs/powerbi_client_hours_measures.md#model).
--
-- WHICH KEY AN ATTRIBUTE GETS IS DECIDED BY THE REPORT, NOT BY WHERE THE VALUE
-- LIVES. column_ref reproduces what NAMEOF() stores in the report's field
-- parameter, and the table named there is the one whose filter context will reach
-- the row. dim_hrfile's two columns are keyed on hr_file_key because the parameter
-- says DIM_HRFILE[...]; the carer attributes of the qualification export are keyed
-- on the fact even though some also exist on dim_carer, because that parameter
-- says CARER_QUALIFICATION_REPORT[...] and the visual groups by the fact's copies.
--
-- COST IS PAID PER ROW OF THE SOURCE. A dimension attribute costs one row per
-- entity — thousands. A fact attribute costs one row per fact row, so the column
-- lists below are curated against what people type, not against what the report
-- shows. schedule_difference has 112M rows: only its two SPARSE text columns are
-- indexed (3.3% and 4.4% populated, ~8.6M rows together, and blanks are dropped
-- at the end), while timesheet_status and early_late would cost 112M each and
-- already have their own slicers. system_comments is populated on 21.9% of rows —
-- 24.5M, three times everything else combined — and is machine-generated text
-- nobody searches by phrase, so it is deliberately absent.
--
-- Dates are indexed in the format the reports render them (DD-MM-YYYY).
--
-- Entries are (column_ref suffix, value expression). There is no display
-- label column: column_ref already reads as DIM_CLIENT[FULL_NAME], and the
-- report's own field parameter is the source of truth for what a column is
-- called on screen.

{% set key_columns = [
    'client_key', 'carer_key', 'job_type_key', 'group_key',
    'qualification_key', 'occurrence_key'
] %}

{#- Every key is an integer (macros/source_key.sql; occurrence_key and qualification_key
    have their own layouts). Each branch's NULL is cast to bigint for that reason: an
    untyped or varchar NULL would let the union settle a key column as text. -#}

{% set sources = [
    {
        'relation': 'mart__dim_client',
        'key': 'client_key',
        'ref_table': 'DIM_CLIENT',
        'attributes': [
            ('CLIENT_ID', 'client_id'),
            ('FULL_NAME', 'full_name'),
            ('FIRST_NAME', 'first_name'),
            ('SURNAME', 'surname'),
            ('CLIENT_NO', 'client_no'),
            ('AREA_NAME', 'area_name'),
            ('WORKGROUP', 'workgroup'),
            ('BRANCH', 'branch'),
            ('ADDRESS', 'address'),
            ('TOWN', 'town'),
            ('COUNTY', 'county'),
            ('POST_CODE', 'post_code'),
            ('PHONE', 'phone'),
            ('EMAIL', 'email'),
            ('DATE_OF_BIRTH', "to_varchar(date_of_birth, 'DD-MM-YYYY')"),
            ('SERVICE_COMMENCEMENT', "to_varchar(service_commencement, 'DD-MM-YYYY')"),
            ('FIRST_SCHEDULED_EVENT', "to_varchar(first_scheduled_event, 'DD-MM-YYYY')"),
            ('CSO', 'cso'),
            ('COORDINATOR_ZONE', 'coordinator_zone'),
            ('BILLING_CODE', 'billing_code'),
            ('REFERRAL_REASON', 'referral_reason'),
            ('UNIT_ID', 'unit_id'),
            ('COUNCIL_ID', 'council_id'),
            ('CARE_MANAGER', 'care_manager'),
            ('FUNDER', 'funder'),
            ('STATUS_LABEL', 'status_label'),
        ],
    },
    {
        'relation': 'mart__dim_carer',
        'key': 'carer_key',
        'ref_table': 'DIM_CARER',
        'attributes': [
            ('CARER_NO', 'carer_no'),
            ('FULL_NAME', 'full_name'),
            ('FIRST_NAME', 'first_name'),
            ('SURNAME', 'surname'),
            ('POSITION', 'position'),
            ('AREA', 'area'),
            ('ADDRESS', 'address'),
            ('TOWN', 'town'),
            ('COUNTY', 'county'),
            ('DATE_OF_BIRTH', "to_varchar(date_of_birth, 'DD-MM-YYYY')"),
            ('START_DATE', "to_varchar(start_date, 'DD-MM-YYYY')"),
        ],
    },
    {
        'relation': 'mart__dim_jobtype',
        'key': 'job_type_key',
        'ref_table': 'DIM_JOBTYPE',
        'attributes': [
            ('JOB_TYPE_NAME', 'job_type_name'),
        ],
    },
    {
        'relation': 'mart__dim_jobtype_group',
        'key': 'group_key',
        'ref_table': 'DIM_JOBTYPE_GROUP',
        'attributes': [
            ('GROUP_NAME', 'group_name'),
        ],
    },
    {
        'relation': 'mart__carer_qualification_report',
        'from_cte': 'qualification_joined',
        'key': 'qualification_key',
        'ref_table': 'CARER_QUALIFICATION_REPORT',
        'attributes': [
            ('CARER_NO', 'carer_no'),
            ('FIRST_NAME', 'first_name'),
            ('SURNAME', 'surname'),
            ('POSITION', 'position'),
            ('AREA', 'area'),
            ('BRANCH', 'branch'),
            ('WORKGROUP', 'workgroup'),
            ('QUALIFICATION_NAME', 'qualification_name'),
        ],
    },
    {
        'relation': 'mart__carer_qualification_report',
        'from_cte': 'qualification_joined',
        'key': 'qualification_key',
        'ref_table': 'DIM_HRFILE',
        'attributes': [
            ('HR_FILE_NAME', 'hr_file_name'),
            ('HR_FILE_TYPE', 'hr_file_type'),
        ],
    },
    {
        'relation': 'mart__schedule_difference_report',
        'key': 'occurrence_key',
        'ref_table': 'SCHEDULE_DIFFERENCE_REPORT',
        'attributes': [
            ('CANCELLATION_COMMENT', 'cancellation_comment'),
            ('CANCELLATION_REASON', 'cancellation_reason'),
        ],
    },
] %}

with qualification_joined as (
    -- dim_hrfile is folded into the fact rather than indexed under its own key:
    -- the fact is already related to dim_hrfile for the HR File slicer, so a second
    -- relationship from the index to that dimension closes a loop and Power BI
    -- refuses it. Keying these two values on the fact costs ~3M rows and removes
    -- the ambiguity; column_ref still says DIM_HRFILE, because that is what the
    -- report's field parameter names.
    select
        f.*,
        h.hr_file_name,
        h.hr_file_type
    from {{ ref('mart__carer_qualification_report') }} as f
    left join {{ ref('mart__dim_hrfile') }} as h
        on f.hr_file_key = h.hr_file_key
),

unpivoted as (
    {%- for source in sources %}
        {%- for ref_column, expression in source.attributes %}
            select
                source,
                {%- for key in key_columns %}
                    {% if key == source.key %}{{ key }}{% else %}cast(null as bigint) as {{ key }}{% endif %},
                {%- endfor %}
                '{{ source.ref_table }}[{{ ref_column }}]' as column_ref,
                trim(cast({{ expression }} as varchar)) as value_text,
                company_id,
                location_id
            from {% if source.get('from_cte') %}{{ source.from_cte }}{% else %}{{ ref(source.relation) }}{% endif %}
            {%- if not (loop.last and source == sources[-1]) %}
                union all
            {%- endif %}
        {%- endfor %}
    {%- endfor %}
),

final as (
    -- A blank value would match every search term, so it is dropped rather than
    -- indexed: the entity still appears via its other attributes. This is also
    -- what keeps the two schedule_difference columns affordable — they are
    -- populated on a few per cent of 112M rows.
    select *
    from unpivoted
    where value_text is not null and value_text != ''
)

select * from final
