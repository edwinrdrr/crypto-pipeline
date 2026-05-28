{#
  dbt-recommended `generate_schema_name` override.

  The DEFAULT dbt macro would build into "<target.schema>_<custom_schema>" when a model
  declares a custom schema (e.g. +schema: marketing). That's noisy across environments.

  This override applies a `+schema:` value AS-IS — but ONLY in prod. In dev/CI it falls
  back to target.schema (the dataset from profiles.yml, env-driven: per-PR `dbt_ci_pr_<n>`,
  staging, or `crypto_analytics_dev`). This is the dbt-documented pattern. dbt explicitly
  warns against the simpler "always use custom_schema_name" form: in dev/CI it would route
  every PR/developer to the SAME schema (e.g. `marketing`) and they'd overwrite each other.

  Our project doesn't currently set `+schema:` on any model — so functionally this resolves
  to `target.schema` everywhere, same as the default. The macro is here to keep us safe IF
  a model later adds `+schema:` — in dev it stays isolated; in prod it's used as written.
#}
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- set default_schema = target.schema -%}
    {%- if target.name == 'prod' and custom_schema_name is not none -%}
        {{ custom_schema_name | trim }}
    {%- else -%}
        {{ default_schema }}
    {%- endif -%}
{%- endmacro %}
