{#-
    log_run_costs — on-run-end hook.

    Queries INFORMATION_SCHEMA.JOBS for every job created by the current dbt
    invocation and prints a formatted cost summary to the console.

    Register in the consumer project's dbt_project.yml:

        on-run-end:
          - "{{ penny.log_run_costs() }}"

    Gracefully degrades:
      - No-ops on non-BigQuery targets.
      - No-ops during parse (only runs when `execute` is true).
      - If model-level labels are missing, the "largest model" falls back to the
        destination table name.
-#}
{% macro log_run_costs() %}

    {#- Only run at execution time, never during parse. -#}
    {% if not execute %}
        {% do return('') %}
    {% endif %}

    {% if target.type != 'bigquery' %}
        {% do log("🪙 Penny: log_run_costs() only supports BigQuery targets — skipping.", info=true) %}
        {% do return('') %}
    {% endif %}

    {#- Per-job cost expression, summed below so 'auto' mode prices each job by
        its own reservation_id rather than one formula for the whole run. -#}
    {% set cost_expr = penny.get_cost_usd('total_bytes_billed', 'total_slot_ms', 'reservation_id') %}

    {% set query %}
        with invocation_jobs as (

            select
                total_bytes_billed,
                total_slot_ms,
                reservation_id,
                (select label.value from unnest(labels) as label where label.key = 'dbt_model_name') as dbt_model_name,
                destination_table.table_id as destination_table
            from {{ penny.penny_jobs_relation() }}
            where state = 'DONE'
              and job_type = 'QUERY'
              and (statement_type is null or statement_type != 'SCRIPT')
              and creation_time >= timestamp_sub(current_timestamp(), interval 1 day)
              and exists (
                  select 1
                  from unnest(labels) as label
                  where label.key = 'dbt_invocation_id'
                    and label.value = '{{ invocation_id }}'
              )

        )

        select
            count(*) as models_run,
            round(sum(total_bytes_billed) / power(1024, 4), 4) as total_tb_billed,
            round(sum({{ cost_expr }}), 6) as total_cost_usd,
            round(max(total_bytes_billed) / power(1024, 3), 2) as largest_gb,
            array_agg(
                coalesce(dbt_model_name, destination_table, 'unknown')
                order by total_bytes_billed desc
                limit 1
            )[safe_offset(0)] as largest_model
        from invocation_jobs
    {% endset %}

    {% set results = run_query(query) %}

    {% if results is none or (results.rows | length) == 0 %}
        {% do log("🪙 Penny: no job history returned for this invocation.", info=true) %}
        {% do return('') %}
    {% endif %}

    {% set row = results.rows[0] %}
    {% set models_run = row[0] or 0 %}
    {% set total_tb = row[1] if row[1] is not none else 0 %}
    {% set total_cost = row[2] if row[2] is not none else 0 %}
    {% set largest_gb = row[3] if row[3] is not none else 0 %}
    {% set largest_model = row[4] if row[4] is not none else 'n/a' %}

    {% if models_run == 0 %}
        {% do log("🪙 Penny: no dbt jobs found for invocation " ~ invocation_id ~ " (labels may not be configured yet).", info=true) %}
        {% do return('') %}
    {% endif %}

    {% set summary %}

═══════════════════════════════════════════
  🪙 Penny — Run Summary
═══════════════════════════════════════════
  Models run:        {{ models_run }}
  Total TB billed:   {{ total_tb }} TB
  Estimated cost:    ${{ total_cost }} USD
  Largest model:     {{ largest_gb }} GB ({{ largest_model }})
═══════════════════════════════════════════
    {% endset %}

    {% do log(summary, info=true) %}
    {% do return('') %}

{% endmacro %}
