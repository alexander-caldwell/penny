{#-
    penny_query_comment — emit dbt node identity as a JSON query comment.

    Wire it into the consumer project's dbt_project.yml:

        query-comment:
          comment: "{{ penny.penny_query_comment(node) }}"
          job-label: true

    With `job-label: true`, dbt-bigquery parses this JSON comment and turns each
    key/value into a BigQuery job label (sanitised to lowercase, with disallowed
    characters replaced by underscores and truncated to 63 chars). dbt always
    adds `dbt_invocation_id` on top, so Penny gets all three labels it reads.

    Why this and not `models: +labels:` in dbt_project.yml? That file is rendered
    with no model context, so `{{ this.name }}` / `{{ node.name }}` are undefined
    and dbt errors. The query comment is rendered per node, so `node` is in scope.

    `node` is None for statements not tied to a model (e.g. some macros); in that
    case we emit an empty object and only dbt_invocation_id is labelled.
-#}
{% macro penny_query_comment(node) %}
    {%- set comment = {} -%}
    {%- if node is not none -%}
        {%- do comment.update({
            'dbt_model_name': node.name,
            'dbt_node_id': node.unique_id
        }) -%}
    {%- endif -%}
    {{ return(tojson(comment)) }}
{% endmacro %}
