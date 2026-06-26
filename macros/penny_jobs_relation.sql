{#-
    penny_jobs_relation — fully-qualified INFORMATION_SCHEMA.JOBS path.

    Returns a backtick-quoted `project`.`region-xxx`.INFORMATION_SCHEMA.JOBS
    string for use in both the staging model and the log_run_costs macro, so the
    region-resolution logic lives in exactly one place.

    Project   defaults to target.project, override with penny_bigquery_project.
    Region    defaults to target.location, override with penny_bigquery_region.
              INFORMATION_SCHEMA requires the `region-` prefix (e.g.
              region-europe-west2, region-eu), but profiles usually store the
              bare location (europe-west2, EU) — so we prepend `region-` and
              lowercase unless the value already carries the prefix.
-#}
{% macro penny_jobs_relation() %}
    {%- set project = var('penny_bigquery_project', none) or target.project -%}
    {%- set region = var('penny_bigquery_region', none) or target.location -%}
    {%- if not region.lower().startswith('region-') -%}
        {%- set region = 'region-' ~ region.lower() -%}
    {%- endif -%}
    {{ return('`' ~ project ~ '`.`' ~ region ~ '`.INFORMATION_SCHEMA.JOBS') }}
{% endmacro %}
