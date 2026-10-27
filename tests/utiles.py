"""Utilidades compartidas por las pruebas."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

import db  # noqa: E402
import repositorio  # noqa: E402


def maximo_incidencia():
    """Mayor id de incidencia existente (punto de referencia antes de una prueba)."""
    conn = db.get_connection("vigilante")
    try:
        filas = repositorio.consultar_cursor(conn, "r_incidencias", None, None)
        return max([f["id_incidencia"] for f in filas] or [0])
    finally:
        conn.close()


def cerrar_incidencias_nuevas(desde_id, comentario="Cerrada por la prueba automatica"):
    """Resuelve las incidencias creadas despues de desde_id.

    Las lecturas de prueba en el punto de control disparan incidencias reales
    (persona restringida, intentos reiterados); se cierran para que no queden
    abiertas en el dashboard.
    """
    conn = db.get_connection("vigilante")
    try:
        for fila in repositorio.consultar_cursor(conn, "r_incidencias", None, None):
            if fila["id_incidencia"] > desde_id and fila["estado"] != "resuelta":
                repositorio.resolver_incidencia(conn, fila["id_incidencia"], "resuelta", comentario)
    finally:
        conn.close()
