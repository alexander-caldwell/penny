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
    One row per BigQuery job. This is NOT one row per model: dbt stamps the
    same dbt_model_name label on a model's pre-hooks and post-hooks as on its
    build statement, so one model can produce many rows here. Use `job_role` to
    tell them apart, and count distinct model_name (not rows) for models run.

    Each row is enriched with:
      - cost_usd via the shared penny.get_cost_usd formula (auto / on-demand /
        editions; in 'auto' each job is priced by whether it ran in a reservation)
      - methodology_layer derived from the model-name prefix
      - job_role ('build' / 'hook' / 'overhead') from penny.penny_job_role
      - gb_billed / tb_billed / is_error derived metrics

    Model identity is resolved by penny.penny_model_name. Free tier is
    deliberately ignored for the MVP — gross cost is reported.
-#}

{%- set penny_mode = var('penny_pricing_model', 'auto') -%}

with job_history as (

    select * from {{ ref('stg_bigquery__job_history') }}

    {% if is_incremental() %}
    where created_at > _dbt_max_partition
    {% endif %}

),

identified as (

    select
        *,
        -- Model identity and the __dbt_tmp fold live in penny_model_name, which
        -- log_run_costs also uses so the console summary matches these tables.
        {{ penny.penny_model_name('dbt_model_name', 'dbt_node_id', 'target_table') }} as model_name,
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
        statement_type,

        -- Split a model's own build statement from its hooks, and from run
        -- overhead that belongs to no model. Shared with log_run_costs so the
        -- console summary and the tables agree. See penny_job_role for limits.
        {{ penny.penny_job_role('statement_type', 'target_table', 'model_name') }} as job_role,

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
        target_table,
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
    statement_type,
    job_role,
    user_email,
    destination_dataset,
    destination_table,
    target_table,
    error_message,
    is_error
from enriched
