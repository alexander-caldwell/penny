---
title: How Penny works
description: What Penny reads, how a job is traced to a model, and how cost is worked out
---

Penny is a dbt package that tells you what each of your dbt models costs to run
on BigQuery — per model, per day, with trends and anomalies — and prints a cost
summary to the console after every run.

## The core idea

BigQuery already records the cost of every query it runs. Penny doesn't measure
anything new or add overhead — it reads that record, attributes each query back
to the dbt model that caused it, and turns bytes into dollars. All the raw data
is sitting in BigQuery's metadata; Penny just makes it about *models* instead of
*jobs*.

## What it reads

Penny reads one source: `INFORMATION_SCHEMA.JOBS` — BigQuery's built-in log of
every query job, scoped to your project and region (e.g.
`` `your-project`.`region-eu`.INFORMATION_SCHEMA.JOBS ``). Per job it takes:

- **`total_bytes_billed`** — bytes you're charged for (the basis of on-demand cost)
- **`total_slot_ms`** — slot-milliseconds used (the basis of reserved/editions cost)
- **`reservation_id`** — which reservation the job ran in, or null for on-demand
- **timing, `cache_hit`, `error_result`, `destination_table`, `user_email`**
- **job labels** — how a job is tied back to a dbt model (below)

It only looks at completed dbt query jobs (it filters out scripts, non-query
jobs, and — by default — anything without a dbt invocation label).

## How it knows which model a job belongs to

BigQuery jobs carry **labels**. dbt always stamps a `dbt_invocation_id` (which
run a job came from). To attribute cost to an individual *model*, the job also
needs the model's identity in a label. Penny reads that in order of preference:

1. **`dbt_model_name`** — a clean model-name label, if you've configured one
2. **`node_id`** — the standard label dbt emits when you turn on job-labelling;
   Penny reads it as a fallback and strips it back to a model name
3. **target table** — the table the job wrote to, if there's no label
4. **`'unknown'`** — for jobs that write nowhere (introspection queries)

BigQuery's own anonymous result tables (`anon<hex>`) are skipped at step 3.
Every query without an explicit destination writes to one, so counting them
would turn each test and introspective select into a one-off "model".

So Penny works with zero label setup (attributing by table name), and gets
sharper the more identity you give it. It also folds dbt's incremental temp
tables (`…__dbt_tmp`) back into the model they belong to.

Penny's own query-comment hook adds a fourth label, `dbt_project_name`, naming
the dbt project that ran the job. It is not used for model identity; it backs
the optional filter that narrows the report to one project when several dbt
projects share a BigQuery project.

One thing to know about labels: BigQuery does not allow full stops in label
values, so dbt's node id `model.my_project.my_model` is stored as
`model_my_project_my_model`. Anything reading that label has to account for it.

## Why one model is many jobs

dbt renders the query comment (and so the labels) once per node. Every pre-hook
and post-hook statement therefore carries the **same model label** as the
model's own build statement. One model with twelve hooks creates thirteen
labelled jobs.

Penny tags each job with a `job_role` so the two never get confused:

- **`build`** — wrote the model's own table, temp `__dbt_tmp` builds included
- **`hook`** — ran in the model's context but wrote something else, or nothing
- **`overhead`** — belongs to no model at all

Model counts come from dbt's own record of what it ran. Job counts and cost come
from BigQuery. Hooks cost real money, so Penny reports their share rather than
hiding it.

## How it turns bytes into dollars

Two pricing formulas, picked **per job**:

- **On-demand** (job ran outside a reservation): `bytes_billed ÷ 1 TiB × price per TiB`
- **Slot-based** (job ran in a reservation): `slot_ms ÷ hour × price per slot-hour`

By default Penny decides per job using `reservation_id`, so a project that mixes
on-demand and reserved billing is costed correctly. Prices are configurable.

## What you get

Four layers, each one grain finer to coarser:

| Table | One row per | Tells you |
|-------|-------------|-----------|
| `stg_bigquery__job_history` | BigQuery job | the raw facts |
| `int_penny_model_runs` | BigQuery job | cost of every job, tagged build / hook / overhead |
| `rpt_penny_cost_summary` | model per day | daily cost, 30-day rolling average, anomaly flag |
| `rpt_penny_cost_by_layer` | layer per day | where spend concentrates (staging / integration / warehouse / analytics) |
| `rpt_penny_model_latest` | model | latest state, week-over-week trend, red/amber/green status |

Plus a **run summary** printed to the console after each `dbt run` — models run,
queries executed, total billed, estimated cost split into builds and hooks, and
the single most expensive model — scoped to just that run.

## Worth knowing

- **Gross cost.** The BigQuery 1 TB/month free tier is account-level, so Penny
  reports gross cost, not your net invoice.
- **Reserved cost is an allocation.** Flat-rate reservations bill a fixed amount
  regardless of usage; Penny apportions it by slot-time consumed.
- **BigQuery keeps job history for 180 days.** Penny's tables persist beyond
  that, so running it regularly (daily) is how you keep cost history longer than
  the source window — and how the trend and anomaly signals stay meaningful.
