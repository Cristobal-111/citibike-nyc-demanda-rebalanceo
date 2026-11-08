-- =====================================================================================
-- Citi Bike NYC · Demanda, rebalanceo y expansión de estaciones
-- Script de construcción del modelo en BigQuery (ejecutar completo con RUN).
--
-- ANTES DE EJECUTAR: reemplaza  tu-proyecto.cyclistic  por tu proyecto y dataset
-- (Ctrl+H en el editor de BigQuery). Debe ser el dataset donde está tu tabla `zipcodes`,
-- y ese dataset debe estar en la ubicación US.
--
-- Período: 2016-2017 (dos años completos, los más recientes con datos meteorológicos).
-- Diseño: primero se limpian los viajes y se georreferencian las ESTACIONES (~800 filas)
-- en vez de cada viaje (~30 millones): el cruce espacial se hace una sola vez y las
-- consultas siguientes son mucho más baratas.
-- =====================================================================================


-- -------------------------------------------------------------------------------------
-- 0. CALIDAD DE DATOS: cuántos viajes excluye cada regla de limpieza
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE TABLE `tu-proyecto.cyclistic.calidad_datos` AS
SELECT
  COUNT(*)                                                             AS viajes_brutos,
  COUNTIF(tripduration < 60)                                           AS menos_de_1_minuto,
  COUNTIF(tripduration > 3 * 3600)                                     AS mas_de_3_horas,
  COUNTIF(start_station_id IS NULL OR end_station_id IS NULL)          AS sin_estacion,
  COUNTIF(usertype IS NULL OR usertype NOT IN ('Subscriber', 'Customer')) AS tipo_usuario_desconocido,
  COUNTIF(start_station_latitude NOT BETWEEN 40.4 AND 41.0
       OR start_station_longitude NOT BETWEEN -74.3 AND -73.6
       OR end_station_latitude NOT BETWEEN 40.4 AND 41.0
       OR end_station_longitude NOT BETWEEN -74.3 AND -73.6)          AS coordenadas_fuera_de_nyc,
  COUNTIF(start_station_id = end_station_id)                           AS viajes_ida_y_vuelta,
  COUNTIF(birth_year IS NOT NULL AND birth_year < 1930)                AS anio_nacimiento_improbable
FROM `bigquery-public-data.new_york_citibike.citibike_trips`
WHERE starttime >= DATETIME '2016-01-01 00:00:00'
  AND starttime <  DATETIME '2018-01-01 00:00:00';


-- -------------------------------------------------------------------------------------
-- 1. VIAJES LIMPIOS (tabla base, agrupada por estación)
-- Nota: no se particiona por fecha a propósito. En la zona de pruebas (sandbox) de BigQuery
-- las particiones vencen a los 60 días según su FECHA, así que las de 2016-2017 se borrarían
-- al instante. El agrupamiento (CLUSTER BY) sí reduce lo que lee cada consulta.
-- -------------------------------------------------------------------------------------
-- se borra primero: BigQuery no permite reemplazar una tabla cambiando su partición
DROP TABLE IF EXISTS `tu-proyecto.cyclistic.viajes_limpios`;

CREATE OR REPLACE TABLE `tu-proyecto.cyclistic.viajes_limpios`
CLUSTER BY start_station_id, end_station_id AS
SELECT
  DATE(starttime)                              AS fecha,
  EXTRACT(HOUR FROM starttime)                 AS hora_salida,
  DATE(stoptime)                               AS fecha_llegada,
  EXTRACT(HOUR FROM stoptime)                  AS hora_llegada,
  EXTRACT(DAYOFWEEK FROM starttime) IN (1, 7)  AS es_fin_de_semana,      -- 1 = domingo, 7 = sábado
  IF(usertype = 'Subscriber', 'Abonado', 'Ocasional') AS tipo_usuario,
  start_station_id,
  end_station_id,
  ROUND(tripduration / 60, 1)                  AS minutos,
  IF(birth_year BETWEEN 1930 AND 2005, birth_year, NULL) AS anio_nacimiento,
  gender                                       AS genero
FROM `bigquery-public-data.new_york_citibike.citibike_trips`
WHERE starttime >= DATETIME '2016-01-01 00:00:00'
  AND starttime <  DATETIME '2018-01-01 00:00:00'
  AND tripduration BETWEEN 60 AND 3 * 3600                 -- falsos inicios y bicicletas no devueltas
  AND start_station_id IS NOT NULL AND end_station_id IS NOT NULL
  AND usertype IN ('Subscriber', 'Customer')
  AND start_station_latitude BETWEEN 40.4 AND 41.0 AND start_station_longitude BETWEEN -74.3 AND -73.6
  AND end_station_latitude   BETWEEN 40.4 AND 41.0 AND end_station_longitude   BETWEEN -74.3 AND -73.6;


-- -------------------------------------------------------------------------------------
-- 2. DIMENSIÓN DE ESTACIONES: coordenadas, código postal, distrito y barrio
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE TABLE `tu-proyecto.cyclistic.dim_estaciones` AS
WITH puntos AS (
  SELECT start_station_id AS station_id, start_station_name AS nombre,
         start_station_latitude AS lat, start_station_longitude AS lng
  FROM `bigquery-public-data.new_york_citibike.citibike_trips`
  WHERE starttime >= DATETIME '2016-01-01 00:00:00' AND starttime < DATETIME '2018-01-01 00:00:00'
  UNION ALL
  SELECT end_station_id, end_station_name, end_station_latitude, end_station_longitude
  FROM `bigquery-public-data.new_york_citibike.citibike_trips`
  WHERE starttime >= DATETIME '2016-01-01 00:00:00' AND starttime < DATETIME '2018-01-01 00:00:00'
),
estaciones AS (
  -- una estación puede aparecer con nombres o coordenadas levemente distintos:
  -- se usa el nombre más frecuente y la mediana de las coordenadas
  SELECT
    station_id,
    APPROX_TOP_COUNT(nombre, 1)[OFFSET(0)].value AS nombre,
    APPROX_QUANTILES(lat, 2)[OFFSET(1)]          AS lat,
    APPROX_QUANTILES(lng, 2)[OFFSET(1)]          AS lng
  FROM puntos
  WHERE station_id IS NOT NULL
    AND lat BETWEEN 40.4 AND 41.0 AND lng BETWEEN -74.3 AND -73.6
  GROUP BY station_id
)
SELECT
  e.station_id,
  e.nombre,
  e.lat,
  e.lng,
  z.zip_code,
  COALESCE(n.borough, IF(z.state_code = 'NJ', 'Jersey City (NJ)', 'Sin dato'))        AS distrito,
  COALESCE(n.neighborhood, IF(z.state_code = 'NJ', 'Jersey City (NJ)', 'Sin dato'))   AS barrio
FROM estaciones e
LEFT JOIN `bigquery-public-data.geo_us_boundaries.zip_codes` z
  ON ST_WITHIN(ST_GEOGPOINT(e.lng, e.lat), z.zip_code_geom)
LEFT JOIN `tu-proyecto.cyclistic.zipcodes` n
  ON z.zip_code = CAST(n.zip AS STRING);


-- -------------------------------------------------------------------------------------
-- 3. MART · DEMANDA DIARIA CON CLIMA (Central Park, NOAA)
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE TABLE `tu-proyecto.cyclistic.mart_demanda_diaria` AS
WITH clima AS (
  SELECT
    DATE(CAST(year AS INT64), CAST(mo AS INT64), CAST(da AS INT64))         AS fecha,
    IF(temp = 9999.9, NULL, ROUND((temp - 32) * 5 / 9, 1))                  AS temp_media_c,
    IF(`max` = 9999.9, NULL, ROUND((`max` - 32) * 5 / 9, 1))               AS temp_max_c,
    IF(prcp = 99.99, NULL, ROUND(prcp * 25.4, 1))                           AS precipitacion_mm,
    ROUND(SAFE_CAST(NULLIF(wdsp, '999.9') AS FLOAT64) * 1.852, 1)           AS viento_kmh,
    rain_drizzle = '1'                                                      AS hubo_lluvia,
    snow_ice_pellets = '1'                                                  AS hubo_nieve
  FROM `bigquery-public-data.noaa_gsod.gsod201*`
  WHERE _TABLE_SUFFIX IN ('6', '7')
    AND wban = '94728'                                                      -- NEW YORK CENTRAL PARK
),
viajes AS (
  SELECT
    fecha,
    tipo_usuario,
    COUNT(*)                                   AS viajes,
    ROUND(AVG(minutos), 1)                     AS duracion_prom_min,
    APPROX_QUANTILES(minutos, 2)[OFFSET(1)]    AS duracion_mediana_min
  FROM `tu-proyecto.cyclistic.viajes_limpios`
  GROUP BY fecha, tipo_usuario
)
SELECT
  v.fecha,
  EXTRACT(YEAR FROM v.fecha)                   AS anio,
  EXTRACT(MONTH FROM v.fecha)                  AS mes,
  ['domingo', 'lunes', 'martes', 'miércoles', 'jueves', 'viernes', 'sábado'][OFFSET(EXTRACT(DAYOFWEEK FROM v.fecha) - 1)] AS dia_semana,
  EXTRACT(DAYOFWEEK FROM v.fecha) IN (1, 7)    AS es_fin_de_semana,
  CASE WHEN EXTRACT(MONTH FROM v.fecha) IN (12, 1, 2) THEN 'Invierno'
       WHEN EXTRACT(MONTH FROM v.fecha) IN (3, 4, 5)  THEN 'Primavera'
       WHEN EXTRACT(MONTH FROM v.fecha) IN (6, 7, 8)  THEN 'Verano'
       ELSE 'Otoño' END                        AS temporada,
  v.tipo_usuario,
  v.viajes,
  v.duracion_prom_min,
  v.duracion_mediana_min,
  c.temp_media_c,
  c.temp_max_c,
  c.precipitacion_mm,
  c.viento_kmh,
  c.hubo_lluvia,
  c.hubo_nieve
FROM viajes v
LEFT JOIN clima c USING (fecha)
ORDER BY v.fecha, v.tipo_usuario;


-- -------------------------------------------------------------------------------------
-- 4. MART · ESTACIONES POR AÑO (demanda, perfil y desbalance)
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE TABLE `tu-proyecto.cyclistic.mart_estaciones` AS
WITH salidas AS (
  SELECT start_station_id AS station_id, EXTRACT(YEAR FROM fecha) AS anio,
         COUNT(*) AS salidas,
         COUNTIF(tipo_usuario = 'Abonado') AS salidas_abonados,
         COUNT(DISTINCT fecha) AS dias_con_salidas
  FROM `tu-proyecto.cyclistic.viajes_limpios`
  GROUP BY 1, 2
),
llegadas AS (
  SELECT end_station_id AS station_id, EXTRACT(YEAR FROM fecha_llegada) AS anio,
         COUNT(*) AS llegadas
  FROM `tu-proyecto.cyclistic.viajes_limpios`
  WHERE EXTRACT(YEAR FROM fecha_llegada) IN (2016, 2017)
  GROUP BY 1, 2
)
SELECT
  station_id,
  anio,
  e.nombre, e.lat, e.lng, e.zip_code, e.distrito, e.barrio,
  COALESCE(s.salidas, 0)                                            AS salidas,
  COALESCE(l.llegadas, 0)                                           AS llegadas,
  COALESCE(s.salidas, 0) + COALESCE(l.llegadas, 0)                  AS movimientos,
  ROUND(SAFE_DIVIDE(s.salidas_abonados, s.salidas), 3)              AS pct_abonados,
  s.dias_con_salidas,
  -- flujo neto diario: > 0 la estación se llena (llegan más bicicletas de las que salen); < 0 se vacía
  ROUND(SAFE_DIVIDE(COALESCE(l.llegadas, 0) - COALESCE(s.salidas, 0), s.dias_con_salidas), 1) AS flujo_neto_diario
FROM salidas s
FULL OUTER JOIN llegadas l USING (station_id, anio)
JOIN `tu-proyecto.cyclistic.dim_estaciones` e USING (station_id);


-- -------------------------------------------------------------------------------------
-- 5. MART · FLUJO POR HORA Y ESTACIÓN (2017): base del análisis de rebalanceo
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE TABLE `tu-proyecto.cyclistic.mart_flujo_horario` AS
WITH dias AS (     -- cantidad de días laborales y de fin de semana en 2017, para promediar
  SELECT es_fin_de_semana, COUNT(DISTINCT fecha) AS n_dias
  FROM `tu-proyecto.cyclistic.viajes_limpios`
  WHERE EXTRACT(YEAR FROM fecha) = 2017
  GROUP BY 1
),
salidas AS (
  SELECT start_station_id AS station_id, es_fin_de_semana, hora_salida AS hora, COUNT(*) AS salidas
  FROM `tu-proyecto.cyclistic.viajes_limpios`
  WHERE EXTRACT(YEAR FROM fecha) = 2017
  GROUP BY 1, 2, 3
),
llegadas AS (
  SELECT end_station_id AS station_id, es_fin_de_semana, hora_llegada AS hora, COUNT(*) AS llegadas
  FROM `tu-proyecto.cyclistic.viajes_limpios`
  WHERE EXTRACT(YEAR FROM fecha) = 2017
  GROUP BY 1, 2, 3
)
SELECT
  station_id,
  e.nombre, e.distrito, e.barrio, e.lat, e.lng,
  IF(es_fin_de_semana, 'Fin de semana', 'Día laboral')                       AS tipo_dia,
  hora,
  ROUND(COALESCE(s.salidas, 0) / d.n_dias, 2)                               AS salidas_prom_dia,
  ROUND(COALESCE(l.llegadas, 0) / d.n_dias, 2)                              AS llegadas_prom_dia,
  ROUND((COALESCE(l.llegadas, 0) - COALESCE(s.salidas, 0)) / d.n_dias, 2)   AS flujo_neto_prom_dia
FROM salidas s
FULL OUTER JOIN llegadas l USING (station_id, es_fin_de_semana, hora)
JOIN dias d USING (es_fin_de_semana)
JOIN `tu-proyecto.cyclistic.dim_estaciones` e USING (station_id);


-- -------------------------------------------------------------------------------------
-- 6. MART · PERFIL HORARIO POR TIPO DE USUARIO (2017)
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE TABLE `tu-proyecto.cyclistic.mart_perfil_usuarios` AS
SELECT
  tipo_usuario,
  IF(es_fin_de_semana, 'Fin de semana', 'Día laboral')   AS tipo_dia,
  hora_salida                                            AS hora,
  COUNT(*)                                               AS viajes,
  APPROX_QUANTILES(minutos, 2)[OFFSET(1)]                AS duracion_mediana_min,
  ROUND(COUNTIF(start_station_id = end_station_id) / COUNT(*), 3) AS pct_ida_y_vuelta
FROM `tu-proyecto.cyclistic.viajes_limpios`
WHERE EXTRACT(YEAR FROM fecha) = 2017
GROUP BY 1, 2, 3;


-- -------------------------------------------------------------------------------------
-- 7. MART · RUTAS MÁS USADAS (2017, top 300 por tipo de usuario)
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE TABLE `tu-proyecto.cyclistic.mart_rutas` AS
WITH rutas AS (
  SELECT tipo_usuario, start_station_id, end_station_id,
         COUNT(*) AS viajes,
         APPROX_QUANTILES(minutos, 2)[OFFSET(1)] AS duracion_mediana_min
  FROM `tu-proyecto.cyclistic.viajes_limpios`
  WHERE EXTRACT(YEAR FROM fecha) = 2017
  GROUP BY 1, 2, 3
  QUALIFY ROW_NUMBER() OVER (PARTITION BY tipo_usuario ORDER BY COUNT(*) DESC) <= 300
)
SELECT
  r.tipo_usuario,
  r.start_station_id, o.nombre AS estacion_origen, o.barrio AS barrio_origen, o.lat AS lat_origen, o.lng AS lng_origen,
  r.end_station_id,   d.nombre AS estacion_destino, d.barrio AS barrio_destino, d.lat AS lat_destino, d.lng AS lng_destino,
  r.viajes,
  r.duracion_mediana_min,
  r.start_station_id = r.end_station_id                                       AS es_ida_y_vuelta,
  ROUND(ST_DISTANCE(ST_GEOGPOINT(o.lng, o.lat), ST_GEOGPOINT(d.lng, d.lat)) / 1000, 2) AS distancia_km
FROM rutas r
JOIN `tu-proyecto.cyclistic.dim_estaciones` o ON o.station_id = r.start_station_id
JOIN `tu-proyecto.cyclistic.dim_estaciones` d ON d.station_id = r.end_station_id;


-- -------------------------------------------------------------------------------------
-- 8. MART · BARRIOS POR AÑO (base del análisis de expansión)
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE TABLE `tu-proyecto.cyclistic.mart_barrios` AS
SELECT
  distrito,
  barrio,
  anio,
  COUNT(DISTINCT station_id)                                   AS estaciones_activas,
  SUM(salidas)                                                 AS salidas,
  SUM(llegadas)                                                AS llegadas,
  ROUND(SUM(salidas) / COUNT(DISTINCT station_id) / 365, 1)    AS salidas_por_estacion_dia,
  ROUND(AVG(pct_abonados), 3)                                  AS pct_abonados_prom,
  ROUND(AVG(ABS(flujo_neto_diario)), 1)                        AS desbalance_prom_diario,
  AVG(lat)                                                     AS lat,
  AVG(lng)                                                     AS lng
FROM `tu-proyecto.cyclistic.mart_estaciones`
GROUP BY distrito, barrio, anio;


-- -------------------------------------------------------------------------------------
-- 9. MART · PERFIL DE ABONADOS POR EDAD Y GÉNERO (2017)
-- -------------------------------------------------------------------------------------
CREATE OR REPLACE TABLE `tu-proyecto.cyclistic.mart_edad_genero` AS
SELECT
  CASE
    WHEN 2017 - anio_nacimiento < 25 THEN '1. Menos de 25'
    WHEN 2017 - anio_nacimiento < 35 THEN '2. 25-34'
    WHEN 2017 - anio_nacimiento < 45 THEN '3. 35-44'
    WHEN 2017 - anio_nacimiento < 55 THEN '4. 45-54'
    WHEN 2017 - anio_nacimiento < 65 THEN '5. 55-64'
    ELSE '6. 65 o más' END                                AS tramo_edad,
  CASE genero WHEN 'male' THEN 'Hombre' WHEN 'female' THEN 'Mujer' ELSE 'Sin dato' END AS genero,
  COUNT(*)                                                AS viajes,
  APPROX_QUANTILES(minutos, 2)[OFFSET(1)]                 AS duracion_mediana_min
FROM `tu-proyecto.cyclistic.viajes_limpios`
WHERE EXTRACT(YEAR FROM fecha) = 2017
  AND tipo_usuario = 'Abonado'
  AND anio_nacimiento IS NOT NULL
GROUP BY 1, 2;
