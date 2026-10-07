{{ config(materialized='table') }}

{#-
    One row per model per day. Daily cost/usage aggregates from
    int_penny_model_runs, plus a trailing 30-day average (excluding the current
    day) used as the anomaly baseline. A day is flagged as an anomaly when its
    cost exceeds penny_anomaly_threshold times that rolling average.

    total_jobs counts BigQuery jobs, not model runs. A model's pre-hooks and
    post-hooks are separate jobs carrying the same model label, so total_jobs is
    usually greater than 1 even for a single build. build_jobs / hook_jobs and
    build_cost_usd / hook_cost_usd split those apart (see penny.penny_job_role).

    The rolling window orders by unix_date(run_date) and uses a numeric RANGE
    frame so calendar gaps are handled correctly (BigQuery RANGE frames require
    a numeric ordering expression).
-#}

with model_runs as (

    select * from {{ ref('int_penny_model_runs') }}

),

daily as (

    select
        run_date,
        model_name,
        methodology_layer,
        count(*) as total_jobs,
        countif(job_role = 'build') as build_jobs,
        countif(job_role = 'hook') as hook_jobs,
        round(sum(cost_usd), 6) as total_cost_usd,
        round(sum(if(job_role = 'build', cost_usd, 0)), 6) as build_cost_usd,
        round(sum(if(job_role = 'hook', cost_usd, 0)), 6) as hook_cost_usd,
        round(avg(cost_usd), 6) as avg_cost_per_job_usd,
        round(max(cost_usd), 6) as max_cost_per_job_usd,
        round(sum(gb_billed), 4) as total_gb_billed,
        round(avg(execution_time_seconds), 2) as avg_execution_seconds,
        countif(cache_hit) as cache_hits
    from model_runs
    group by 1, 2, 3

),

with_rolling as (

    select
        daily.*,
        round(
            avg(total_cost_usd) over (
                partition by model_name
                order by unix_date(run_date)
                range between 30 preceding and 1 preceding
            ),
            6
        ) as rolling_30d_avg_cost_usd
    from daily

),

final as (

    select
        run_date,
        model_name,
        methodology_layer,
        total_jobs,
        build_jobs,
        hook_jobs,
        total_cost_usd,
        build_cost_usd,
        hook_cost_usd,
        avg_cost_per_job_usd,
        max_cost_per_job_usd,
        total_gb_billed,
        avg_execution_seconds,
        cache_hits,
        rolling_30d_avg_cost_usd,
        coalesce(
            rolling_30d_avg_cost_usd > 0
            and total_cost_usd > rolling_30d_avg_cost_usd * {{ var('penny_anomaly_threshold', 3) }},
            false
        ) as is_cost_anomaly
    from with_rolling

)

select
    run_date,
    model_name,
    methodology_layer,
    total_jobs,
    build_jobs,
    hook_jobs,
    total_cost_usd,
    build_cost_usd,
    hook_cost_usd,
    avg_cost_per_job_usd,
    max_cost_per_job_usd,
    total_gb_billed,
    avg_execution_seconds,
    cache_hits,
    rolling_30d_avg_cost_usd,
    is_cost_anomaly
from final
