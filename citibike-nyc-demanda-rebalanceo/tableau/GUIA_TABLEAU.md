# Guía del dashboard en Tableau Public

Usa los archivos de `data/tableau/`: cada uno se conecta como una fuente de datos separada (**Conectar → Archivo de texto**), sin uniones.

| Archivo | Grano | Para qué |
| --- | --- | --- |
| `demanda_diaria_clima.csv` | 1 fila por día | Tendencia, clima, KPIs |
| `rebalanceo_estaciones.csv` | 1 fila por estación | Mapa y ranking de rebalanceo |
| `flujo_horario.csv` | estación × tipo de día × hora | Curvas por hora y animación del mapa |
| `expansion_barrios.csv` | 1 fila por barrio | Matriz de expansión |
| `perfil_usuarios.csv` | tipo de usuario × tipo de día × hora | Perfil horario |
| `rutas_top.csv` | 600 rutas | Mapa de rutas |
| `estaciones_anual.csv`, `abonados_edad_genero.csv` | — | Detalle y demografía |

**Antes de empezar:** en cada fuente, marca `lat`/`lng` (y `lat_origen`, `lng_origen`, `lat_destino`, `lng_destino`) como **Función geográfica → Latitud / Longitud**.

## Dashboard 1 · Demanda y clima

1. **Tarjetas KPI** (fuente `demanda_diaria_clima`):
   - Viajes totales = `SUM([viajes])`
   - % ocasionales = `SUM([Ocasional]) / SUM([viajes])`
   - Viajes por día = `SUM([viajes]) / COUNTD([fecha])`
2. **Línea diaria:** `fecha` (día exacto, continuo) en Columnas y `viajes` en Filas. Ponle una nota: "Sin datos oct-2016 a mar-2017 en la fuente".
3. **Temperatura vs. viajes:** diagrama de dispersión con `temp_max_c` y `viajes`, color = `tramo_lluvia` y forma = `es_fin_de_semana`.
4. **Barras por lluvia:** `tramo_lluvia` contra el promedio de `Abonado` y `Ocasional`, lado a lado (Nombres / Valores de medidas).
5. Filtros: año, temporada, tipo de día.

## Dashboard 2 · Usuarios

1. **Perfil horario:** `hora` en Columnas, `SUM(viajes)` en Filas, color = `tipo_usuario`, columnas por `tipo_dia`. Es el gráfico que más explica en menos espacio.
2. **Duración mediana por tipo de usuario:** barras horizontales.
3. **Demografía de abonados:** `tramo_edad` en Filas, `viajes` en Columnas, color = `genero`.

## Dashboard 3 · Rebalanceo (el diferenciador)

1. **Mapa** (`rebalanceo_estaciones`):
   - Coordenadas: `lng` en Columnas y `lat` en Filas.
   - Tipo de marca: Círculo.
   - Color: `flujo_neto_punta_am`, con paleta divergente **Rojo-Azul**, centro en 0 y rango −60 a +60.
   - Tamaño: `salidas_dia`.
   - Tooltip: nombre, barrio, amplitud y perfil.
2. **Ranking top 20:** `nombre` por `amplitud_rebalanceo`, color = `perfil`.
3. **Curva del día** (`flujo_horario`): crea el campo `Acumulado = RUNNING_SUM(SUM([flujo_neto_prom_dia]))`, calculado a lo largo de `hora`. Filtra por `tipo_dia` = Día laboral y por una estación (filtro de lista).
4. **Acción de dashboard:** al hacer clic en una estación del mapa se filtra la curva del día.
5. **Extra:** en el mapa de `flujo_horario`, arrastra `hora` a **Páginas** para animar las 24 horas y ver cómo las bicicletas fluyen hacia Midtown en la mañana y de vuelta en la tarde.

## Dashboard 4 · Expansión

1. **Matriz:** `carga_por_estacion_2017` en Columnas (escala logarítmica), `indice_crecimiento` en Filas, tamaño = `estaciones_2017`, color = `recomendacion` y etiqueta = `barrio`. Agrega una línea de referencia en Filas con el valor constante 1.
2. **Tabla:** barrio, puntaje, recomendación, ordenada por puntaje.
3. **Mapa de barrios:** `lat_2017`/`lng_2017`, tamaño = `puntaje_expansion`, color = `recomendacion`.

## Historia (Story) sugerida

1. "El sistema creció 21 % en un año y el clima explica gran parte de la variación diaria."
2. "Abonados y ocasionales son dos negocios distintos: oficina vs. paseo."
3. "El 17 % de las estaciones concentra la mitad del problema de rebalanceo."
4. "Densificar Manhattan bajo la calle 59 y crecer en Williamsburg y Greenpoint."

## Publicar

**Archivo → Guardar en Tableau Public**. Pega el enlace en el README (donde dice "enlace pendiente") y guarda capturas en `docs/img/`.
