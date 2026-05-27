{#
  Override dbt's default schema naming.

  By default dbt builds models into "<target_schema>_<custom_schema>", which is
  confusing for environment isolation. We instead use the schema AS-IS:

    - no custom schema set  -> use target.schema (the dataset from profiles.yml,
      which is env-driven: per-PR `dbt_ci_pr_<n>`, `crypto_analytics_staging`,
      or `crypto_analytics`)
    - custom schema set     -> use exactly that name (no prefix)

  This is what lets each PR build into its own throwaway dataset without
  colliding with shared dev / staging / prod.
#}
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is none -%}
        {{ target.schema }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
