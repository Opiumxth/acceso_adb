"""Configuracion central del proyecto.

Aqui se define, en un solo lugar:
  * la conexion a Oracle (DSN, esquema y usuario/clave de cada rol),
  * las rutas de los datos biometricos en disco (carpeta datos/),
  * los parametros de la camara.

Las claves NUNCA van en el codigo: se leen de variables de entorno o del
archivo .env de la raiz del repositorio (que esta en .gitignore). Ver
.env.example para la lista completa de variables.
"""
import os
from pathlib import Path

# Raiz del repositorio (src/ esta un nivel debajo)
BASE_DIR = Path(__file__).resolve().parent.parent
ENV_FILE = BASE_DIR / ".env"


def cargar_env(ruta=ENV_FILE):
    """Lee un archivo .env simple (CLAVE=valor) sin pisar variables ya definidas.

    Solo se ignoran las lineas vacias y las que empiezan con '#': un '#'
    dentro del valor (por ejemplo una clave) se conserva tal cual.
    """
    ruta = Path(ruta)
    if not ruta.is_file():
        return
    for linea in ruta.read_text(encoding="utf-8").splitlines():
        linea = linea.strip()
        if not linea or linea.startswith("#") or "=" not in linea:
            continue
        clave, valor = linea.split("=", 1)
        clave = clave.strip()
        valor = valor.strip()
        if len(valor) >= 2 and valor[0] == valor[-1] and valor[0] in "\"'":
            valor = valor[1:-1]
        os.environ.setdefault(clave, valor)


cargar_env()


def _entero(nombre, defecto):
    return int(os.environ.get(nombre, defecto))


def _decimal(nombre, defecto):
    return float(os.environ.get(nombre, defecto))


# ---------------------------------------------------------------------
# Oracle
# ---------------------------------------------------------------------
ORACLE_DSN = os.environ.get("ORACLE_DSN", "localhost:1521/XEPDB1")
ORACLE_SCHEMA = os.environ.get("ORACLE_SCHEMA", "ACCESO_OWNER")

# Un usuario Oracle por rol de la aplicacion (ver sql/00_admin.sql)
ROLES = ("punto", "vigilante", "docente", "admin")
USUARIOS_POR_DEFECTO = {
    "punto": "u_punto",
    "vigilante": "u_vigilante",
    "docente": "u_docente",
    "admin": "u_admin",
}


def credenciales(rol):
    """Devuelve (usuario, clave) del rol. La clave puede ser None si no esta definida."""
    if rol not in ROLES:
        raise ValueError(f"Rol desconocido: {rol!r}. Roles validos: {', '.join(ROLES)}")
    usuario = os.environ.get(f"DB_USER_{rol.upper()}") or USUARIOS_POR_DEFECTO[rol]
    clave = os.environ.get(f"DB_PASSWORD_{rol.upper()}") or None
    return usuario, clave


# ---------------------------------------------------------------------
# Datos biometricos en disco (no se versionan: datos/ esta en .gitignore)
# ---------------------------------------------------------------------
DATOS_DIR = Path(os.environ.get("DATOS_DIR", BASE_DIR / "datos")).resolve()
ROSTROS_DIR = DATOS_DIR / "faces"       # fotos de rostro: faces/<codigo>/
MODELOS_DIR = DATOS_DIR / "models"      # modelo LBPH: models/modelo_lbph_<codigo>.yml
QR_DIR = DATOS_DIR / "qrcodes"          # imagenes QR: qrcodes/qr_<codigo>.png


def ruta_rostros(codigo):
    return ROSTROS_DIR / str(codigo)


def ruta_modelo(codigo):
    return MODELOS_DIR / f"modelo_lbph_{codigo}.yml"


def ruta_qr(codigo):
    return QR_DIR / f"qr_{codigo}.png"


# ---------------------------------------------------------------------
# Punto de acceso y camara
# ---------------------------------------------------------------------
ID_PUNTO = _entero("ID_PUNTO", 1)                              # punto de control de este equipo
CAMERA_INDEX = _entero("CAMERA_INDEX", 0)
QR_TIMEOUT = _decimal("QR_TIMEOUT_SEGUNDOS", 30)               # espera maxima del QR
ROSTRO_TIMEOUT = _decimal("ROSTRO_TIMEOUT_SEGUNDOS", 20)       # espera maxima del rostro
TAM_ROSTRO = (200, 200)       # mismo tamano al entrenar y al verificar
MIN_ROSTRO = (100, 100)       # rostro minimo que se acepta al verificar
