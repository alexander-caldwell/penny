{#-
    penny_project_filter — restrict jobs to one dbt project.

    Returns a SQL boolean expression for the penny_dbt_project_filter var.
    "Project" here means the *root* dbt project, the one that ran dbt, not the
    package a model is defined in. Penny's own models therefore count as part
    of the consumer's project rather than as a separate 'penny' project.

    Two sources, in order of preference:

      1. The dbt_project_name label, emitted by penny_query_comment from v0.1.6
         on. An exact match, no parsing.
      2. The dbt_node_id label, prefix-matched. This covers jobs labelled before
         v0.1.6 and consumers using dbt's own default query comment, which emits
         node_id but no project label.

    The trap this macro exists to avoid: BigQuery does not allow full stops in
    label values, so dbt's node id `model.my_project.my_model` is stored as
    `model_my_project_my_model`. Splitting on '.' returns null for every row and
    the filter silently drops the whole table. Splitting on '_' is no better —
    resource type, project and model name can all contain underscores
    (sql_operation, my_project, wh_ecommerce__customer_dim), so there is no
    reliable boundary. Hence the anchored prefix match below.

    Known limit of the fallback: a project name that is a prefix of another
    (`public` against `public_data`) can match the wrong jobs. Set the
    query-comment hook to get the exact label and the fallback stops mattering.

    Arguments: `project` is a literal string (the var's value); the other two
    are SQL expressions (column names), as in Penny's other shared macros.
-#}
{% macro penny_project_filter(project, dbt_project_name='dbt_project_name', dbt_node_id='dbt_node_id') %}
    {%- set normalised = project | lower | replace('-', '_') -%}
    {%- set node_id_prefix = '^(' ~ penny.penny_node_types() ~ ')_' ~ normalised ~ '_' -%}
    {{-
        "(case when " ~ dbt_project_name ~ " is not null"
        ~ " then " ~ dbt_project_name ~ " = '" ~ normalised ~ "'"
        ~ " else regexp_contains(coalesce(" ~ dbt_node_id ~ ", ''), r'" ~ node_id_prefix ~ "') end)"
    -}}
{% endmacro %}


{#-
    penny_node_types — the dbt resource types that can prefix a sanitised node
    id. Shared by penny_model_name (which strips the prefix) and
    penny_project_filter (which matches on it) so the two never drift apart.

    Returns a regex alternation fragment, not a list.
-#}
{% macro penny_node_types() %}
    {{- 'model|snapshot|seed|test|unit_test|analysis|operation' -}}
{% endmacro %}
