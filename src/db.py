"""Conexion a Oracle.

get_connection(rol) abre la sesion con el usuario Oracle del rol (u_punto,
u_vigilante, u_docente o u_admin) y fija el esquema dueno de los objetos con

    alter session set current_schema = ACCESO_OWNER

para poder llamar a los procedimientos sin prefijo. Los usuarios de aplicacion
no tienen acceso a las tablas: solo ejecutan procedimientos.
"""
import re
import oracledb

import config


class ConfiguracionError(RuntimeError):
    """Falta algun dato de configuracion (por ejemplo la clave del rol)."""


class ErrorAplicacion(Exception):
    """Error controlado de un procedimiento (ORA-20001 a ORA-20999).

    codigo: numero ORA (por ejemplo 20002); mensaje: texto para mostrar.
    """

    def __init__(self, codigo, mensaje):
        super().__init__(mensaje)
        self.codigo = codigo
        self.mensaje = mensaje


_PATRON_APP = re.compile(r"ORA-(20\d{3}): (.*)")
_PATRON_ESQUEMA = re.compile(r"^[A-Za-z][A-Za-z0-9_$#]*$")


def traducir_error(exc):
    """Convierte un oracledb.DatabaseError en ErrorAplicacion si viene de un
    raise_application_error; si no, devuelve la excepcion original."""
    texto = str(exc)
    encontrado = _PATRON_APP.search(texto)
    if encontrado:
        codigo = int(encontrado.group(1))
        mensaje = encontrado.group(2).splitlines()[0].strip()
        # los -20099 vienen como "p_xxx: ORA-nnnnn: detalle"
        return ErrorAplicacion(codigo, mensaje)
    return exc


def get_connection(rol, password=None):
    """Abre una conexion para el rol indicado.

    password: si se indica, reemplaza a la clave del archivo .env (sirve para
    pedirla por consola).
    """
    usuario, clave = config.credenciales(rol)
    if password is not None:
        clave = password
    if not clave:
        raise ConfiguracionError(
            f"Falta la clave del rol '{rol}': defina DB_PASSWORD_{rol.upper()} "
            f"en el archivo .env (ver .env.example)."
        )
    if not _PATRON_ESQUEMA.match(config.ORACLE_SCHEMA):
        raise ConfiguracionError(f"Nombre de esquema no valido: {config.ORACLE_SCHEMA!r}")

    conexion = oracledb.connect(user=usuario, password=clave, dsn=config.ORACLE_DSN)
    with conexion.cursor() as cur:
        cur.execute(f"alter session set current_schema = {config.ORACLE_SCHEMA}")
    return conexion
