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
    One row per BigQuery job, read from INFORMATION_SCHEMA.JOBS.

    Incremental via insert_overwrite on the day partition of created_at. On a
    full refresh we look back `penny_lookback_days`; incrementally we read only
    partitions newer than the table's current max partition (_dbt_max_partition).

    dbt labels are extracted from the labels array. dbt_invocation_id is always
    present on dbt jobs; dbt_model_name / dbt_node_id only appear once the
    consumer project configures +labels (see README). Missing labels resolve to
    null rather than dropping the row.

    Project and region default to the dbt target (target.project /
    target.location) so no config is needed in the common case. Override with the
    penny_bigquery_project / penny_bigquery_region vars to read a different
    project. Path resolution lives in penny_jobs_relation().
-#}

with jobs as (

    select
        job_id,
        creation_time,
        start_time,
        end_time,
        job_type,
        statement_type,
        state,
        cache_hit,
        user_email,
        total_bytes_processed,
        total_bytes_billed,
        total_slot_ms,
        reservation_id,
        error_result,
        destination_table,
        labels
    from {{ penny.penny_jobs_relation() }}
    where state = 'DONE'
      and job_type = 'QUERY'
      and (statement_type is null or statement_type != 'SCRIPT')

    {% if is_incremental() %}
      and creation_time > _dbt_max_partition
    {% else %}
      and creation_time >= timestamp_sub(current_timestamp(), interval {{ var('penny_lookback_days', 180) }} day)
    {% endif %}

),

labelled as (

    select
        job_id,
        creation_time as created_at,
        start_time,
        end_time,
        cache_hit,
        user_email,
        total_bytes_processed,
        total_bytes_billed,
        total_slot_ms,
        reservation_id,
        error_result.message as error_message,
        destination_table.project_id as destination_project,
        destination_table.dataset_id as destination_dataset,
        destination_table.table_id as destination_table,
        (select label.value from unnest(labels) as label where label.key = 'dbt_invocation_id') as dbt_invocation_id,
        (select label.value from unnest(labels) as label where label.key = 'dbt_model_name') as dbt_model_name,
        -- Prefer Penny's dbt_node_id label; fall back to the standard `node_id`
        -- label that dbt's default query-comment emits under job-label: true.
        coalesce(
            (select label.value from unnest(labels) as label where label.key = 'dbt_node_id'),
            (select label.value from unnest(labels) as label where label.key = 'node_id')
        ) as dbt_node_id
    from jobs

),

filtered as (

    select *
    from labelled
    where 1 = 1

    {% if var('penny_dbt_only', true) %}
      and dbt_invocation_id is not null
    {% endif %}

    {% if var('penny_dbt_project_filter', none) is not none %}
      and split(dbt_node_id, '.')[safe_offset(1)] = '{{ var('penny_dbt_project_filter') }}'
    {% endif %}

),

final as (

    select
        job_id,
        created_at,
        end_time as completed_at,
        round(timestamp_diff(end_time, start_time, millisecond) / 1000.0, 3) as execution_time_seconds,
        total_bytes_processed,
        total_bytes_billed,
        total_slot_ms,
        reservation_id,
        cache_hit,
        destination_project,
        destination_dataset,
        destination_table,
        user_email,
        error_message,
        dbt_invocation_id,
        dbt_model_name,
        dbt_node_id
    from filtered

)

select
    job_id,
    created_at,
    completed_at,
    execution_time_seconds,
    total_bytes_processed,
    total_bytes_billed,
    total_slot_ms,
    reservation_id,
    cache_hit,
    destination_project,
    destination_dataset,
    destination_table,
    user_email,
    error_message,
    dbt_invocation_id,
    dbt_model_name,
    dbt_node_id
from final
