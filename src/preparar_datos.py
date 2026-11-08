"""Capa de análisis: corrige y enriquece las exportaciones de BigQuery y genera las tablas para Tableau.

Uso:  python src/preparar_datos.py

Entradas:  data/bigquery/*.csv   (exportadas con sql/02_exportar.sql)
Salidas:   data/tableau/*.csv    (listas para el dashboard)
"""

from __future__ import annotations

from pathlib import Path

import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
BQ = ROOT / "data" / "bigquery"
OUT = ROOT / "data" / "tableau"

# --------------------------------------------------------------------------------------------- #
# Correcciones geográficas
# La tabla de códigos postales del curso no incluye el 11249 (Williamsburg norte, creado en 2011
# a partir del 11211) y 3 estaciones quedan fuera de todo polígono postal (muelle, borde costero).
# Se asignan al barrio de la tabla que les corresponde.
# --------------------------------------------------------------------------------------------- #
ZIP_FALTANTES = {11249: ("Brooklyn", "Greenpoint")}            # 11211 pertenece a "Greenpoint"
ESTACIONES_SIN_ZIP = {
    3256: ("Manhattan", "Greenwich Village and Soho"),          # Pier 40 - Hudson River Park
    3514: ("Queens", "Northwest Queens"),                        # Astoria Park S & Shore Blvd
    3532: ("Queens", "Northwest Queens"),                        # Ditmars Blvd & 19 St
}
# Meses con datos en la tabla pública (falta oct-2016 a mar-2017, ver notebook)
MESES_COMPARABLES = range(4, 10)    # abril a septiembre: presentes en ambos años


def corregir_barrios(df: pd.DataFrame, id_col: str = "station_id") -> pd.DataFrame:
    """Rellena distrito y barrio de las estaciones que quedaron como 'Sin dato'."""
    df = df.copy()
    if "zip_code" in df.columns:
        for zip_code, (dist, barrio) in ZIP_FALTANTES.items():
            m = df["zip_code"] == zip_code
            df.loc[m, ["distrito", "barrio"]] = [dist, barrio]
    for est, (dist, barrio) in ESTACIONES_SIN_ZIP.items():
        m = df[id_col] == est
        df.loc[m, ["distrito", "barrio"]] = [dist, barrio]
    return df


def cargar() -> dict[str, pd.DataFrame]:
    d = {p.stem: pd.read_csv(p) for p in BQ.glob("*.csv")}
    d["dim_estaciones"] = corregir_barrios(d["dim_estaciones"])
    d["mart_estaciones"] = corregir_barrios(d["mart_estaciones"])
    d["mart_flujo_horario"] = corregir_barrios(
        d["mart_flujo_horario"].merge(d["dim_estaciones"][["station_id", "zip_code"]], on="station_id", how="left"))
    d["mart_demanda_diaria"]["fecha"] = pd.to_datetime(d["mart_demanda_diaria"]["fecha"])
    return d


def demanda_diaria(d: dict) -> pd.DataFrame:
    """Una fila por día: viajes totales y por tipo de usuario, más el clima."""
    dd = d["mart_demanda_diaria"]
    clima_cols = ["fecha", "anio", "mes", "dia_semana", "es_fin_de_semana", "temporada", "temp_media_c",
                  "temp_max_c", "precipitacion_mm", "viento_kmh", "hubo_lluvia", "hubo_nieve"]
    base = dd[clima_cols].drop_duplicates("fecha")
    piv = dd.pivot_table(index="fecha", columns="tipo_usuario", values="viajes", aggfunc="sum").reset_index()
    piv.columns.name = None
    out = base.merge(piv, on="fecha")
    out["viajes"] = out["Abonado"] + out["Ocasional"]
    out["precipitacion_mm"] = out["precipitacion_mm"].fillna(0)
    out["tramo_lluvia"] = pd.cut(out["precipitacion_mm"], [-0.1, 0, 5, 15, 1000],
                                 labels=["Sin lluvia", "Lluvia leve (<5 mm)", "Moderada (5-15 mm)", "Fuerte (>15 mm)"])
    out["tramo_temp"] = pd.cut(out["temp_max_c"], [-50, 5, 15, 25, 50],
                               labels=["< 5 °C", "5-15 °C", "15-25 °C", "> 25 °C"])
    return out.sort_values("fecha")


def rebalanceo(d: dict) -> pd.DataFrame:
    """Necesidad de rebalanceo por estación en un día laboral típico de 2017.

    Se acumula el flujo neto (llegadas - salidas) hora a hora desde la medianoche.
    - deficit_max: cuántas bicicletas faltarían en el peor momento si la estación partiera con 0 extra.
    - amplitud: diferencia entre el punto más lleno y el más vacío del día = bicicletas que
      el sistema debe mover (o anclajes que debe tener libres) para que la estación no colapse.
    """
    f = d["mart_flujo_horario"]
    w = f[f["tipo_dia"] == "Día laboral"].sort_values(["station_id", "hora"]).copy()
    w["acumulado"] = w.groupby("station_id")["flujo_neto_prom_dia"].cumsum()
    w["punta_am"] = w["hora"].between(7, 9)
    w["punta_pm"] = w["hora"].between(17, 19)
    g = w.groupby(["station_id", "nombre", "distrito", "barrio", "lat", "lng"]).agg(
        salidas_dia=("salidas_prom_dia", "sum"),
        llegadas_dia=("llegadas_prom_dia", "sum"),
        flujo_neto_dia=("flujo_neto_prom_dia", "sum"),
        minimo_acumulado=("acumulado", "min"),
        maximo_acumulado=("acumulado", "max"),
    ).reset_index()
    am = w[w["punta_am"]].groupby("station_id")["flujo_neto_prom_dia"].sum().rename("flujo_neto_punta_am")
    pm = w[w["punta_pm"]].groupby("station_id")["flujo_neto_prom_dia"].sum().rename("flujo_neto_punta_pm")
    g = g.merge(am, on="station_id", how="left").merge(pm, on="station_id", how="left")
    g["amplitud_rebalanceo"] = (g["maximo_acumulado"] - g["minimo_acumulado"]).round(1)
    g["perfil"] = np.select(
        [g["flujo_neto_punta_am"] <= -15, g["flujo_neto_punta_am"] >= 15],
        ["Se vacía en la mañana (origen)", "Se llena en la mañana (destino)"],
        default="Equilibrada")
    g = g.sort_values("amplitud_rebalanceo", ascending=False)
    g["ranking"] = np.arange(1, len(g) + 1)
    g["pct_acumulado_necesidad"] = (g["amplitud_rebalanceo"].cumsum() / g["amplitud_rebalanceo"].sum()).round(4)
    metricas = [c for c in g.columns if c not in ("station_id", "nombre", "distrito", "barrio", "lat", "lng", "perfil", "ranking")]
    g[metricas] = g[metricas].round(2)          # las coordenadas se dejan completas
    return g


def barrios(d: dict, reb: pd.DataFrame) -> pd.DataFrame:
    """Indicadores por barrio para decidir dónde abrir estaciones.

    - carga_por_estacion: salidas por estación por día con operación (2017). Alta = estaciones saturadas.
    - indice_crecimiento: cuánto creció la carga por estación del barrio, relativo a cuánto creció en
      el sistema completo (1 = igual que el sistema; > 1 = cada estación del barrio se llenó más rápido).
      Los años cubren meses distintos (2016: ene-sep; 2017: abr-dic), por eso se compara contra el
      sistema: así se neutraliza la estacionalidad que afecta a todos por igual.
    """
    e = d["mart_estaciones"].copy()
    e["salidas_por_dia"] = e["salidas"] / e["dias_con_salidas"]
    b = (e.groupby(["distrito", "barrio", "anio"])
           .agg(estaciones=("station_id", "nunique"), salidas=("salidas", "sum"),
                carga_por_estacion=("salidas_por_dia", "mean"), pct_abonados=("pct_abonados", "mean"),
                lat=("lat", "mean"), lng=("lng", "mean"))
           .reset_index())
    w = b.pivot_table(index=["distrito", "barrio"], columns="anio",
                      values=["estaciones", "carga_por_estacion", "pct_abonados", "lat", "lng"]).reset_index()
    w.columns = ["_".join(str(c) for c in col if c != "").strip("_") for col in w.columns]
    sistema = e.groupby("anio")["salidas_por_dia"].mean()          # carga promedio por estación del sistema
    ratio_sistema = sistema[2017] / sistema[2016]
    w["indice_crecimiento"] = ((w["carga_por_estacion_2017"] / w["carga_por_estacion_2016"]) / ratio_sistema).round(2)
    amp = reb.groupby("barrio")["amplitud_rebalanceo"].mean().rename("rebalanceo_prom_estacion")
    w = w.merge(amp, on="barrio", how="left")
    w = w[(w["estaciones_2017"].fillna(0) >= 2) & (w["distrito"] != "Jersey City (NJ)")].copy()   # ≥ 2 estaciones
    # puntaje 0-100: 50 % saturación, 30 % crecimiento, 20 % presión de rebalanceo (rangos percentiles)
    w["puntaje_expansion"] = (100 * (0.5 * w["carga_por_estacion_2017"].rank(pct=True)
                                     + 0.3 * w["indice_crecimiento"].rank(pct=True, na_option="bottom")
                                     + 0.2 * w["rebalanceo_prom_estacion"].rank(pct=True))).round(0)
    w["recomendacion"] = np.select(
        [w["puntaje_expansion"] >= 70, w["puntaje_expansion"] >= 45],
        ["Prioridad alta: densificar", "Prioridad media: monitorear"], default="Sin urgencia")
    keep = ["distrito", "barrio", "estaciones_2016", "estaciones_2017", "carga_por_estacion_2016",
            "carga_por_estacion_2017", "indice_crecimiento", "rebalanceo_prom_estacion", "pct_abonados_2017",
            "puntaje_expansion", "recomendacion", "lat_2017", "lng_2017"]
    w = w[keep].sort_values("puntaje_expansion", ascending=False)
    num = [c for c in w.select_dtypes("number").columns if c not in ("lat_2017", "lng_2017")]
    w[num] = w[num].round(2)
    return w


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    d = cargar()
    dem = demanda_diaria(d)
    reb = rebalanceo(d)
    bar = barrios(d, reb)
    salidas = {
        "demanda_diaria_clima": dem,
        "rebalanceo_estaciones": reb,
        "expansion_barrios": bar,
        "estaciones_anual": d["mart_estaciones"],
        "flujo_horario": d["mart_flujo_horario"].drop(columns="zip_code"),
        "perfil_usuarios": d["mart_perfil_usuarios"],
        "rutas_top": d["mart_rutas"],
        "abonados_edad_genero": d["mart_edad_genero"],
    }
    for nombre, df in salidas.items():
        df.to_csv(OUT / f"{nombre}.csv", index=False, encoding="utf-8")
        print(f"{nombre:24s} {len(df):>7,} filas")


if __name__ == "__main__":
    main()
