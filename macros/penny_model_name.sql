{#-
    penny_model_name — resolve a job's model name from its dbt job labels.

    Returns a SQL expression, shared by int_penny_model_runs and log_run_costs
    so the console summary and the tables never disagree on a model's name.

    Order of preference:
      1. dbt_model_name label (cleanest, when the consumer project sets it)
      2. dbt_node_id label with its resource-type and project prefix stripped,
         which covers projects using dbt's default job-label query comment
      3. the job's target table (destination table, or DDL target)
      4. 'unknown', so the result is never null

    The trailing __dbt_tmp suffix is stripped, so an incremental model's temp
    build folds into the model instead of appearing as a separate model.

    Arguments are SQL expressions (column names), not literals.
-#}
{% macro penny_model_name(dbt_model_name='dbt_model_name', dbt_node_id='dbt_node_id', target_table='target_table') %}
    {#- dbt's default query comment stamps node_id as model_<project>_<name>
        (dots sanitised to underscores). Strip the resource type, and the
        project too when penny_dbt_project_name is set. -#}
    {%- set penny_project = var('penny_dbt_project_name', none) -%}
    {#- Resource-type list lives in penny_node_types so penny_project_filter,
        which prefix-matches the same sanitised node id, cannot drift from it. -#}
    {%- set node_types = penny.penny_node_types() -%}
    {%- if penny_project -%}
        {%- set node_id_prefix = '^(' ~ node_types ~ ')_' ~ (penny_project | lower | replace('-', '_')) ~ '_' -%}
    {%- else -%}
        {%- set node_id_prefix = '^(' ~ node_types ~ ')_' -%}
    {%- endif -%}
    {{-
        "regexp_replace(coalesce("
        ~ dbt_model_name ~ ", "
        ~ "nullif(regexp_replace(" ~ dbt_node_id ~ ", r'" ~ node_id_prefix ~ "', ''), ''), "
        ~ target_table ~ ", "
        ~ "'unknown'), r'__dbt_tmp$', '')"
    -}}
{% endmacro %}
