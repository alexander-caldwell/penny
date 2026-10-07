{#-
    penny_job_role — classify a BigQuery job as the model's own build, a hook,
    or run overhead.

    A single dbt model can create many BigQuery jobs. dbt renders the query
    comment (and therefore the job labels) once per node, so every pre-hook and
    post-hook statement carries the same dbt_model_name label as the model it
    belongs to. Counting jobs therefore overstates how many models ran: one
    model with twelve hook statements looks like thirteen models.

    This macro returns a SQL case expression that splits those jobs apart. It is
    shared by int_penny_model_runs and log_run_costs so both agree.

    Values:
      'build'     the statement that writes the model's own relation, including
                  the __dbt_tmp temp build of an incremental model
      'hook'      attributable to a model but not its build statement: pre-hooks,
                  post-hooks, grants
      'overhead'  not attributable to any model: introspective queries, package
                  operations, on-run-start / on-run-end statements

    A job is a build when both are true:
      1. its statement_type writes data or DDL, and
      2. its target table (the job's destination table, which BigQuery fills
         in for DDL as well as for CTAS and DML),
         with any __dbt_tmp suffix stripped, equals the resolved model name.

    Known limits:
      - A post-hook that writes to a *different* table (an audit log, say) is
        correctly classified as 'hook' only while dbt_model_name or dbt_node_id
        labels are present. With no labels at all, model_name falls back to the
        destination table, so such a hook looks like a build of its own model.
      - A hook writing to the model's own table (a manual backfill statement in
        a post-hook) is classified as 'build'. It writes the model relation, so
        this is arguably right, but it is worth knowing.

    Arguments are SQL expressions (column names), not literals.
-#}

{#- statement_type values that write data or create objects. Everything else
    (SELECT, GRANT, ALTER_TABLE, CALL, and so on) cannot be a model build. -#}
{% macro penny_build_statement_types() %}
    {{ return([
        'CREATE_TABLE_AS_SELECT',
        'CREATE_TABLE',
        'CREATE_VIEW',
        'CREATE_MATERIALIZED_VIEW',
        'CREATE_SNAPSHOT_TABLE',
        'MERGE',
        'INSERT',
        'UPDATE',
        'DELETE',
        'TRUNCATE_TABLE'
    ]) }}
{% endmacro %}

{% macro penny_job_role(statement_type, target_table, model_name) %}
    {%- set build_types = penny.penny_build_statement_types() -%}
    {%- set build_types_sql = "'" ~ build_types | join("', '") ~ "'" -%}
    {{-
        'case'
        ~ " when " ~ model_name ~ " = 'unknown' then 'overhead'"
        ~ " when " ~ statement_type ~ " in (" ~ build_types_sql ~ ")"
        ~ "  and regexp_replace(coalesce(" ~ target_table ~ ", ''), r'__dbt_tmp$', '') = " ~ model_name
        ~ "  then 'build'"
        ~ " else 'hook' end"
    -}}
{% endmacro %}
