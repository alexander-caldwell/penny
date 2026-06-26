{#-
    get_cost_usd — shared BigQuery cost formula.

    Returns a SQL expression (string) that computes cost in USD. Used by both
    int_penny_model_runs and the log_run_costs on-run-end macro so the two can
    never drift apart.

    Args:
        bytes_billed  SQL expression for total bytes billed
                      (a column like `total_bytes_billed`, or an aggregate like
                      `sum(total_bytes_billed)`).
        slot_ms       SQL expression for total slot milliseconds
                      (e.g. `total_slot_ms` or `sum(total_slot_ms)`).

    Pricing mode is read from the `penny_pricing_model` var:
        on_demand  -> (bytes_billed / 1024^4) * penny_price_per_tb
        editions   -> (slot_ms / 1000 / 3600) * penny_price_per_slot_hour

    Cost is rounded to 6 decimal places to keep sub-cent precision without
    floating-point noise.
-#}
{% macro get_cost_usd(bytes_billed, slot_ms) %}
    {%- set pricing_model = var('penny_pricing_model', 'on_demand') -%}
    {%- if pricing_model == 'editions' -%}
        {%- set price_per_slot_hour = var('penny_price_per_slot_hour', 0.04) -%}
        round((coalesce({{ slot_ms }}, 0) / 1000.0 / 3600.0) * {{ price_per_slot_hour }}, 6)
    {%- else -%}
        {%- set price_per_tb = var('penny_price_per_tb', 6.25) -%}
        round((coalesce({{ bytes_billed }}, 0) / power(1024, 4)) * {{ price_per_tb }}, 6)
    {%- endif -%}
{% endmacro %}
