---
title: Penny
description: Model-level BigQuery cost tracking for dbt
---

Penny tells you what each dbt model costs to run on BigQuery. Cost per model,
per day, with trends and anomaly flags, plus a summary printed to the console
after every run.

It reads BigQuery's own record of every query it ran, attributes each query back
to the dbt model that caused it, and turns bytes into dollars. Nothing is
measured twice and nothing is added to your runs.

BigQuery only. Requires dbt 1.10.5 or later.

## Install

Add Penny to `packages.yml` in your dbt project:

```yaml
packages:
  - git: "https://github.com/alexander-caldwell/penny.git"
    revision: v0.1.10
```

Label your jobs so cost can be traced to a model, in `dbt_project.yml`. This is
configuration only: it changes no SQL and no data.

```yaml
query-comment:
  comment: "{{ penny.penny_query_comment(node) }}"
  job-label: true

on-run-end:
  - "{{ penny.log_run_costs() }}"
```

Then build:

```bash
dbt deps
dbt build --select penny
```

## What you get

Five tables, from raw jobs up to a per-model summary:

| Table | One row per | Tells you |
|-------|-------------|-----------|
| `stg_bigquery__job_history` | BigQuery job | the raw facts |
| `int_penny_model_runs` | BigQuery job | cost per job, tagged build, hook or overhead |
| `rpt_penny_cost_summary` | model per day | daily cost, 30-day rolling average, anomaly flag |
| `rpt_penny_cost_by_layer` | layer per day | where spend concentrates |
| `rpt_penny_model_latest` | model | latest state, weekly trend, red/amber/green |

And a summary after each run:

```
═══════════════════════════════════════════
  🪙  Penny — Run Summary
═══════════════════════════════════════════
  Models run:        5
  Queries executed:  40 (5 build, 35 hook, 0 overhead)
  Total TB billed:   0.0004 TB
  Estimated cost:    $0.002283 USD
    builds:          $0.000376
    hooks:           $0.001907
    overhead:        $0.0
  Largest model:     0.02 GB (stg_bigquery__job_history)
═══════════════════════════════════════════
```

## How it costs a job

Two formulas, chosen per job:

- **On-demand**, when the job ran outside a reservation: bytes billed, divided by
  one tebibyte, times your price per tebibyte.
- **Slot-based**, when it ran inside one: slot milliseconds, converted to hours,
  times your price per slot-hour.

Choosing per job means a project that mixes both billing types is still costed
correctly. Prices come from your configuration, not from the warehouse, so set
them to your contracted rate.

Penny reports gross cost. BigQuery's free tier is account-level, so it cannot be
netted out per model.

## Read next

- [How Penny works](how-penny-works.html) — the mechanism in full: what it
  reads, how a job is traced to a model, why one model is many jobs.
- [README on GitHub](https://github.com/alexander-caldwell/penny#readme) —
  every configuration variable, column reference, and troubleshooting.

## Licence

MIT. Built by [Rittman Analytics](https://rittmananalytics.com).
