{#-
    log_run_costs — on-run-end hook.

    Prints a formatted cost summary for the current dbt invocation to the
    console.

    Two different questions are answered by two different sources:

      "How many models ran?"  comes from dbt's own `results` list, which is the
                              authoritative record of what dbt just executed.
      "What did it cost?"     comes from INFORMATION_SCHEMA.JOBS, the only place
                              bytes billed and slot time are recorded.

    Why not count jobs for both? Because dbt renders the query comment (and so
    the job labels) once per node, every pre-hook and post-hook statement is
    labelled with the same model name as the model's build statement. Counting
    jobs therefore overstates models run: one model with twelve hook statements
    counts as thirteen. Hook statements still cost real money, so the summary
    reports the job count and the hook share of cost rather than hiding them.

    Register in the consumer project's dbt_project.yml:

        on-run-end:
          - "{{ penny.log_run_costs() }}"

    Gracefully degrades:
      - No-ops on non-BigQuery targets.
      - No-ops during parse (only runs when `execute` is true).
      - When `results` is empty (a `dbt run-operation`, for example) the model
        count falls back to distinct model names seen in the job labels.
      - If model-level labels are missing, model names fall back to the target
        table name (see penny_model_name).
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

    {#- ── What dbt says it ran ──────────────────────────────────────────────
        `results` is a list of run results, one per node dbt executed. Node
        type is read off unique_id ('model.my_project.my_model') rather than
        resource_type, because unique_id is a plain string in every dbt
        version while resource_type is an enum whose repr has changed.
        Skipped nodes are excluded: they never ran.

        Every attribute is probed with `is defined` before use, and nothing is
        chained off a value that might be undefined. Jinja raises on attribute
        access against an undefined value, so a run result whose shape differs
        from dbt Core's would otherwise abort the whole hook. This is the only
        place Penny reads dbt internals rather than BigQuery job history, and
        the Fusion engine has open parity bugs in exactly this object. On an
        unusable `results` the loop simply counts nothing, and the model count
        falls back to distinct model names from the job labels below. -#}
    {% set node_counts = {} %}
    {% if results is defined and results is not none and results is iterable %}
        {% for res in results %}
            {%- set node = res.node if res.node is defined else none -%}
            {%- set uid = node.unique_id if (node is not none and node.unique_id is defined) else none -%}
            {%- set status = (res.status if res.status is defined else '') | string | lower -%}
            {#- No status is treated as "it ran": better to over-count by one
                than to silently drop a model that really did build. -#}
            {% if uid is not none and 'skip' not in status %}
                {% set node_type = (uid | string).split('.')[0] %}
                {% if node_type %}
                    {% do node_counts.update({node_type: node_counts.get(node_type, 0) + 1}) %}
                {% endif %}
            {% endif %}
        {% endfor %}
    {% endif %}
    {% set dbt_models_run = node_counts.get('model', 0) %}
    {% set dbt_snapshots_run = node_counts.get('snapshot', 0) %}
    {% set dbt_seeds_run = node_counts.get('seed', 0) %}
    {% set dbt_tests_run = node_counts.get('test', 0) + node_counts.get('unit_test', 0) %}

    {#- ── What BigQuery says it cost ────────────────────────────────────────
        Per-job cost expression, summed below so 'auto' mode prices each job by
        its own reservation_id rather than one formula for the whole run. -#}
    {% set cost_expr = penny.get_cost_usd('total_bytes_billed', 'total_slot_ms', 'reservation_id') %}

    {% set query %}
        with invocation_jobs as (

            select
                total_bytes_billed,
                total_slot_ms,
                reservation_id,
                statement_type,
                -- destination_table only. ddl_target_table does not exist in
                -- every region's JOBS view; see stg_bigquery__job_history.
                destination_table.table_id as target_table,
                (select label.value from unnest(labels) as label where label.key = 'dbt_model_name') as dbt_model_name,
                coalesce(
                    (select label.value from unnest(labels) as label where label.key = 'dbt_node_id'),
                    (select label.value from unnest(labels) as label where label.key = 'node_id')
                ) as dbt_node_id
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

        ),

        classified as (

            select
                total_bytes_billed,
                {{ penny.penny_model_name('dbt_model_name', 'dbt_node_id', 'target_table') }} as model_name,
                {{ cost_expr }} as cost_usd,
                {{ penny.penny_job_role(
                       'statement_type',
                       'target_table',
                       penny.penny_model_name('dbt_model_name', 'dbt_node_id', 'target_table')
                   ) }} as job_role
            from invocation_jobs

        ),

        -- Largest model is judged on a model's whole footprint (its build plus
        -- its hooks), not on a single job, so a heavy post-hook cannot outrank
        -- the model it belongs to.
        per_model as (

            select
                model_name,
                sum(total_bytes_billed) as bytes_billed
            from classified
            where job_role != 'overhead'
            group by 1

        )

        select
            count(*) as total_jobs,
            countif(job_role = 'build') as build_jobs,
            countif(job_role = 'hook') as hook_jobs,
            countif(job_role = 'overhead') as overhead_jobs,
            count(distinct if(job_role = 'overhead', null, model_name)) as models_labelled,
            round(sum(total_bytes_billed) / power(1024, 4), 4) as total_tb_billed,
            round(sum(cost_usd), 6) as total_cost_usd,
            round(sum(if(job_role = 'build', cost_usd, 0)), 6) as build_cost_usd,
            round(sum(if(job_role = 'hook', cost_usd, 0)), 6) as hook_cost_usd,
            round(sum(if(job_role = 'overhead', cost_usd, 0)), 6) as overhead_cost_usd,
            -- Scalar subqueries: null rather than an error when no model jobs ran.
            (select model_name from per_model order by bytes_billed desc limit 1) as largest_model,
            (select round(bytes_billed / power(1024, 3), 2) from per_model order by bytes_billed desc limit 1) as largest_gb
        from classified
    {% endset %}

    {% set results_table = run_query(query) %}

    {% if results_table is none or (results_table.rows | length) == 0 %}
        {% do log("🪙 Penny: no job history returned for this invocation.", info=true) %}
        {% do return('') %}
    {% endif %}

    {% set row = results_table.rows[0] %}
    {% set total_jobs = row[0] or 0 %}
    {% set build_jobs = row[1] or 0 %}
    {% set hook_jobs = row[2] or 0 %}
    {% set overhead_jobs = row[3] or 0 %}
    {% set models_labelled = row[4] or 0 %}
    {% set total_tb = row[5] if row[5] is not none else 0 %}
    {% set total_cost = row[6] if row[6] is not none else 0 %}
    {% set build_cost = row[7] if row[7] is not none else 0 %}
    {% set hook_cost = row[8] if row[8] is not none else 0 %}
    {% set overhead_cost = row[9] if row[9] is not none else 0 %}
    {% set largest_model = row[10] if row[10] is not none else 'n/a' %}
    {% set largest_gb = row[11] if row[11] is not none else 0 %}

    {% if total_jobs == 0 %}
        {% do log("🪙 Penny: no dbt jobs found for invocation " ~ invocation_id ~ " (labels may not be configured yet).", info=true) %}
        {% do return('') %}
    {% endif %}

    {#- Prefer dbt's count. Fall back to distinct labelled model names when dbt
        reported no nodes (e.g. `dbt run-operation`, which still runs queries). -#}
    {% set models_run = dbt_models_run if dbt_models_run > 0 else models_labelled %}
    {% set models_source = 'dbt' if dbt_models_run > 0 else 'job labels' %}

    {#- Build the optional lines separately to keep the summary block readable. -#}
    {% set other_lines = [] %}
    {% if dbt_snapshots_run > 0 %}
        {% do other_lines.append('  Snapshots run:     ' ~ dbt_snapshots_run) %}
    {% endif %}
    {% if dbt_seeds_run > 0 %}
        {% do other_lines.append('  Seeds loaded:      ' ~ dbt_seeds_run) %}
    {% endif %}
    {% if dbt_tests_run > 0 %}
        {% do other_lines.append('  Tests run:         ' ~ dbt_tests_run) %}
    {% endif %}

    {% set summary %}

═══════════════════════════════════════════
  🪙  Penny — Run Summary
═══════════════════════════════════════════
  Models run:        {{ models_run }}{% if models_source != 'dbt' %} (from {{ models_source }}){% endif %}
{% for line in other_lines %}{{ line }}
{% endfor %}  Queries executed:  {{ total_jobs }} ({{ build_jobs }} build, {{ hook_jobs }} hook, {{ overhead_jobs }} overhead)
  Total TB billed:   {{ total_tb }} TB
  Estimated cost:    ${{ total_cost }} USD
    builds:          ${{ build_cost }}
    hooks:           ${{ hook_cost }}
    overhead:        ${{ overhead_cost }}
  Largest model:     {{ largest_gb }} GB ({{ largest_model }})
═══════════════════════════════════════════
    {% endset %}

    {% do log(summary, info=true) %}
    {% do return('') %}

{% endmacro %}
