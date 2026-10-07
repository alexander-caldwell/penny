# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Penny is a **dbt package**, not a standalone dbt project. It reads BigQuery's
`INFORMATION_SCHEMA.JOBS`, attributes each job's cost to the dbt model that ran
it, and exposes daily trends plus a console run summary. BigQuery only.

`dbt_project.yml` has no `profile:` key, so this repo cannot be built on its own.
To exercise it against a warehouse, install it into a consumer dbt project via
`packages.yml` and run `dbt build --select penny` there.

Requires dbt 1.10.5 or later (the `arguments:` test property), upper bound
`<3.0.0` so the Fusion engine, which reports as v2, does not flag Penny as
incompatible. Fusion itself is untested.

## Commands

```bash
dbt deps                                  # in the consumer project
dbt build --select penny                  # seed + models + tests
dbt run  --select penny --full-refresh    # re-read penny_lookback_days of history
dbt test --select penny                   # tests only
dbt test --select stg_bigquery__job_history   # one model's tests

uvx dbt-autofix deprecations --dry-run    # dbt deprecation check
uvx dbt-autofix packages --dry-run        # Fusion package compatibility check
```

There is no Python test suite and no CI. Always dry-run `dbt-autofix` first: it
rewrites files, and it has a habit of stripping explicit `null` values out of
`vars` and appending blocks without a trailing newline.

### Validating changes without a warehouse

Because there is no profile here, SQL and Jinja changes cannot be compiled
locally. Render the macros through plain Jinja2 and parse the output with
sqlglot in the `bigquery` dialect. Stub `var`, `target`, `ref`, `config`,
`is_incremental`, and a `penny` object whose attributes are the macro module's;
`penny_build_statement_types` needs a Python override because it uses dbt's
`return()`. Check models in both incremental and full-refresh modes.

For the `on-run-end` hook, extract the `{% set query %}` and `{% set summary %}`
blocks by regex and render them separately. The summary block's whitespace is
load-bearing, so inspect the rendered console output rather than assuming.

sqlglot only checks that the SQL parses. It cannot know which columns
`INFORMATION_SCHEMA.JOBS` actually has, and that view differs by region: it has
no `ddl_target_table` in the US multi-region, which once shipped a release that
failed on the first model with `Unrecognized name: ddl_target_table`. Any change
touching the columns read from `JOBS` must also be dry-run against BigQuery,
which costs nothing and resolves every name.

## Architecture

### Data flow

```
INFORMATION_SCHEMA.JOBS
  → stg_bigquery__job_history    incremental, insert_overwrite on created_at day
  → int_penny_model_runs         incremental, adds cost + layer + job_role
  → rpt_penny_cost_summary       table, model per day, rolling avg + anomaly flag
      → rpt_penny_cost_by_layer  table, layer per day
      → rpt_penny_model_latest   table, model, latest state + trend
```

The three `rpt_` models rebuild fully each run from the incremental base.

### The central invariant: shared macros

The `on-run-end` console summary queries `INFORMATION_SCHEMA.JOBS` directly
rather than reading Penny's own tables, because the tables have not been built
yet when the hook fires. That means the same logic exists in two places, so
**every piece of shared logic must live in a macro that both call**, or the
console figure and the warehouse figure will silently disagree:

| Macro | Owns |
|---|---|
| `get_cost_usd` | The cost formula and the `auto` / `on_demand` / `editions` mode switch |
| `penny_model_name` | The label fallback chain and the `__dbt_tmp` fold |
| `penny_job_role` | The `build` / `hook` / `overhead` classification |
| `penny_jobs_relation` | The `project`.`region-xxx` path, including the `region-` prefix rule |
| `penny_node_types` | The dbt resource types that can prefix a sanitised node id |
| `penny_project_filter` | The `penny_dbt_project_filter` match: label first, node-id prefix as fallback |

These return SQL expression **strings**, and take column names as arguments. If
you add logic to `int_penny_model_runs` that the hook also needs, extract it to a
macro rather than duplicating it.

### One model is many jobs

dbt renders the query comment, and therefore the job labels, once per node. Every
pre-hook and post-hook statement carries the **same** `dbt_model_name` label as
the model's build statement, so counting jobs overstates models run: one model
with twelve hooks looks like thirteen.

`job_role` on `int_penny_model_runs` splits these. A job is `build` when its
`statement_type` writes data or DDL **and** its target table, with `__dbt_tmp`
stripped, matches the resolved model name. `overhead` means no model could be
resolved at all.

Consequences to respect:

- `count(*)` on `int_penny_model_runs` counts jobs. Use `count(distinct model_name)`
  or filter `job_role = 'build'` for models.
- Columns named `total_jobs` mean jobs. There is deliberately no `total_runs`
  column anywhere; it was renamed because it was misleading.
- The console summary takes its model count from dbt's own `results` list, not
  from job labels, because dbt knows the true answer.

### Model attribution and its fallbacks

Penny works with zero label configuration and gets sharper as more identity is
provided. `penny_model_name` resolves, in order: the `dbt_model_name` label, then
the `node_id` label with its `model_<project>_` prefix stripped (set
`penny_dbt_project_name` to enable that stripping), then the job's target table,
then `'unknown'`.

The target-table step skips BigQuery's anonymous result tables, matched on
`^anon[0-9a-f]`. BigQuery writes every destination-less query result to one, so
without the skip each test and introspective select became its own one-off
model: a 20-model project reported 320. Those jobs resolve to `'unknown'` and
`penny_job_role` calls them overhead.

Three traps here:

- `models: +labels: {dbt_model_name: "{{ this.name }}"}` in `dbt_project.yml`
  **fails**. That file is rendered with no model context, so `this` is undefined
  and `dbt deps` errors. The `query-comment` hook works because it is rendered
  per node with `node` in scope. This is why `penny_query_comment` exists.
- With no labels at all, the model name falls back to the target table, which
  makes a post-hook writing elsewhere look like a build of its own model.
  `penny_job_role` documents this limit; do not try to fix it in SQL.
- The project filter (`penny_dbt_project_filter`) means the **root** dbt project,
  the one that ran dbt, not the package a model is defined in. Penny's own models
  therefore count as part of the consumer's project. `penny_query_comment` stamps
  that as `dbt_project_name`; `penny_project_filter` falls back to prefix-matching
  the sanitised node id when the label is absent.

### The on-run-end hook is not registered here

`dbt_project.yml` deliberately omits `on-run-end`. dbt fires `on-run-end` hooks
from installed packages as well as the root project, so registering it here would
double-fire alongside the consumer's own registration. Consumers register
`"{{ penny.log_run_costs() }}"` themselves.

`log_run_costs` is the only place Penny reads dbt internals rather than BigQuery
metadata, and Fusion has known parity gaps in the `results` object. Every field
is probed with `is defined` before use and nothing is chained off a possibly
undefined value, so an unfamiliar result shape yields an empty count and falls
back to job labels rather than aborting the run. Keep it that way.

### Pricing

Prices come from `vars` (`penny_price_per_tb`, `penny_price_per_slot_hour`), not
from the warehouse. The `penny_bigquery_pricing` seed is a **reference table that
nothing reads** — it documents published BigQuery rates for humans. Changing it
changes no output.

`auto` mode prices each job by whether `reservation_id` is null, which is why
cost must be summed per job and never computed once for a whole run. The 1 TB
monthly free tier is not netted out; Penny reports gross cost.

### Methodology layers

`methodology_layer` is a `case` expression over the model-name prefix in
`int_penny_model_runs`, following the Rittman Analytics four layers. It matches
both `wh_`-style file prefixes and Kimball `_fact` / `_dim` **suffixes**, because
RA warehouse models are file-named `wh_*` but aliased to `partnerships_fact`, and
the alias is what appears in job metadata.

## Conventions

- Macros and models carry long `{#- ... -#}` header comments explaining why the
  code is shaped as it is, including known limits. Match that density; the
  comments are the design record.
- Every model has a paired `.yml` with column descriptions and tests. Update both
  together, and use the `arguments:` nesting for generic test arguments.
- Releases are tags `v0.1.x` with a commit message of the form
  `v0.1.5: <what changed>`. The install pin in the README's Quick start must be
  bumped to match the new tag in the same change.
- Renaming a published column is a breaking change for consumers. Call it out
  explicitly and update every downstream model and the README column tables.
