# 🪙 Penny — model-level cost tracking for dbt on BigQuery

Penny reads BigQuery job metadata, attributes the cost of every job to the dbt
model that ran it, and surfaces daily trends and anomalies. It also prints a
cost summary to the console after every `dbt run`. Named for the idea that every
query costs something — and Penny watches every one.

Built for BigQuery, structured to extend to other warehouses later. Phase 1 (MVP).

---

## Quick start

Three steps. Project and region are read from your dbt target, so there's nothing
to configure for the common case.

```yaml
# 1. packages.yml
packages:
  - git: "https://github.com/alex-caldwell-RA/penny.git"
    revision: v0.1.5
```

```yaml
# 2. your dbt_project.yml — label every job with its model so Penny can tell them apart
query-comment:
  comment: "{{ penny.penny_query_comment(node) }}"
  job-label: true
```

```bash
# 3. install and build
dbt deps
dbt build --select penny
```

That's the whole setup. Everything below is optional — the console summary hook,
pointing at a different project, and the tuning variables all have working
defaults.

Skipping step 2 works too. Penny still runs and tracks cost; it just attributes
to the destination table name instead of the model name until labels are present.

> **Don't use `models: +labels: {dbt_model_name: "{{ this.name }}"}`.** dbt renders
> `dbt_project.yml` before any model context exists, so `this` is undefined and
> `dbt deps` fails with `'this' is undefined`. The `query-comment` hook above is
> rendered per-node with `node` in scope, so it works — and it captures the dbt
> node name (`wh_orders_fact`), not the aliased table name. See
> [labelling jobs](#labelling-jobs-so-cost-maps-to-models) for the per-model
> alternative.

---

## Contents

- [Quick start](#quick-start)
- [What you get](#what-you-get)
- [Setup in detail](#setup-in-detail)
- [Running Penny](#running-penny)
- [Using the outputs](#using-the-outputs) — the part you came for
- [How cost is calculated](#how-cost-is-calculated)
- [Methodology layers](#methodology-layers)
- [Incremental behaviour](#incremental-behaviour)
- [Configuration reference](#configuration-reference)
- [Troubleshooting](#troubleshooting)

---

## What you get

| Layer | Model | Grain | Use it for |
|-------|-------|-------|------------|
| staging | `stg_bigquery__job_history` | one row per BigQuery job | raw job facts, debugging |
| integration | `int_penny_model_runs` | one row per model execution, costed | per-run drill-down |
| analytics | `rpt_penny_cost_summary` | one row per model per day | trends + anomaly flags |
| analytics | `rpt_penny_cost_by_layer` | one row per layer per day | where spend concentrates |
| analytics | `rpt_penny_model_latest` | one row per model | dashboards, IDE tooling |

Plus an `on-run-end` macro that prints a per-run cost summary, and a
`penny_bigquery_pricing` seed for reference.

All Penny objects land in one dataset. With dbt's default custom-schema
behaviour the dataset name is your target schema suffixed with `penny` — for
example `analytics_penny`. Confirm yours with `dbt run --select penny` and check
the logged relation names. The examples below write it as `penny`; substitute
your actual dataset.

---

## Setup in detail

The [quick start](#quick-start) covers the whole required path. This section
explains the pieces and the optional extras.

### Required: install Penny

Install via `packages.yml` and `dbt deps` (step 1). Penny depends on `dbt_utils`
for its freshness and uniqueness tests — if your project already includes it, dbt
deduplicates automatically.

### Labelling jobs so cost maps to models

By default dbt stamps BigQuery jobs only with `dbt_invocation_id`, so Penny can
total a run but not split it by model. To attribute per model, the jobs need
model identity in their labels. Three ways, depending on what you already have.

**Already using `query-comment: job-label: true`? Nothing to do.** dbt's default
query comment stamps a `node_id` label on every job, and Penny reads it
automatically as a fallback — you get per-model grouping with zero config.
BigQuery sanitises that label to `model_<project>_<name>`, so for clean,
classifiable names set `penny_dbt_project_name` to your dbt project name and
Penny strips the `model_<project>_` prefix off. Leave it null and grouping still
works, the names are just prefixed.

If you're *not* already labelling jobs, two ways to start, depending on scope.

**Project-wide (recommended) — the query-comment hook.** Add to your
`dbt_project.yml`. It's config-only — no SQL, no schema, no data impact — and is
rendered per node, so it labels every model's job with the dbt node name:

```yaml
query-comment:
  comment: "{{ penny.penny_query_comment(node) }}"
  job-label: true
```

**Selective — a model `config()` block.** To label only some models (handy for a
first test), set labels in the model itself, where `this` is in scope:

```sql
{{ config(labels = {'dbt_model_name': this.name, 'dbt_node_id': this.identifier}) }}
```

Note `this.name` is the *aliased* table name (e.g. `partnerships_fact`), whereas
the query-comment hook captures the dbt node name (e.g. `wh_partnerships_fact`).
Penny classifies both correctly — see [methodology layers](#methodology-layers).

Either way, do **not** try `models: +labels: {dbt_model_name: "{{ this.name }}"}`
in `dbt_project.yml`. dbt renders that file with no model context, so `this` is
undefined and `dbt deps` fails.

Verify labels are landing after a run:

```sql
select job_id, label.key, label.value
from `your-project.region-EU.INFORMATION_SCHEMA.JOBS`,
  unnest(labels) as label
where label.key like 'dbt%'
order by creation_time desc
limit 20
```

### Optional: the run-summary console hook

To print the run summary after each `dbt run`, register the hook in your
project's `dbt_project.yml`. The `penny.` prefix is required — `on-run-end` only
fires for the root project, never an installed package:

```yaml
on-run-end:
  - "{{ penny.log_run_costs() }}"
```

### Optional: point at a different project or region

Penny reads `target.project` and `target.location` from your active dbt target by
default, so no config is needed when you want to track the project dbt is
connected to. To read a different one, set the vars:

```yaml
vars:
  penny_bigquery_project: "some-other-project"
  penny_bigquery_region: "region-US"
```

### Permissions

The dbt service account needs `bigquery.jobs.list` on the project to read
`INFORMATION_SCHEMA.JOBS`. The standard `BigQuery User` + `BigQuery Data Editor`
roles include it — most setups already have this.

---

## Running Penny

One command builds the seed, models, and tests together:

```bash
dbt build --select penny
```

With the [console hook](#optional-the-run-summary-console-hook) registered, any
`dbt run` in your project then prints:

```text
═══════════════════════════════════════════
  🪙 Penny — Run Summary
═══════════════════════════════════════════
  Models run:        47
  Total TB billed:   0.032 TB
  Estimated cost:    $0.20 USD
  Largest model:     1.8 GB (fct_orders)
═══════════════════════════════════════════
```

The first build reads `penny_lookback_days` of history (default 180). After
that, runs are incremental and only pick up new partitions, so they stay cheap.
A daily schedule keeps the reporting tables current.

---

## Using the outputs

This is where Penny earns its keep. Four tables answer four different questions.

### "What did this model cost lately, and is anything wrong right now?"

`rpt_penny_model_latest` — one row per model, built for dashboards and the future
IDE extension. A single cheap read gives the current state of every model.

```sql
-- Today's watch-list: models flagged red or amber, most expensive first
select
    model_name,
    methodology_layer,
    last_run_date,
    last_run_cost_usd,
    avg_cost_30d,
    trend_pct_7d,
    anomaly_status
from `penny.rpt_penny_model_latest`
where anomaly_status in ('red', 'amber')
order by last_run_cost_usd desc
```

```sql
-- Fastest-growing models week over week
select model_name, trend_pct_7d, total_cost_30d
from `penny.rpt_penny_model_latest`
where trend_pct_7d is not null
order by trend_pct_7d desc
limit 20
```

`anomaly_status` is a traffic light: **red** if the latest day tripped the
anomaly threshold, **amber** if the last run was more than 1.5× the 30-day
average, **green** otherwise.

### "How has this model trended day by day?"

`rpt_penny_cost_summary` — one row per model per day, with a trailing 30-day
average and the anomaly flag. This is the table to chart.

```sql
-- A single model's daily cost vs its rolling baseline
select
    run_date,
    total_cost_usd,
    rolling_30d_avg_cost_usd,
    is_cost_anomaly
from `penny.rpt_penny_cost_summary`
where model_name = 'fct_orders'
order by run_date desc
limit 60
```

```sql
-- Every anomaly in the last 30 days, worst first
select run_date, model_name, total_cost_usd, rolling_30d_avg_cost_usd
from `penny.rpt_penny_cost_summary`
where is_cost_anomaly
  and run_date >= date_sub(current_date(), interval 30 day)
order by total_cost_usd desc
```

### "Where is the spend concentrated?"

`rpt_penny_cost_by_layer` — one row per methodology layer per day. Good for the
"are we spending most of our budget in staging or in analytics?" conversation.

```sql
-- Last 7 days of cost split by layer
select
    methodology_layer,
    round(sum(total_cost_usd), 2) as cost_usd,
    sum(total_executions) as executions
from `penny.rpt_penny_cost_by_layer`
where run_date >= date_sub(current_date(), interval 7 day)
group by methodology_layer
order by cost_usd desc
```

### "Why was that day so expensive — which run did it?"

`int_penny_model_runs` — one row per execution, fully costed. Drop down here when
a daily figure looks wrong and you need the individual jobs behind it.

```sql
-- The 20 most expensive individual runs in the last week
select
    run_date,
    model_name,
    cost_usd,
    gb_billed,
    execution_time_seconds,
    cache_hit,
    is_error
from `penny.int_penny_model_runs`
where run_date >= date_sub(current_date(), interval 7 day)
order by cost_usd desc
limit 20
```

### Column reference

<details>
<summary><code>rpt_penny_model_latest</code> (one row per model)</summary>

| Column | Meaning |
|--------|---------|
| `model_name` | Model identity (label, or destination-table fallback) |
| `methodology_layer` | staging / integration / warehouse / analytics / unclassified |
| `last_run_date` | Most recent date the model ran |
| `last_run_cost_usd` | Cost on that most recent day |
| `avg_cost_30d` | Average daily cost over the last 30 days |
| `trend_pct_7d` | Week-over-week % change (last 7d vs prior 7d); null if no prior week |
| `anomaly_status` | `green` / `amber` / `red` |
| `total_cost_30d` | Total cost over the last 30 days |
| `total_runs_30d` | Total executions over the last 30 days |

</details>

<details>
<summary><code>rpt_penny_cost_summary</code> (one row per model per day)</summary>

| Column | Meaning |
|--------|---------|
| `run_date`, `model_name`, `methodology_layer` | Grain + classification |
| `total_runs` | Executions that day |
| `total_cost_usd` | Total cost that day |
| `avg_cost_per_run_usd` / `max_cost_per_run_usd` | Per-execution cost |
| `total_gb_billed` | GiB billed that day |
| `avg_execution_seconds` | Average wall-clock time |
| `cache_hits` | Cache-served executions |
| `rolling_30d_avg_cost_usd` | Trailing 30-day baseline (excludes current day) |
| `is_cost_anomaly` | `total_cost_usd` > threshold × rolling average |

</details>

<details>
<summary><code>rpt_penny_cost_by_layer</code> (one row per layer per day)</summary>

| Column | Meaning |
|--------|---------|
| `run_date`, `methodology_layer` | Grain |
| `models_run` | Distinct models in the layer that day |
| `total_executions` | Executions across the layer |
| `total_cost_usd` / `total_gb_billed` | Layer totals |
| `avg_execution_seconds` | Average per-model execution time |

</details>

<details>
<summary><code>int_penny_model_runs</code> (one row per execution)</summary>

| Column | Meaning |
|--------|---------|
| `job_id` | BigQuery job id (grain) |
| `created_at` / `run_date` | Job timestamp / date |
| `model_name` / `dbt_node_id` | Model identity |
| `is_label_fallback` | True when `model_name` came from the destination table (no label) |
| `methodology_layer` | Layer classification |
| `cost_usd` | Estimated cost for this run |
| `gb_billed` / `tb_billed` | Size billed |
| `total_slot_ms` / `execution_time_seconds` | Slot + wall-clock usage |
| `cache_hit` / `is_error` | Cache served / failed |
| `pricing_model` | `on_demand` or `editions` (per-job in `auto` mode) |
| `reservation_id` | Reservation the job ran in, or null for on-demand |

</details>

---

## How cost is calculated

`get_cost_usd` is the single source of truth, shared by the integration model and
the run-summary macro, so the console figure and the warehouse figure can't drift.
Two formulas:

- **on-demand** — `(total_bytes_billed / 1024^4) × penny_price_per_tb`
- **slot-based** — `(total_slot_ms / 1000 / 3600) × penny_price_per_slot_hour`

`penny_pricing_model` picks which applies:

| Mode | Behaviour |
|------|-----------|
| `auto` (default) | Per job — on-demand when the job's `reservation_id` is null, slot-based when it ran in a reservation. Correct for projects that **mix** on-demand and reserved billing (e.g. a reservation assigned to only some models). Resolves to the same answer as the fixed modes for pure on-demand or pure editions projects. |
| `on_demand` | Force the on-demand formula for every job |
| `editions` | Force the slot-based formula for every job |

A caveat on reserved jobs: flat-rate/commitment reservations bill a fixed amount
regardless of usage, so `slot_ms × rate` is an apportionment of that capacity by
consumption, not a marginal cost. Set `penny_price_per_slot_hour` to your
effective edition/commitment rate to make the allocation meaningful.

The BigQuery 1 TB/month free tier is account-level and is **not** netted out in
the MVP — Penny reports gross cost. Revisit as a monthly project-level adjustment
in a later phase.

---

## Methodology layers

`methodology_layer` is inferred from the model-name prefix, following the
Rittman Analytics four-layer architecture:

| Pattern | Layer |
|---------|-------|
| `stg_` prefix | staging |
| `int_` prefix | integration |
| `wh_` / `mart_` / `dim_` / `fct_` prefix, or `_fact` / `_dim` suffix | warehouse |
| `rpt_` / `mtr_` prefix | analytics |
| anything else | unclassified |

The `_fact` / `_dim` suffix rules matter because RA warehouse models are
file-named `wh_*` but aliased to Kimball table names like `partnerships_fact`
and `companies_dim` — and the alias is what Penny sees in job metadata.

If your project uses different prefixes, models land in `unclassified` — adjust
the `case` expression in `int_penny_model_runs` to match your conventions.

---

## Incremental behaviour

`stg_bigquery__job_history` and `int_penny_model_runs` are incremental with
BigQuery `insert_overwrite` on the day partition of `created_at`. Incremental
runs read only partitions newer than the table's current max partition; a full
refresh re-reads the last `penny_lookback_days` days:

```bash
dbt run --select penny --full-refresh
```

The three `rpt_` models are tables, rebuilt each run from the incremental base.

---

## Configuration reference

All variables go under `vars:` in the consumer project's `dbt_project.yml`.

| Variable | Default | Purpose |
|----------|---------|---------|
| `penny_bigquery_project` | `target.project` | Project whose jobs are read; auto-detected from the dbt target |
| `penny_bigquery_region` | `target.location` | INFORMATION_SCHEMA location; auto-detected from the dbt target |
| `penny_pricing_model` | `auto` | `auto` (per-job by reservation), `on_demand`, or `editions` |
| `penny_price_per_tb` | `6.25` | USD per TiB billed (on-demand jobs) |
| `penny_price_per_slot_hour` | `0.04` | USD per slot-hour (reserved/editions jobs) |
| `penny_lookback_days` | `180` | First-build / full-refresh window |
| `penny_dbt_only` | `true` | Ingest dbt-labelled jobs only |
| `penny_dbt_project_filter` | `null` | Restrict to one dbt project name |
| `penny_dbt_project_name` | `null` | Your dbt project name; strips the `model_<project>_` prefix off the fallback `node_id` label for clean names |
| `penny_anomaly_threshold` | `3` | Flag daily cost > N× rolling 30-day average |

---

## Troubleshooting

**`dbt_model_name` is null everywhere.** The label config isn't in place yet —
see [the quick start](#quick-start), step 2. Until then Penny falls back to the
destination table name; rows where it did so are flagged with
`is_label_fallback = true` in `int_penny_model_runs`.

**No console summary after `dbt run`.** The hook is registered in the package's
own `dbt_project.yml` for standalone development only. Consumer projects must add
`"{{ penny.log_run_costs() }}"` to their own `on-run-end` — the `penny.` prefix
is required.

**`Access Denied` reading INFORMATION_SCHEMA.JOBS.** The service account lacks
`bigquery.jobs.list`. Grant `BigQuery User` on the project.

**Everything is `unclassified`.** Your model prefixes don't match the defaults —
see [methodology layers](#methodology-layers).

**Costs look too high or too low.** Check `penny_pricing_model` matches your
billing arrangement, and that `penny_price_per_tb` / `penny_price_per_slot_hour`
reflect your contracted rate rather than list price.

---

## Out of scope (later phases)

Dry-run estimation, dbt contract awareness, CI cost gates, Slack/email alerting,
LookML/dashboard layer, and the VS Code extension are not part of this MVP.

---

## License

MIT — see [LICENSE](LICENSE).
