{% macro auto_generate_select(target_table_name,target_schema_name,source_table_name,source_schema_name,source_database_name,log_id_overwrite,pcr_create_update_date_overwrite,key_column,order_by_column) -%}

{% if key_column.strip() == "" and order_by_column.strip() == "" %}
    {% set qualify_stmt = '' %}
{% elif key_column.strip() != "" and order_by_column.strip() == "" %}
    {% set qualify_stmt = ' QUALIFY ROW_NUMBER() OVER (PARTITION BY '+ key_column + ' ORDER BY 0) =1 ' %}
{% else %}
    {% set qualify_stmt = ' QUALIFY ROW_NUMBER() OVER (PARTITION BY '+ key_column + ' ORDER BY '+ order_by_column + ') =1 ' %}
{% endif %}
{# Check if the LZ schmea table got columns with _ENCR#}

{% call statement('my_statement', fetch_result=True) %}
WITH src_encr_cnt as (
    SELECT COUNT(1) SRC_ENCR_COL_COUNT FROM {{ source_database_name }}.INFORMATION_SCHEMA.COLUMNS 
    WHERE TABLE_SCHEMA='{{ source_schema_name }}' AND TABLE_NAME='{{ source_table_name }}' AND UPPER(COLUMN_NAME) LIKE '%ENCR' 
),
tgt_encr_cnt as (
	SELECT COUNT(1) TGT_ENCR_COL_COUNT FROM INFORMATION_SCHEMA.COLUMNS 
	WHERE TABLE_SCHEMA='{{ target_schema_name }}' AND TABLE_NAME='{{ target_table_name }}' AND UPPER(COLUMN_NAME) LIKE '%ENCR' 
),
MISMATCH_COUNT AS (
SELECT COUNT(1) AS DIFF_COUNT 
FROM (
SELECT UPPER(COLUMN_NAME) AS TARGET_ENCR_COLUMN FROM INFORMATION_SCHEMA.COLUMNS 
	WHERE TABLE_SCHEMA='{{ target_schema_name }}' AND TABLE_NAME='{{ target_table_name }}' AND UPPER(COLUMN_NAME) LIKE '%ENCR'
MINUS
SELECT UPPER(COLUMN_NAME) AS TARGET_ENCR_COLUMN FROM {{ source_database_name }}.INFORMATION_SCHEMA.COLUMNS 
	WHERE TABLE_SCHEMA='{{ source_schema_name }}' AND TABLE_NAME='{{ source_table_name }}' AND UPPER(COLUMN_NAME) LIKE '%ENCR' 
    )
)
SELECT SRC_ENCR_COL_COUNT,TGT_ENCR_COL_COUNT,DIFF_COUNT
FROM src_encr_cnt 
JOIN tgt_encr_cnt 
ON 1=1
JOIN MISMATCH_COUNT
ON 1=1

{% endcall %}

{% if execute %}
    {% set results = load_result('my_statement')['data'] %}
    {% set lv_encr_in_src = results[0][0] %}
    {% set lv_encr_in_tgt = results[0][1] %}
    {% set lv_encr_missing_cnt = results[0][2] %}

{% else %}
    {% set lv_encr_in_src = [] %}
    {% set lv_encr_in_tgt = [] %}
    {% set lv_encr_missing_cnt = [] %}

{% endif %}

{# If Core table got columns with _ENCR and STG got non encrypted columns#}

{% if (lv_encr_in_src == 0 and lv_encr_in_tgt != 0) or ( lv_encr_missing_cnt != 0 )%}

	{% call statement('my_statement', fetch_result=True) %}
	
	WITH GET_TGT_COL_LIST AS (
	select COLUMN_NAME,
    DATA_TYPE|| CASE WHEN DATA_TYPE IN ('NUMBER', 'DECIMAL', 'NUMERIC') THEN '(' || NUMERIC_PRECISION || ',' || NUMERIC_SCALE || ')' WHEN DATA_TYPE IN ('VARCHAR', 'CHAR', 'TEXT', 'VARIANT') THEN '(' || CHARACTER_MAXIMUM_LENGTH || ')' WHEN DATA_TYPE IN ('TIMESTAMP', 'TIMESTAMP_NTZ', 'TIMESTAMP_LTZ', 'TIMESTAMP_TZ') THEN '(' || DATETIME_PRECISION || ')' ELSE '' END AS DATATYPE,
    ORDINAL_POSITION ,NUMERIC_PRECISION
    FROM INFORMATION_SCHEMA.COLUMNS 
	WHERE TABLE_SCHEMA='{{ target_schema_name }}' AND TABLE_NAME='{{ target_table_name }}' --AND UPPER(COLUMN_NAME) <> 'USGCI_IND' 
    ORDER BY ORDINAL_POSITION),
	GET_SRC_COL_LIST AS (
	select COLUMN_NAME,
    DATA_TYPE|| CASE WHEN DATA_TYPE IN ('NUMBER', 'DECIMAL', 'NUMERIC') THEN '(' || NUMERIC_PRECISION || ',' || NUMERIC_SCALE || ')' WHEN DATA_TYPE IN ('VARCHAR', 'CHAR', 'TEXT', 'VARIANT') THEN '(' || CHARACTER_MAXIMUM_LENGTH || ')' WHEN DATA_TYPE IN ('TIMESTAMP', 'TIMESTAMP_NTZ', 'TIMESTAMP_LTZ', 'TIMESTAMP_TZ') THEN '(' || DATETIME_PRECISION || ')' ELSE '' END AS DATATYPE,
    ORDINAL_POSITION 
    FROM INFORMATION_SCHEMA.COLUMNS 
	WHERE TABLE_SCHEMA='{{ source_schema_name }}' AND TABLE_NAME='{{ source_table_name }}' --AND UPPER(COLUMN_NAME) <> 'USGCI_IND' 
    ORDER BY ORDINAL_POSITION),
	GET_ENCR_DETAILS AS (
	SELECT COLUMN_NAME,KEY_VALUE FROM FIN_CRSK_T_SCH.ENCRYPTION_MAPPING
	WHERE COLUMN_NAME IN (SELECT COLUMN_NAME FROM GET_TGT_COL_LIST WHERE COLUMN_NAME LIKE '%_ENCR' )
	),
	NON_CASTING AS(
	SELECT 
	CASE WHEN (SRC.COLUMN_NAME IS NULL OR '{{ pcr_create_update_date_overwrite }}' = 'Y') AND TGT.COLUMN_NAME = 'PCR_CREATE_DT' THEN 'CURRENT_TIMESTAMP'
		WHEN (SRC.COLUMN_NAME IS NULL OR '{{ pcr_create_update_date_overwrite }}' = 'Y') AND TGT.COLUMN_NAME = 'PCR_UPDATE_DT' THEN 'CURRENT_TIMESTAMP'
		WHEN SRC.COLUMN_NAME IS NULL AND TGT.COLUMN_NAME = 'USGCI_IND' THEN 'NULL :: VARCHAR(1) '
		WHEN (SRC.COLUMN_NAME IS NULL OR '{{ log_id_overwrite }}' = 'Y' ) AND (TGT.COLUMN_NAME = 'PCR_CREATE_LOG_ID' AND TGT.NUMERIC_PRECISION IS NULL) THEN 'DATE_PART(''EPOCH_SECOND'',CURRENT_TIMESTAMP(2)) '
		WHEN (SRC.COLUMN_NAME IS NULL OR '{{ log_id_overwrite }}' = 'Y' ) AND (TGT.COLUMN_NAME = 'PCR_UPDATE_LOG_ID' AND TGT.NUMERIC_PRECISION IS NULL) THEN 'DATE_PART(''EPOCH_SECOND'',CURRENT_TIMESTAMP(2)) '
		WHEN (SRC.COLUMN_NAME IS NULL OR '{{ log_id_overwrite }}' = 'Y' ) AND (TGT.COLUMN_NAME = 'PCR_CREATE_LOG_ID' AND TGT.NUMERIC_PRECISION IS NOT NULL) THEN 'SUBSTRING(DATE_PART(''EPOCH_SECOND'',CURRENT_TIMESTAMP(2)),0,'||TGT.NUMERIC_PRECISION||') '
		WHEN (SRC.COLUMN_NAME IS NULL OR '{{ log_id_overwrite }}' = 'Y' ) AND (TGT.COLUMN_NAME = 'PCR_UPDATE_LOG_ID' AND TGT.NUMERIC_PRECISION IS NOT NULL) THEN 'SUBSTRING(DATE_PART(''EPOCH_SECOND'',CURRENT_TIMESTAMP(2)),0,'||TGT.NUMERIC_PRECISION||') '
			ELSE 
                CASE WHEN (ENCR.COLUMN_NAME IS NULL OR SRC.COLUMN_NAME= TGT.COLUMN_NAME) THEN SRC.COLUMN_NAME
                        ELSE
                        'DS_DB.DS_SCH.SFENCRYPT('||SRC.COLUMN_NAME||','||''''||KEY_VALUE||''''||')'
                        END
		END||' AS '||
		TGT.COLUMN_NAME AS VALUE
	FROM 
	GET_TGT_COL_LIST TGT
	LEFT OUTER JOIN 
	GET_SRC_COL_LIST SRC
	--ON REPLACE(TGT.COLUMN_NAME,'_ENCR')=SRC.COLUMN_NAME
    ON (REPLACE(TGT.COLUMN_NAME,'_ENCR')=SRC.COLUMN_NAME OR TGT.COLUMN_NAME=SRC.COLUMN_NAME)
	--AND TGT.ORDINAL_POSITION=SRC.ORDINAL_POSITION
    LEFT OUTER JOIN 
    GET_ENCR_DETAILS ENCR
    ON ENCR.COLUMN_NAME = TGT.COLUMN_NAME
	ORDER BY TGT.ORDINAL_POSITION
	),
	CASTING AS(
	SELECT 
	CASE WHEN (SRC.COLUMN_NAME IS NULL OR '{{ pcr_create_update_date_overwrite }}' = 'Y') AND TGT.COLUMN_NAME = 'PCR_CREATE_DT' THEN 'CURRENT_TIMESTAMP'
		WHEN (SRC.COLUMN_NAME IS NULL OR '{{ pcr_create_update_date_overwrite }}' = 'Y') AND TGT.COLUMN_NAME = 'PCR_UPDATE_DT' THEN 'CURRENT_TIMESTAMP'
		WHEN SRC.COLUMN_NAME IS NULL AND TGT.COLUMN_NAME = 'USGCI_IND' THEN 'NULL :: VARCHAR(1) '
		WHEN (SRC.COLUMN_NAME IS NULL OR '{{ log_id_overwrite }}' = 'Y' ) AND (TGT.COLUMN_NAME = 'PCR_CREATE_LOG_ID' AND TGT.NUMERIC_PRECISION IS NULL) THEN 'DATE_PART(''EPOCH_SECOND'',CURRENT_TIMESTAMP(2)) '
		WHEN (SRC.COLUMN_NAME IS NULL OR '{{ log_id_overwrite }}' = 'Y' ) AND (TGT.COLUMN_NAME = 'PCR_UPDATE_LOG_ID' AND TGT.NUMERIC_PRECISION IS NULL) THEN 'DATE_PART(''EPOCH_SECOND'',CURRENT_TIMESTAMP(2)) '
		WHEN (SRC.COLUMN_NAME IS NULL OR '{{ log_id_overwrite }}' = 'Y' ) AND (TGT.COLUMN_NAME = 'PCR_CREATE_LOG_ID' AND TGT.NUMERIC_PRECISION IS NOT NULL) THEN 'SUBSTRING(DATE_PART(''EPOCH_SECOND'',CURRENT_TIMESTAMP(2)),0,'||TGT.NUMERIC_PRECISION||') '
		WHEN (SRC.COLUMN_NAME IS NULL OR '{{ log_id_overwrite }}' = 'Y' ) AND (TGT.COLUMN_NAME = 'PCR_UPDATE_LOG_ID' AND TGT.NUMERIC_PRECISION IS NOT NULL) THEN 'SUBSTRING(DATE_PART(''EPOCH_SECOND'',CURRENT_TIMESTAMP(2)),0,'||TGT.NUMERIC_PRECISION||') '
			ELSE  CASE WHEN (ENCR.COLUMN_NAME IS NULL OR SRC.COLUMN_NAME= TGT.COLUMN_NAME) THEN SRC.COLUMN_NAME
                        ELSE
                        'DS_DB.DS_SCH.SFENCRYPT('||SRC.COLUMN_NAME||','||''''||KEY_VALUE||''''||')'
                        END
		END||'::'||
		TGT.DATATYPE||' AS '||
		TGT.COLUMN_NAME AS VALUE
	FROM 
	GET_TGT_COL_LIST TGT
	LEFT OUTER JOIN 
	GET_SRC_COL_LIST SRC
	--ON REPLACE(TGT.COLUMN_NAME,'_ENCR')=SRC.COLUMN_NAME
    ON (REPLACE(TGT.COLUMN_NAME,'_ENCR')=SRC.COLUMN_NAME OR TGT.COLUMN_NAME=SRC.COLUMN_NAME)
	--AND TGT.ORDINAL_POSITION=SRC.ORDINAL_POSITION
    LEFT OUTER JOIN 
    GET_ENCR_DETAILS ENCR
    ON ENCR.COLUMN_NAME = TGT.COLUMN_NAME
	ORDER BY TGT.ORDINAL_POSITION
	)
	
	SELECT 'SELECT '||replace(replace(replace(ARRAY_AGG(VALUE) WITHIN GROUP (ORDER BY VALUE ASC) ::varchar ,'"',''),'[',''),']','')
	||' FROM '||'{{ source_schema_name }}'||'.'||'{{ source_table_name }}'  ||
    '{{ qualify_stmt }}'
	FROM CASTING
	
	{% endcall %}
	
{% else %}
    {# Core and STG tables got encrypted columns#}

	{% call statement('my_statement', fetch_result=True) %}
	
	WITH GET_TGT_COL_LIST AS (
	select COLUMN_NAME,
    DATA_TYPE|| CASE WHEN DATA_TYPE IN ('NUMBER', 'DECIMAL', 'NUMERIC') THEN '(' || NUMERIC_PRECISION || ',' || NUMERIC_SCALE || ')' WHEN DATA_TYPE IN ('VARCHAR', 'CHAR', 'TEXT', 'VARIANT') THEN '(' || CHARACTER_MAXIMUM_LENGTH || ')' WHEN DATA_TYPE IN ('TIMESTAMP', 'TIMESTAMP_NTZ', 'TIMESTAMP_LTZ', 'TIMESTAMP_TZ') THEN '(' || DATETIME_PRECISION || ')' ELSE '' END AS DATATYPE,
    ORDINAL_POSITION ,NUMERIC_PRECISION
    FROM INFORMATION_SCHEMA.COLUMNS 
	WHERE TABLE_SCHEMA='{{ target_schema_name }}' AND TABLE_NAME='{{ target_table_name }}'  ORDER BY ORDINAL_POSITION),
	GET_SRC_COL_LIST AS (
	select COLUMN_NAME,
    DATA_TYPE|| CASE WHEN DATA_TYPE IN ('NUMBER', 'DECIMAL', 'NUMERIC') THEN '(' || NUMERIC_PRECISION || ',' || NUMERIC_SCALE || ')' WHEN DATA_TYPE IN ('VARCHAR', 'CHAR', 'TEXT', 'VARIANT') THEN '(' || CHARACTER_MAXIMUM_LENGTH || ')' WHEN DATA_TYPE IN ('TIMESTAMP', 'TIMESTAMP_NTZ', 'TIMESTAMP_LTZ', 'TIMESTAMP_TZ') THEN '(' || DATETIME_PRECISION || ')' ELSE '' END AS DATATYPE,
    ORDINAL_POSITION 
    FROM INFORMATION_SCHEMA.COLUMNS 
	WHERE TABLE_SCHEMA='{{ source_schema_name }}' AND TABLE_NAME='{{ source_table_name }}'  ORDER BY ORDINAL_POSITION),
	GET_ENCR_DETAILS AS (
	SELECT * FROM FIN_CRSK_T_SCH.ENCRYPTION_MAPPING
	WHERE COLUMN_NAME IN (SELECT COLUMN_NAME FROM GET_TGT_COL_LIST )
	),
	NON_CASTING AS(
	SELECT 
	CASE WHEN (SRC.COLUMN_NAME IS NULL OR '{{ pcr_create_update_date_overwrite }}' = 'Y') AND TGT.COLUMN_NAME = 'PCR_CREATE_DT' THEN 'CURRENT_TIMESTAMP'
		WHEN (SRC.COLUMN_NAME IS NULL OR '{{ pcr_create_update_date_overwrite }}' = 'Y') AND TGT.COLUMN_NAME = 'PCR_UPDATE_DT' THEN 'CURRENT_TIMESTAMP'
		WHEN SRC.COLUMN_NAME IS NULL AND TGT.COLUMN_NAME = 'USGCI_IND' THEN 'NULL :: VARCHAR(1) '
		WHEN (SRC.COLUMN_NAME IS NULL OR '{{ log_id_overwrite }}' = 'Y' ) AND (TGT.COLUMN_NAME = 'PCR_CREATE_LOG_ID' AND TGT.NUMERIC_PRECISION IS NULL) THEN 'DATE_PART(''EPOCH_SECOND'',CURRENT_TIMESTAMP(2)) '
		WHEN (SRC.COLUMN_NAME IS NULL OR '{{ log_id_overwrite }}' = 'Y' ) AND (TGT.COLUMN_NAME = 'PCR_UPDATE_LOG_ID' AND TGT.NUMERIC_PRECISION IS NULL) THEN 'DATE_PART(''EPOCH_SECOND'',CURRENT_TIMESTAMP(2)) '
		WHEN (SRC.COLUMN_NAME IS NULL OR '{{ log_id_overwrite }}' = 'Y' ) AND (TGT.COLUMN_NAME = 'PCR_CREATE_LOG_ID' AND TGT.NUMERIC_PRECISION IS NOT NULL) THEN 'SUBSTRING(DATE_PART(''EPOCH_SECOND'',CURRENT_TIMESTAMP(2)),0,'||TGT.NUMERIC_PRECISION||') '
		WHEN (SRC.COLUMN_NAME IS NULL OR '{{ log_id_overwrite }}' = 'Y' ) AND (TGT.COLUMN_NAME = 'PCR_UPDATE_LOG_ID' AND TGT.NUMERIC_PRECISION IS NOT NULL) THEN 'SUBSTRING(DATE_PART(''EPOCH_SECOND'',CURRENT_TIMESTAMP(2)),0,'||TGT.NUMERIC_PRECISION||') '
			ELSE SRC.COLUMN_NAME
		END||' AS '||
		TGT.COLUMN_NAME AS VALUE
	FROM 
	GET_TGT_COL_LIST TGT
	LEFT OUTER JOIN 
	GET_SRC_COL_LIST SRC
	ON TGT.COLUMN_NAME=SRC.COLUMN_NAME
	--AND TGT.ORDINAL_POSITION=SRC.ORDINAL_POSITION
	ORDER BY TGT.ORDINAL_POSITION
	),
	CASTING AS(
	SELECT 
	CASE WHEN (SRC.COLUMN_NAME IS NULL OR '{{ pcr_create_update_date_overwrite }}' = 'Y') AND TGT.COLUMN_NAME = 'PCR_CREATE_DT' THEN 'CURRENT_TIMESTAMP'
		WHEN (SRC.COLUMN_NAME IS NULL OR '{{ pcr_create_update_date_overwrite }}' = 'Y') AND TGT.COLUMN_NAME = 'PCR_UPDATE_DT' THEN 'CURRENT_TIMESTAMP'
		WHEN SRC.COLUMN_NAME IS NULL AND TGT.COLUMN_NAME = 'USGCI_IND' THEN 'NULL :: VARCHAR(1) '
		WHEN (SRC.COLUMN_NAME IS NULL OR '{{ log_id_overwrite }}' = 'Y' ) AND (TGT.COLUMN_NAME = 'PCR_CREATE_LOG_ID' AND TGT.NUMERIC_PRECISION IS NULL) THEN 'DATE_PART(''EPOCH_SECOND'',CURRENT_TIMESTAMP(2)) '
		WHEN (SRC.COLUMN_NAME IS NULL OR '{{ log_id_overwrite }}' = 'Y' ) AND (TGT.COLUMN_NAME = 'PCR_UPDATE_LOG_ID' AND TGT.NUMERIC_PRECISION IS NULL) THEN 'DATE_PART(''EPOCH_SECOND'',CURRENT_TIMESTAMP(2)) '
		WHEN (SRC.COLUMN_NAME IS NULL OR '{{ log_id_overwrite }}' = 'Y' ) AND (TGT.COLUMN_NAME = 'PCR_CREATE_LOG_ID' AND TGT.NUMERIC_PRECISION IS NOT NULL) THEN 'SUBSTRING(DATE_PART(''EPOCH_SECOND'',CURRENT_TIMESTAMP(2)),0,'||TGT.NUMERIC_PRECISION||') '
		WHEN (SRC.COLUMN_NAME IS NULL OR '{{ log_id_overwrite }}' = 'Y' ) AND (TGT.COLUMN_NAME = 'PCR_UPDATE_LOG_ID' AND TGT.NUMERIC_PRECISION IS NOT NULL) THEN 'SUBSTRING(DATE_PART(''EPOCH_SECOND'',CURRENT_TIMESTAMP(2)),0,'||TGT.NUMERIC_PRECISION||') '
			ELSE SRC.COLUMN_NAME
		END||'::'||
		TGT.DATATYPE||' AS '||
		TGT.COLUMN_NAME AS VALUE
	
	FROM 
	GET_TGT_COL_LIST TGT
	LEFT OUTER JOIN 
	GET_SRC_COL_LIST SRC
	ON TGT.COLUMN_NAME=SRC.COLUMN_NAME
	--AND TGT.ORDINAL_POSITION=SRC.ORDINAL_POSITION
	ORDER BY TGT.ORDINAL_POSITION
	)
	
	SELECT 'SELECT '||replace(replace(replace(ARRAY_AGG(VALUE) WITHIN GROUP (ORDER BY VALUE ASC) ::varchar ,'"',''),'[',''),']','')
	||' FROM '||'{{ source_schema_name }}'||'.'||'{{ source_table_name }}' ||
    '{{ qualify_stmt }}'
	FROM CASTING
	
	{% endcall %}
{% endif %}

{% if execute %}
{% set STN_STATEMENT = load_result('my_statement')['data'][0][0] %}
{% else %}
{% set STN_STATEMENT = [] %}
{% endif %}

{{ log(STN_STATEMENT) }}

{{ return(STN_STATEMENT) }}

{%- endmacro %}
