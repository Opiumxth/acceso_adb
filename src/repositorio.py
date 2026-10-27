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
