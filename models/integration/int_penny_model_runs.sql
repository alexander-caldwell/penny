{{
    config(
        materialized='incremental',
        incremental_strategy='insert_overwrite',
        partition_by={
            'field': 'created_at',
            'data_type': 'timestamp',
            'granularity': 'day'
        },
        on_schema_change='sync_all_columns'
    )
}}

{#-
    One row per dbt model execution (one BigQuery job), enriched with:
      - cost_usd via the shared penny.get_cost_usd formula (auto / on-demand /
        editions; in 'auto' each job is priced by whether it ran in a reservation)
      - methodology_layer derived from the model-name prefix
      - gb_billed / tb_billed / is_error derived metrics

    Model identity prefers the dbt_model_name label and falls back to the
    destination table name when labels are not yet configured. Free tier is
    deliberately ignored for the MVP — gross cost is reported.
-#}

{%- set penny_mode = var('penny_pricing_model', 'auto') -%}

{#- Regex that strips the resource-type prefix (and, when penny_dbt_project_name
    is set, the sanitised project prefix) off a `node_id` job label so it reads
    as a clean model name. dbt's default query-comment stamps node_id as
    model_<project>_<name> (dots sanitised to underscores). -#}
{%- set penny_project = var('penny_dbt_project_name', none) -%}
{%- set node_types = 'model|snapshot|seed|test|unit_test|analysis|operation' -%}
{%- if penny_project -%}
    {%- set node_id_prefix = '^(' ~ node_types ~ ')_' ~ (penny_project | lower | replace('-', '_')) ~ '_' -%}
{%- else -%}
    {%- set node_id_prefix = '^(' ~ node_types ~ ')_' -%}
{%- endif -%}

with job_history as (

    select * from {{ ref('stg_bigquery__job_history') }}

    {% if is_incremental() %}
    where created_at > _dbt_max_partition
    {% endif %}

),

identified as (

    select
        *,
        -- Model identity, in order of preference:
        --   1. dbt_model_name label (cleanest, when configured)
        --   2. node_id label with its resource/project prefix stripped
        --      (covers projects using dbt's default job-label query comment)
        --   3. destination table name
        --   4. 'unknown' — dbt jobs that write nowhere (introspection, hooks,
        --      package operations) so model_name is never null
        -- The trailing __dbt_tmp incremental suffix is stripped so a model's
        -- temp-build job folds into the model instead of becoming a phantom row.
        regexp_replace(
            coalesce(
                dbt_model_name,
                nullif(regexp_replace(dbt_node_id, r'{{ node_id_prefix }}', ''), ''),
                destination_table,
                'unknown'
            ),
            r'__dbt_tmp$', ''
        ) as model_name,
        dbt_model_name is null as is_label_fallback
    from job_history

),

enriched as (

    select
        job_id,
        created_at,
        date(created_at) as run_date,
        completed_at,
        dbt_invocation_id,
        dbt_node_id,
        model_name,
        is_label_fallback,

        -- Classify by name. RA staging/integration use stg_/int_ prefixes;
        -- warehouse tables follow the Kimball *_fact / *_dim suffix convention
        -- (and may carry wh_/mart_/dim_/fct_ prefixes depending on labelling).
        case
            when starts_with(model_name, 'stg_') then 'staging'
            when starts_with(model_name, 'int_') then 'integration'
            when starts_with(model_name, 'wh_')
              or starts_with(model_name, 'mart_')
              or starts_with(model_name, 'dim_')
              or starts_with(model_name, 'fct_')
              or ends_with(model_name, '_fact')
              or ends_with(model_name, '_dim') then 'warehouse'
            when starts_with(model_name, 'rpt_')
              or starts_with(model_name, 'mtr_') then 'analytics'
            else 'unclassified'
        end as methodology_layer,

        execution_time_seconds,
        total_bytes_processed,
        total_bytes_billed,
        round(total_bytes_billed / power(1024, 3), 4) as gb_billed,
        round(total_bytes_billed / power(1024, 4), 6) as tb_billed,
        total_slot_ms,
        reservation_id,
        cache_hit,

        round({{ penny.get_cost_usd('total_bytes_billed', 'total_slot_ms', 'reservation_id') }}, 6) as cost_usd,
        {% if penny_mode == 'on_demand' -%}
            'on_demand'
        {%- elif penny_mode == 'editions' -%}
            'editions'
        {%- else -%}
            case when reservation_id is null then 'on_demand' else 'editions' end
        {%- endif %} as pricing_model,

        user_email,
        destination_dataset,
        destination_table,
        error_message,
        error_message is not null as is_error

    from identified

)

select
    job_id,
    created_at,
    run_date,
    completed_at,
    dbt_invocation_id,
    dbt_node_id,
    model_name,
    is_label_fallback,
    methodology_layer,
    execution_time_seconds,
    total_bytes_processed,
    total_bytes_billed,
    gb_billed,
    tb_billed,
    total_slot_ms,
    reservation_id,
    cache_hit,
    cost_usd,
    pricing_model,
    user_email,
    destination_dataset,
    destination_table,
    error_message,
    is_error
from enriched
