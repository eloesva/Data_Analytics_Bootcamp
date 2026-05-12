-- NIVEL 1
SELECT
  tc.*,
  cc.company_name,
  cc.country
FROM `sprint3_silver.transactions_clean` AS tc
JOIN `sprint3_silver.companies_clean` AS cc
  ON tc.business_id = cc.company_id
WHERE EXTRACT(DATE FROM tc.timestamp) = DATE '2022-03-12';



-- Ejercicio 2: generación de datos recientes
-- Paso 1: tabla de fechas recientes
CREATE OR REPLACE TABLE `sprint3_silver.transactions_recent` AS

SELECT
  * EXCEPT(timestamp),-- toma todo excepto el timestamp
  TIMESTAMP_SUB(CURRENT_TIMESTAMP(),INTERVAL CAST(RAND() * 50 AS INT64) DAY) AS timestamp -- CURRENT da el tiempo actual, CAST RAND da un número aleatorio entre 0 y 49, _SUB resta ese número de días a la fecha actual

FROM `sprint3_silver.transactions_clean`;


-- Paso 2: creación de tabla optimizada (partición y cluster)

CREATE OR REPLACE TABLE `sprint3_gold.fact_transactions_optimized`
PARTITION BY DATE(timestamp)
CLUSTER BY business_id
AS
SELECT *
FROM `sprint3_silver.transactions_recent`;



-- Ejercicio 3: Prueba del rendimiento (benchmark)

SELECT *
FROM `sprint3_silver.transactions_recent` 
WHERE DATE(timestamp) <= CURRENT_DATE() - INTERVAL 1 MONTH;


SELECT *
FROM `sprint3_gold.fact_transactions_optimized` 
WHERE DATE(timestamp) <= CURRENT_DATE() - INTERVAL 1 MONTH;



-- Ejercicio 4: Vistas Materializadas

CREATE OR REPLACE MATERIALIZED VIEW `sprint3_gold.mv_daily_sales` AS -- vista para contar las ventas diarias
SELECT
  DATE(timestamp) AS sales_date,
  COUNT(*) AS ventas_totales_dia
FROM `sprint3_gold.fact_transactions_optimized`
GROUP BY sales_date;

SELECT *
FROM `sprint3_gold.mv_daily_sales`;

-- NIVEL 2

WITH VIP_Stats AS (
  SELECT
    user_id,
    SUM(amount) AS total_gastado,
    COUNT(transaction_id) AS num_compras,
    ROUND(AVG(amount), 2) AS ticket_medio,
    MAX(amount) AS max_compra
  FROM `sprint3-analytics-estefaniat.sprint3_silver.transactions_clean` -- podría tomarlo de la tabla optimizada para ahorrar MB!!
  GROUP BY user_id
  HAVING total_gastado > 500
),

users AS (
  SELECT
    user_id,
    CONCAT(name, ' ', surname) AS nombre_completo,
    email
  FROM `sprint3-analytics-estefaniat.sprint3_silver.users_combined`
)

SELECT
  v.user_id,
  u.nombre_completo,
  u.email,
  v.num_compras,
  v.ticket_medio,
  v.max_compra,
  v.total_gastado
FROM VIP_Stats AS v
JOIN users AS u
  ON v.user_id = u.user_id
ORDER BY v.total_gastado DESC;


-- Ejercicio 2: Análisis de Tendencias (Window Functions sobre Vistas)

WITH daily_sales_lag AS (
  SELECT
    sales_date AS Fecha,
    ventas_totales_dia AS Ventas_Hoy,
    LAG(ventas_totales_dia) OVER (ORDER BY sales_date) AS Ventas_Ayer -- LAG toma la fila anterior
  FROM `sprint3_gold.mv_daily_sales`
)

SELECT
  Fecha,
  Ventas_Hoy,
  Ventas_Ayer,
  ROUND(
    SAFE_DIVIDE(Ventas_Hoy - Ventas_Ayer, Ventas_Ayer) * 100,
    2
  ) AS Diff_Percentual
FROM daily_sales_lag
ORDER BY Fecha;

-- Ejercicio 3: Totales acumulados. Informe con 3 columnas (fecha, ventas del día, ventas acumuladas)

SELECT
  sales_date AS Fecha,
  ROUND(ventas_totales_dia, 2) AS Ventas_del_Dia,

  ROUND(
    SUM(ventas_totales_dia) OVER (
      PARTITION BY EXTRACT(YEAR FROM sales_date)
      ORDER BY sales_date
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ),
    2
  ) AS Ventas_Acumuladas_YTD

FROM `sprint3_gold.mv_daily_sales`
ORDER BY Fecha;

-- Ejercicio 4: listado de los usuarios que han superado su tercera compra

WITH ordered_transactions AS ( -- se crea una tabla temporal con las 3 primeras compras de cada usuario
  SELECT
    user_id,
    transaction_id,
    timestamp,
    amount,

    ROW_NUMBER() OVER (
      PARTITION BY user_id
      ORDER BY timestamp
    ) AS purchase_number

  FROM `sprint3-analytics-estefaniat.sprint3_silver.transactions_clean`
  QUALIFY purchase_number <= 3 
),

first_three_stats AS ( -- calcula la media solo sobre esas 3 compras, no sobre todo el historial
  SELECT
    user_id,
    AVG(amount) AS media_3_primeras
  FROM ordered_transactions
  GROUP BY user_id
  HAVING COUNT(*) = 3
),

third_purchase AS (
  SELECT
    user_id,
    timestamp AS fecha_tercera_compra,
    amount AS importe_tercera_compra
  FROM ordered_transactions
  WHERE purchase_number = 3
),

users AS (
  SELECT
    user_id,
    CONCAT(name, ' ', surname) AS nombre_completo,
    email
  FROM `sprint3-analytics-estefaniat.sprint3_silver.users_combined`
)

SELECT
  u.user_id,
  u.nombre_completo,
  u.email,
  t.fecha_tercera_compra,
  t.importe_tercera_compra,
  ROUND(s.media_3_primeras, 2) AS media_3_primeras
FROM third_purchase AS t
JOIN first_three_stats AS s
  ON t.user_id = s.user_id
JOIN users AS u
  ON t.user_id = u.user_id
ORDER BY t.fecha_tercera_compra;


-- NIVEL 3

CREATE OR REPLACE TABLE `sprint3_gold.dim_transactions_flat` AS

SELECT
  t.transaction_id,
  t.timestamp,
  t.amount AS total_ticket,
  TRIM(product_id) AS product_sku,-- product_id de transactions_clean tiene espacios, TRIM los quita... Convertir a array desde antes!
  p.name AS product_name,
  p.price AS product_price

FROM `sprint3_silver.transactions_clean` AS t -- pudo haber venido de transactions_clean
CROSS JOIN UNNEST(SPLIT(t.product_ids, ',')) AS product_id
JOIN `sprint3_silver.products_clean` AS p
  ON SAFE_CAST(TRIM(product_id) AS INT64) = SAFE_CAST(p.product_id AS INT64);


  SELECT *
  FROM `sprint3_gold.dim_transactions_flat`;

-- Ejercicio 2: Ranking de ventas 

SELECT
  product_name,
  COUNT(*) AS unidades_vendidas
FROM `sprint3_gold.dim_transactions_flat`
GROUP BY product_name
ORDER BY unidades_vendidas DESC
LIMIT 5;


-- Ejercicio 3: Automatización del Pipeline

CREATE OR REPLACE FUNCTION `sprint3_gold.calculate_tax`(amount FLOAT64)
RETURNS FLOAT64
AS (
  ROUND(amount * 1.21, 2)
);

CREATE OR REPLACE TABLE `sprint3_gold.dim_transactions_flat` AS

SELECT
  t.transaction_id,
  t.timestamp,
  SAFE_CAST(t.amount AS FLOAT64) AS total_ticket,
  TRIM(product_id) AS product_sku,
  p.name AS product_name,
  p.price AS product_price,
  `sprint3_gold.calculate_tax`(SAFE_CAST(p.price AS FLOAT64)) AS product_price_tax_inc -- se llama a la función

FROM `sprint3_silver.transactions_clean` AS t
CROSS JOIN UNNEST(SPLIT(t.product_ids, ',')) AS product_id
JOIN `sprint3_silver.products_clean` AS p
  ON SAFE_CAST(TRIM(product_id) AS INT64) = SAFE_CAST(p.product_id AS INT64);


