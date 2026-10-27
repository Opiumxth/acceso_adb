"""Capa de acceso a datos: llama a los procedimientos almacenados de Oracle.

La aplicacion nunca lee ni escribe tablas; todo pasa por procedimientos
(p_* para operaciones y r_* para reportes). Los errores controlados de los
procedimientos (ORA-20001 a ORA-20999) se convierten en db.ErrorAplicacion.
"""
import functools
import re
from dataclasses import dataclass

import oracledb

import db


@dataclass(frozen=True)
class Persona:
    nombre: str
    tipo: str
    estado: str


@dataclass(frozen=True)
class ResultadoAcceso:
    resultado: str          # 'permitido' o 'denegado'
    motivo: object          # motivo de la denegacion; None si fue permitido
    id_acceso: int


def _traduce(funcion):
    """Convierte los errores ORA-200xx de un procedimiento en db.ErrorAplicacion."""
    @functools.wraps(funcion)
    def envoltura(*args, **kwargs):
        try:
            return funcion(*args, **kwargs)
        except oracledb.DatabaseError as exc:
            traducido = db.traducir_error(exc)
            if traducido is exc:
                raise
            raise traducido from exc
    return envoltura


_PATRON_PROC = re.compile(r"^[pr]_[a-z0-9_]+$")


# ---------------------------------------------------------------------
# Punto de acceso
# ---------------------------------------------------------------------
@_traduce
def verificar_persona(conn, codigo):
    """p_verificar_persona: devuelve Persona o None si el codigo no existe."""
    with conn.cursor() as cur:
        nombre = cur.var(str, 100)
        tipo = cur.var(str, 15)
        estado = cur.var(str, 12)
        existe = cur.var(int)
        cur.callproc("p_verificar_persona", [codigo, nombre, tipo, estado, existe])
        if existe.getvalue() != 1:
            return None
        return Persona(nombre.getvalue(), tipo.getvalue(), estado.getvalue())


@_traduce
def registrar_acceso(conn, codigo, id_punto, rostro_ok, confianza=None, metodo="qr_rostro"):
    """p_registrar_acceso: registra la lectura y devuelve ResultadoAcceso.

    Una denegacion no es un error: llega como resultado = 'denegado' y su motivo.
    """
    with conn.cursor() as cur:
        resultado = cur.var(str, 10)
        motivo = cur.var(str, 40)
        id_acceso = cur.var(int)
        cur.callproc(
            "p_registrar_acceso",
            [codigo, id_punto, 1 if rostro_ok else 0, confianza, metodo,
             resultado, motivo, id_acceso],
        )
        return ResultadoAcceso(resultado.getvalue(), motivo.getvalue(), id_acceso.getvalue())


@_traduce
def obtener_parametro(conn, nombre):
    """p_obtener_parametro: valor (texto) de un parametro de la tabla parametros."""
    with conn.cursor() as cur:
        valor = cur.var(str, 100)
        cur.callproc("p_obtener_parametro", [nombre, valor])
        return valor.getvalue()


def obtener_umbral_lbph(conn):
    """Confianza LBPH maxima aceptada (parametro UMBRAL_LBPH de la base)."""
    return float(obtener_parametro(conn, "UMBRAL_LBPH"))


# ---------------------------------------------------------------------
# Reportes y consultas que devuelven un REF CURSOR
# ---------------------------------------------------------------------
def _filas(cursor):
    columnas = [col[0].lower() for col in cursor.description]
    return [dict(zip(columnas, fila)) for fila in cursor.fetchall()]


@_traduce
def consultar_cursor(conn, procedimiento, *parametros):
    """Ejecuta un procedimiento p_*/r_* cuyo ultimo parametro es un REF CURSOR
    y devuelve las filas como lista de diccionarios (claves en minuscula)."""
    if not _PATRON_PROC.match(procedimiento):
        raise ValueError(f"Nombre de procedimiento no valido: {procedimiento!r}")
    with conn.cursor() as cur:
        ref = conn.cursor()
        try:
            cur.callproc(procedimiento, [*parametros, ref])
            return _filas(ref)
        finally:
            ref.close()


def listar_escuelas(conn):
    return consultar_cursor(conn, "r_escuelas")


# ---------------------------------------------------------------------
# Personas (rol administrador)
# ---------------------------------------------------------------------
@_traduce
def registrar_persona(conn, codigo, nombre, dni, tipo, correo=None,
                      id_escuela=None, ciclo=None, especialidad=None):
    """p_registrar_persona: alta en personas y en su subtipo. Devuelve id_persona."""
    with conn.cursor() as cur:
        id_persona = cur.var(int)
        cur.callproc(
            "p_registrar_persona",
            [codigo, nombre, dni, correo, tipo, id_escuela, ciclo, especialidad, id_persona],
        )
        return id_persona.getvalue()


@_traduce
def modificar_persona(conn, codigo, nombre=None, dni=None, correo=None, estado=None,
                      id_escuela=None, ciclo=None, especialidad=None):
    """p_modificar_persona: los valores None significan 'no cambiar'."""
    with conn.cursor() as cur:
        cur.callproc(
            "p_modificar_persona",
            [codigo, nombre, dni, correo, estado, id_escuela, ciclo, especialidad],
        )


@_traduce
def eliminar_persona(conn, codigo):
    """p_eliminar_persona: devuelve 'baja_logica' o 'eliminada'."""
    with conn.cursor() as cur:
        accion = cur.var(str, 20)
        cur.callproc("p_eliminar_persona", [codigo, accion])
        return accion.getvalue()


def listar_personas(conn):
    return consultar_cursor(conn, "p_listar_personas")


def buscar_personas(conn, texto=None, tipo=None, estado=None):
    return consultar_cursor(conn, "p_buscar_personas", texto, tipo, estado)


# ---------------------------------------------------------------------
# Hora local, sesiones y asistencia
# ---------------------------------------------------------------------
@_traduce
def obtener_desfase(conn):
    """p_obtener_desfase: minutos que la hora del servidor se adelanta a la hora
    local (300 con el servidor en UTC y America/Lima). servidor = local + desfase."""
    with conn.cursor() as cur:
        minutos = cur.var(int)
        cur.callproc("p_obtener_desfase", [minutos])
        return int(minutos.getvalue())


@_traduce
def crear_sesion(conn, id_seccion, hora_inicio, hora_fin):
    """p_crear_sesion: programa una sesion (horas en hora del servidor). Devuelve id_sesion."""
    with conn.cursor() as cur:
        id_sesion = cur.var(int)
        cur.callproc("p_crear_sesion", [id_seccion, hora_inicio, hora_fin, id_sesion])
        return id_sesion.getvalue()


@_traduce
def cancelar_sesion(conn, id_sesion):
    """p_cancelar_sesion: elimina una sesion programada que aun no tiene asistencias."""
    with conn.cursor() as cur:
        cur.callproc("p_cancelar_sesion", [id_sesion])


@_traduce
def cerrar_sesion(conn, id_sesion):
    """p_cerrar_sesion: devuelve (faltas registradas, inscripciones inhabilitadas)."""
    with conn.cursor() as cur:
        faltas = cur.var(int)
        inhabilitados = cur.var(int)
        cur.callproc("p_cerrar_sesion", [id_sesion, faltas, inhabilitados])
        return faltas.getvalue(), inhabilitados.getvalue()


# ---------------------------------------------------------------------
# Seguridad: pases, restricciones e incidencias
# ---------------------------------------------------------------------
@_traduce
def emitir_pase(conn, id_visitante, id_anfitrion, id_zona, desde, hasta, motivo=None):
    """p_emitir_pase (horas en hora del servidor). Devuelve id_pase."""
    with conn.cursor() as cur:
        id_pase = cur.var(int)
        cur.callproc("p_emitir_pase",
                     [id_visitante, id_anfitrion, id_zona, desde, hasta, motivo, id_pase])
        return id_pase.getvalue()


@_traduce
def revocar_pase(conn, id_pase):
    with conn.cursor() as cur:
        cur.callproc("p_revocar_pase", [id_pase])


@_traduce
def registrar_restriccion(conn, id_persona, motivo, fecha_fin=None):
    """p_registrar_restriccion (fecha_fin en hora del servidor o None). Devuelve id."""
    with conn.cursor() as cur:
        id_restriccion = cur.var(int)
        cur.callproc("p_registrar_restriccion", [id_persona, motivo, fecha_fin, id_restriccion])
        return id_restriccion.getvalue()


@_traduce
def levantar_restriccion(conn, id_restriccion):
    with conn.cursor() as cur:
        cur.callproc("p_levantar_restriccion", [id_restriccion])


@_traduce
def registrar_incidencia(conn, id_zona, id_persona, id_acceso, tipo, gravedad, descripcion):
    """p_registrar_incidencia (origen vigilante). Devuelve id_incidencia."""
    with conn.cursor() as cur:
        id_incidencia = cur.var(int)
        cur.callproc("p_registrar_incidencia",
                     [id_zona, id_persona, id_acceso, tipo, gravedad, descripcion, id_incidencia])
        return id_incidencia.getvalue()


@_traduce
def resolver_incidencia(conn, id_incidencia, estado="resuelta", comentario=None):
    """p_resolver_incidencia: estado 'en_revision' o 'resuelta'."""
    with conn.cursor() as cur:
        cur.callproc("p_resolver_incidencia", [id_incidencia, estado, comentario])


def buscar_persona_por_codigo(conn, codigo):
    """Devuelve la fila (dict) de la persona con ese codigo exacto, o None."""
    codigo = (codigo or "").strip()
    if not codigo:
        return None
    for fila in buscar_personas(conn, texto=codigo):
        if str(fila["codigo"]).strip() == codigo:
            return fila
    return None
