{#-
    penny_optional_columns — read columns that only some JOBS views have.

    `INFORMATION_SCHEMA.JOBS` is not one fixed shape. Columns come and go by
    region and by BigQuery edition, and referencing one that is absent does not
    degrade: it fails the model outright with

        Unrecognized name: <column>

    That is how v0.1.6 shipped broken. It read `ddl_target_table`, which the US
    multi-region does not have, so the first model failed and every downstream
    model was skipped. v0.1.9 fixed it by deleting the column, which is safe but
    leaves Penny reading only the columns every region has.

    This macro is the general answer. Each optional column sits behind a var,
    off by default, so:

      - nobody gets a hard failure from a column their region lacks
      - a reader whose region or edition does have it can switch it on

    The output schema is the same either way. A disabled column is emitted as a
    typed null under the same alias, so `on_schema_change: sync_all_columns`
    keeps existing tables in step and downstream models need no conditionals.

    Defaults are off rather than on deliberately. On would be friendlier where
    the column exists and a hard failure everywhere else, which is the behaviour
    this macro exists to remove.

    One honest limit: enabling a column your view does not have still fails at
    execution, because nothing can know the view's shape until the query runs.
    What this macro does is make that opt-in rather than the default, and name
    the responsible var in a comment directly above the column so the compiled
    SQL says which var to turn off. CLAUDE.md requires a BigQuery dry run for any
    change to the columns read from JOBS; that dry run is how you check a column
    before enabling it in anger.
-#}

{#- The guarded columns. `expr` is read from the JOBS view when enabled;
    `null_type` is the BigQuery type the alias takes when disabled, and must
    match the type of `expr` or the two branches produce different schemas. -#}
{% macro penny_optional_column_specs() %}
    {{ return([
        {
            'name': 'total_services_sku_slot_ms',
            'var': 'penny_enable_total_services_sku_slot_ms',
            'expr': 'total_services_sku_slot_ms',
            'null_type': 'int64',
            'note': 'Slot time billed through services SKUs. Editions only.'
        },
        {
            'name': 'reservation_group_path',
            'var': 'penny_enable_reservation_group_path',
            'expr': "array_to_string(reservation_group_path, '/')",
            'null_type': 'string',
            'note': 'Reservation group the job ran in, flattened to a path string.'
        },
        {
            'name': 'principal_subject',
            'var': 'penny_enable_principal_subject',
            'expr': 'principal_subject',
            'null_type': 'string',
            'note': 'Full principal identity, more precise than user_email for service accounts.'
        },
        {
            'name': 'edition',
            'var': 'penny_enable_edition',
            'expr': 'edition',
            'null_type': 'string',
            'note': 'STANDARD / ENTERPRISE / ENTERPRISE_PLUS, where the view reports it.'
        }
    ]) }}
{% endmacro %}


{#-
    Returns the select-list fragment for the source CTE, one line per guarded
    column, each already aliased. It carries no trailing comma, so it goes last
    in a select list, after a line that ends in one.
-#}
{% macro penny_optional_columns() %}
    {%- set lines = [] -%}
    {%- for spec in penny.penny_optional_column_specs() -%}
        {%- if var(spec['var'], false) -%}
            {%- do lines.append(
                "        -- " ~ spec['note'] ~ " Enabled by " ~ spec['var'] ~ "; set it to false if this column is not in your region's JOBS view.\n"
                ~ "        " ~ spec['expr'] ~ " as " ~ spec['name']
            ) -%}
        {%- else -%}
            {%- do lines.append(
                "        -- Not read. Enable with " ~ spec['var'] ~ ": " ~ spec['note'] ~ "\n"
                ~ "        cast(null as " ~ spec['null_type'] ~ ") as " ~ spec['name']
            ) -%}
        {%- endif -%}
    {%- endfor -%}
    {{- lines | join(',\n') -}}
{% endmacro %}


{#-
    Returns the same column names as a plain pass-through list, for the CTEs
    downstream of the source that only need to carry them along. No trailing
    comma, so it goes last in a select list.
-#}
{% macro penny_optional_column_names(indent='        ') %}
    {%- set names = [] -%}
    {%- for spec in penny.penny_optional_column_specs() -%}
        {%- do names.append(indent ~ spec['name']) -%}
    {%- endfor -%}
    {{- names | join(',\n') -}}
{% endmacro %}
