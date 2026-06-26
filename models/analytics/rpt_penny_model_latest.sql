{{ config(materialized='table') }}

{#-
    One row per model, holding its latest state and recent trend. Designed for
    external tool consumption (a future IDE extension): a single cheap read
    gives last run, recent average, week-over-week trend, and a traffic-light
    anomaly status per model.

    Windows are anchored to current_date() so "last 30 / 7 days" stays intuitive
    even if Penny has not run today. anomaly_status:
      red   — the most recent day tripped the anomaly threshold
      amber — last run cost is materially above (>1.5x) the 30-day average
      green — otherwise
-#}

with cost_summary as (

    select * from {{ ref('rpt_penny_cost_summary') }}

),

last_run as (

    select
        model_name,
        methodology_layer,
        run_date as last_run_date,
        total_cost_usd as last_run_cost_usd,
        is_cost_anomaly as last_run_is_anomaly,
        row_number() over (partition by model_name order by run_date desc) as run_rank
    from cost_summary

),

windowed as (

    select
        model_name,
        round(avg(case when run_date >= date_sub(current_date(), interval 30 day) then total_cost_usd end), 6) as avg_cost_30d,
        round(sum(case when run_date >= date_sub(current_date(), interval 30 day) then total_cost_usd else 0 end), 6) as total_cost_30d,
        sum(case when run_date >= date_sub(current_date(), interval 30 day) then total_runs else 0 end) as total_runs_30d,
        sum(case when run_date >= date_sub(current_date(), interval 7 day) then total_cost_usd else 0 end) as cost_last_7d,
        sum(
            case
                when run_date >= date_sub(current_date(), interval 14 day)
                 and run_date < date_sub(current_date(), interval 7 day)
                then total_cost_usd
                else 0
            end
        ) as cost_prior_7d
    from cost_summary
    group by 1

),

final as (

    select
        last_run.model_name,
        last_run.methodology_layer,
        last_run.last_run_date,
        last_run.last_run_cost_usd,
        windowed.avg_cost_30d,
        windowed.total_cost_30d,
        windowed.total_runs_30d,
        case
            when windowed.cost_prior_7d is null or windowed.cost_prior_7d = 0 then null
            else round(((windowed.cost_last_7d - windowed.cost_prior_7d) / windowed.cost_prior_7d) * 100, 2)
        end as trend_pct_7d,
        case
            when last_run.last_run_is_anomaly then 'red'
            when windowed.avg_cost_30d > 0
             and last_run.last_run_cost_usd > windowed.avg_cost_30d * 1.5 then 'amber'
            else 'green'
        end as anomaly_status
    from last_run
    inner join windowed
        on last_run.model_name = windowed.model_name
    where last_run.run_rank = 1

)

select
    model_name,
    methodology_layer,
    last_run_date,
    last_run_cost_usd,
    avg_cost_30d,
    trend_pct_7d,
    anomaly_status,
    total_cost_30d,
    total_runs_30d
from final
