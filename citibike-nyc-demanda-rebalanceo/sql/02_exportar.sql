-- Ejecuta UNA consulta a la vez y descarga cada resultado con
-- GUARDAR RESULTADOS -> CSV (archivo local), usando el nombre indicado.

SELECT * FROM `tu-proyecto.cyclistic.calidad_datos`;                                   -- calidad_datos.csv
SELECT * FROM `tu-proyecto.cyclistic.dim_estaciones` ORDER BY station_id;              -- dim_estaciones.csv
SELECT * FROM `tu-proyecto.cyclistic.mart_demanda_diaria` ORDER BY fecha, tipo_usuario;-- mart_demanda_diaria.csv
SELECT * FROM `tu-proyecto.cyclistic.mart_estaciones` ORDER BY anio, movimientos DESC; -- mart_estaciones.csv
SELECT * FROM `tu-proyecto.cyclistic.mart_flujo_horario`;                              -- mart_flujo_horario.csv
SELECT * FROM `tu-proyecto.cyclistic.mart_perfil_usuarios`;                            -- mart_perfil_usuarios.csv
SELECT * FROM `tu-proyecto.cyclistic.mart_rutas` ORDER BY tipo_usuario, viajes DESC;   -- mart_rutas.csv
SELECT * FROM `tu-proyecto.cyclistic.mart_barrios` ORDER BY anio, salidas DESC;        -- mart_barrios.csv
SELECT * FROM `tu-proyecto.cyclistic.mart_edad_genero`;                                -- mart_edad_genero.csv
