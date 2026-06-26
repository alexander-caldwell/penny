{{ config(materialized='table') }}

{#-
    One row per methodology layer per day. Rolls rpt_penny_cost_summary up from
    model grain to layer grain so cost can be tracked against the Rittman
    Analytics four-layer architecture.
-#}

with cost_summary as (

    select * from {{ ref('rpt_penny_cost_summary') }}

),

final as (

    select
        run_date,
        methodology_layer,
        count(distinct model_name) as models_run,
        sum(total_runs) as total_executions,
        round(sum(total_cost_usd), 6) as total_cost_usd,
        round(sum(total_gb_billed), 4) as total_gb_billed,
        round(avg(avg_execution_seconds), 2) as avg_execution_seconds
    from cost_summary
    group by 1, 2

)

select
    run_date,
    methodology_layer,
    models_run,
    total_executions,
    total_cost_usd,
    total_gb_billed,
    avg_execution_seconds
from final
