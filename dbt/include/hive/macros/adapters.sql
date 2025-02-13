{#
# Copyright 2022 Cloudera Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#}

{% macro file_format_clause() %}
  {%- set file_format = config.get('file_format', validator=validation.any[basestring]) -%}
  {%- if file_format is not none %}
    stored as {{ file_format }}
  {%- endif %}
{%- endmacro -%}

{% macro location_clause() %}
  {%- set location_root = config.get('location_root', validator=validation.any[basestring]) -%}
  {%- set identifier = model['alias'] -%}
  {%- if location_root is not none %}
    location '{{ location_root }}/{{ identifier }}'
  {%- endif %}
{%- endmacro -%}

{% macro options_clause() -%}
  {%- set options = config.get('options') -%}
  {%- if options is not none %}
    options (
      {%- for option in options -%}
      {{ option }} "{{ options[option] }}" {% if not loop.last %}, {% endif %}
      {%- endfor %}
    )
  {%- endif %}
{%- endmacro -%}

{% macro comment_clause() %}
  {%- set raw_persist_docs = config.get('persist_docs', {}) -%}

  {%- if raw_persist_docs is mapping -%}
    {%- set raw_relation = raw_persist_docs.get('relation', false) -%}
      {%- if raw_relation -%}
      comment '{{ model.description | replace("'", "\\'") }}'
      {% endif %}
  {%- else -%}
    {{ exceptions.raise_compiler_error("Invalid value provided for 'persist_docs'. Expected dict but got value: " ~ raw_persist_docs) }}
  {% endif %}
{%- endmacro -%}

{% macro partition_cols(label, required=false) %}
  {%- set cols = config.get('partition_by', validator=validation.any[list, basestring]) -%}
  {%- if cols is not none %}
    {%- if cols is string -%}
      {%- set cols = [cols] -%}
    {%- endif -%}
    {{ label }} (
    {%- for item in cols -%}
      {{ item }}
      {%- if not loop.last -%},{%- endif -%}
    {%- endfor -%}
    )
  {%- endif %}
{%- endmacro -%}


{% macro clustered_cols(label, required=false) %}
  {%- set cols = config.get('clustered_by', validator=validation.any[list, basestring]) -%}
  {%- set buckets = config.get('buckets', validator=validation.any[int]) -%}
  {%- if (cols is not none) and (buckets is not none) %}
    {%- if cols is string -%}
      {%- set cols = [cols] -%}
    {%- endif -%}
    {{ label }} (
    {%- for item in cols -%}
      {{ item }}
      {%- if not loop.last -%},{%- endif -%}
    {%- endfor -%}
    ) into {{ buckets }} buckets
  {%- endif %}
{%- endmacro -%}

{% macro fetch_tbl_properties(relation) -%}
  {% call statement('list_properties', fetch_result=True) -%}
    SHOW TBLPROPERTIES {{ relation }}
  {% endcall %}
  {% do return(load_result('list_properties').table) %}
{%- endmacro %}


{% macro create_temporary_view(relation, sql) -%}
  --  We can't use temporary tables with `create ... as ()` syntax in Hive2
  -- create temporary view {{ relation.include(schema=false) }} as
  create temporary table {{ relation.include(schema=false) }} as
    {{ sql }}
{% endmacro %}


{% macro properties_clause(properties) %}
  {%- if properties is not none -%}
      TBLPROPERTIES (
          {%- for key, value in properties.items() -%}
            "{{ key }}" = "{{ value }}"
            {%- if not loop.last -%}{{ ',\n  ' }}{%- endif -%}
          {%- endfor -%}
      )
  {%- endif -%}
{%- endmacro -%}


{% macro hive__create_table_as(temporary, relation, sql) -%}
  {%- set _properties = config.get('properties') -%}
  {%- set is_external = config.get('external') -%}
  {%- set is_iceberg = config.get('is_iceberg') -%}

  {% if temporary -%}
    {{ create_temporary_view(relation, sql) }}
  {%- else -%}
    {% if config.get('file_format', validator=validation.any[basestring]) == 'delta' %}
      create or replace table {{ relation }}
    {% else %}
      create {% if is_external == true -%}external{%- endif %} table {{ relation }}
    {% endif %}
    {{ options_clause() }}
    {{ partition_cols(label="partitioned by") }}
    {{ clustered_cols(label="clustered by") }}
    {% if is_iceberg == true -%} STORED BY ICEBERG {%- endif %}
    {{ file_format_clause() }}
    {{ location_clause() }}
    {{ comment_clause() }}
    {{ properties_clause(_properties) }}
    as
      {{ sql }}
  {%- endif %}
{%- endmacro -%}


{% macro hive__create_view_as(relation, sql) -%}
  create or replace view {{ relation }}
  {{ comment_clause() }}
  as
    {{ sql }}
{% endmacro %}

{% macro hive__create_schema(relation) -%}
  {%- call statement('create_schema') -%}
    create schema if not exists {{relation}}
  {% endcall %}
{% endmacro %}

{% macro hive__drop_schema(relation) -%}
  {%- call statement('drop_schema') -%}
    drop schema if exists {{ relation }} cascade
  {%- endcall -%}
{% endmacro %}

{# use describe extended for more information #}
{% macro hive__get_columns_in_relation(relation) -%}
  {%- set target_relation = adapter.get_relation(
      database=relation.database,
      schema=relation.schema,
      identifier=relation.name) 
  -%}
  {%- set table_exists=target_relation is not none -%}

  {%- if table_exists %}
  {% call statement('get_columns_in_relation', fetch_result=True) %}
    describe formatted {{ relation }}
  {% endcall %}
  {% do return(load_result('get_columns_in_relation').table) %}
  {%- endif -%}
{% endmacro %}

{% macro hive__list_relations_without_caching(relation) %}
  {% call statement('list_relations_without_caching', fetch_result=True) -%}
    show table extended in {{ relation }} like '*'
  {% endcall %}

  {% do return(load_result('list_relations_without_caching').table) %}
{% endmacro %}

{% macro hive__list_schemas(database) -%}
  {% call statement('list_schemas', fetch_result=True, auto_begin=False) %}
    show databases
  {% endcall %}
  {{ return(load_result('list_schemas').table) }}
{% endmacro %}

{% macro hive__rename_relation(from_relation, to_relation) -%}
  {% call statement('rename_relation') -%}
    {% if not from_relation.type %}
      {% do exceptions.raise_database_error("Cannot rename a relation with a blank type: " ~ from_relation.identifier) %}
    {% elif from_relation.type in ('table') %}
        alter table {{ from_relation }} rename to {{ to_relation }}
    {% elif from_relation.type == 'view' %}
        alter view {{ from_relation }} rename to {{ to_relation }}
    {% else %}
      {% do exceptions.raise_database_error("Unknown type '" ~ from_relation.type ~ "' for relation: " ~ from_relation.identifier) %}
    {% endif %}
  {%- endcall %}
{% endmacro %}

{% macro hive__drop_relation(relation) -%}
  {% call statement('drop_relation_if_exists_table') %}
    drop table if exists {{ relation }}
  {% endcall %}
  {% call statement('drop_relation_if_exists_view') %}
    drop view if exists {{ relation }}
  {% endcall %}
{% endmacro %}


{% macro hive__generate_database_name(custom_database_name=none, node=none) -%}
  {% do return(None) %}
{%- endmacro %}

{% macro hive__persist_docs(relation, model, for_relation, for_columns) -%}
  {% if for_columns and config.persist_column_docs() and model.columns %}
    {% do alter_column_comment(relation, model.columns) %}
  {% endif %}
{% endmacro %}

{% macro hive__alter_column_comment(relation, column_dict) %}
  {% if config.get('file_format', validator=validation.any[basestring]) == 'delta' %}
    {% for column_name in column_dict %}
      {% set comment = column_dict[column_name]['description'] %}
      {% set escaped_comment = comment | replace('\'', '\\\'') %}
      {% set comment_query %}
        alter table {{ relation }} change column 
            {{ adapter.quote(column_name) if column_dict[column_name]['quote'] else column_name }}
            comment '{{ escaped_comment }}';
      {% endset %}
      {% do run_query(comment_query) %}
    {% endfor %}
  {% endif %}
{% endmacro %}

{% macro hive__list_tables_without_caching(schema) %}
  {% call statement('list_tables_without_caching', fetch_result=True) -%}
    show tables in {{ schema }}
  {% endcall %}
  {% do return(load_result('list_tables_without_caching').table) %}
{% endmacro %}

{% macro hive__list_views_without_caching(schema) %}
  {% call statement('list_views_without_caching', fetch_result=True) -%}
    -- show views  in {{ schema }}
    show tables  in {{ schema }} like 'v_*'
    -- show tables  in {{ relation }}
    -- hive2 has no `show view` command
  {% endcall %}
  {% do return(load_result('list_views_without_caching').table) %}
{% endmacro %}

{% macro get_hive_version() %}
  {% do return('1') %}
{% endmacro %}
