{#-
    get_cost_usd — shared BigQuery cost formula.

    Returns an (unrounded) SQL expression computing cost in USD for a single job.
    Used by both int_penny_model_runs and the log_run_costs on-run-end macro so
    the two can never drift apart. Call sites apply round().

    Args:
        bytes_billed    SQL expression for total bytes billed (e.g. `total_bytes_billed`).
        slot_ms         SQL expression for total slot milliseconds (e.g. `total_slot_ms`).
        reservation_id  SQL expression for the job's reservation id (e.g.
                        `reservation_id`). Only used in 'auto' mode. Pass none to
                        skip per-job detection.

    Pricing mode is read from the `penny_pricing_model` var:
        on_demand  -> always (bytes_billed / 1024^4) * penny_price_per_tb
        editions   -> always (slot_ms / 1000 / 3600) * penny_price_per_slot_hour
        auto       -> per job: on-demand when reservation_id is null, otherwise
                      slot-based. This is the correct choice for projects that mix
                      on-demand and reserved/editions billing (e.g. a BigQuery
                      reservation assigned to only some models). For pure
                      on-demand or pure editions projects it resolves to the same
                      result as the fixed modes.

    Note on reserved jobs: slot-based cost is an estimate — flat-rate/commitment
    reservations bill a fixed amount regardless of usage, so slot_ms × rate is an
    apportionment of that capacity by consumption, not a marginal cost.
-#}
{% macro get_cost_usd(bytes_billed, slot_ms, reservation_id=none) %}
    {%- set mode = var('penny_pricing_model', 'auto') -%}
    {%- set price_per_tb = var('penny_price_per_tb', 6.25) -%}
    {%- set price_per_slot_hour = var('penny_price_per_slot_hour', 0.04) -%}
    {%- set on_demand_expr = '(coalesce(' ~ bytes_billed ~ ', 0) / power(1024, 4)) * ' ~ price_per_tb -%}
    {%- set editions_expr = '(coalesce(' ~ slot_ms ~ ', 0) / 1000.0 / 3600.0) * ' ~ price_per_slot_hour -%}
    {%- if mode == 'on_demand' -%}
        {{ on_demand_expr }}
    {%- elif mode == 'editions' -%}
        {{ editions_expr }}
    {%- elif reservation_id is none -%}
        {#- auto, but no reservation_id available: assume on-demand. -#}
        {{ on_demand_expr }}
    {%- else -%}
        {#- auto: decide per job by whether it ran in a reservation. -#}
        case when {{ reservation_id }} is null then {{ on_demand_expr }} else {{ editions_expr }} end
    {%- endif -%}
{% endmacro %}
