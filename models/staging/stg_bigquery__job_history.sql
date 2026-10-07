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
    present on dbt jobs; dbt_model_name / dbt_node_id / dbt_project_name only
    appear once the consumer project configures +labels (see README). Missing
    labels resolve to null rather than dropping the row.

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
        ddl_target_table,
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
        statement_type,
        destination_table.project_id as destination_project,
        destination_table.dataset_id as destination_dataset,
        destination_table.table_id as destination_table,
        -- The table this job wrote. CTAS/DML populate destination_table; CREATE
        -- VIEW and other DDL populate ddl_target_table instead. Coalescing gives
        -- one column that the job-role classifier can compare to the model name.
        coalesce(destination_table.table_id, ddl_target_table.table_id) as target_table,
        (select label.value from unnest(labels) as label where label.key = 'dbt_invocation_id') as dbt_invocation_id,
        (select label.value from unnest(labels) as label where label.key = 'dbt_model_name') as dbt_model_name,
        -- Prefer Penny's dbt_node_id label; fall back to the standard `node_id`
        -- label that dbt's default query-comment emits under job-label: true.
        coalesce(
            (select label.value from unnest(labels) as label where label.key = 'dbt_node_id'),
            (select label.value from unnest(labels) as label where label.key = 'node_id')
        ) as dbt_node_id,
        -- Root dbt project, emitted by penny_query_comment from v0.1.6 on.
        -- Null for jobs labelled before that, and for consumers using dbt's own
        -- default query comment; penny_project_filter falls back to the node id.
        (select label.value from unnest(labels) as label where label.key = 'dbt_project_name') as dbt_project_name
    from jobs

),

filtered as (

    select *
    from labelled
    where 1 = 1

    {% if var('penny_dbt_only', true) %}
      and dbt_invocation_id is not null
    {% endif %}

    {#- Matching the project is not a one-liner: BigQuery stores the node id
        with its dots replaced by underscores, so it cannot simply be split.
        penny_project_filter prefers the dbt_project_name label and falls back
        to an anchored prefix match on the node id. -#}
    {% if var('penny_dbt_project_filter', none) is not none %}
      and {{ penny.penny_project_filter(var('penny_dbt_project_filter')) }}
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
        statement_type,
        destination_project,
        destination_dataset,
        destination_table,
        target_table,
        user_email,
        error_message,
        dbt_invocation_id,
        dbt_model_name,
        dbt_node_id,
        dbt_project_name
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
    statement_type,
    destination_project,
    destination_dataset,
    destination_table,
    target_table,
    user_email,
    error_message,
    dbt_invocation_id,
    dbt_model_name,
    dbt_node_id,
    dbt_project_name
from final
