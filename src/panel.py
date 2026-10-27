"""Reglas del panel web: roles, permisos por pantalla y catalogo de reportes.

La seguridad real la da Oracle: cada rol se conecta con su propio usuario
(u_admin, u_vigilante o u_docente), que solo puede ejecutar los procedimientos
que le concede sql/06_permisos.sql. Los permisos de este modulo solo deciden
que pantallas, botones y reportes se muestran en el menu.
"""
import hmac
import os
from datetime import date, datetime

# rol -> nombre para mostrar
ROLES = {
    "admin": "Administrador",
    "vigilante": "Vigilante",
    "docente": "Docente",
}

# pantalla -> roles que pueden entrar
PERMISOS = {
    "dashboard": {"admin", "vigilante", "docente"},
    "personas": {"admin", "vigilante"},          # el vigilante solo busca
    "personas_editar": {"admin"},                # alta, edicion y baja
    "accesos": {"admin", "vigilante"},
    "asistencia": {"admin", "docente"},
    "sesiones_gestionar": {"admin"},             # programar y cerrar sesiones
    "incidencias": {"admin", "vigilante"},
    "pases": {"admin", "vigilante"},
    "restricciones": {"admin", "vigilante"},
    "reportes": {"admin", "vigilante", "docente"},
}

# (titulo del grupo, [(endpoint, etiqueta, icono, pantalla, prefijo de endpoint activo)])
_MENU = [
    ("Principal", [
        ("dashboard", "Dashboard", "fa-gauge", "dashboard", "dashboard"),
    ]),
    ("Seguridad", [
        ("accesos", "Bitácora de accesos", "fa-door-open", "accesos", "accesos"),
        ("incidencias", "Incidencias", "fa-triangle-exclamation", "incidencias", "incidencia"),
        ("pases", "Pases de visitantes", "fa-id-badge", "pases", "pase"),
        ("restricciones", "Restricciones", "fa-ban", "restricciones", "restriccion"),
    ]),
    ("Académico", [
        ("asistencia", "Asistencia", "fa-clipboard-user", "asistencia", "asistencia"),
    ]),
    ("Administración", [
        ("personas", "Personas", "fa-users", "personas", "persona"),
    ]),
    ("Análisis", [
        ("reportes", "Reportes", "fa-chart-column", "reportes", "reporte"),
    ]),
]


def puede(rol, pantalla):
    return rol in PERMISOS.get(pantalla, ())


def menu_para(rol):
    """Menu lateral filtrado por rol: lista de (titulo, [item, ...])."""
    menu = []
    for titulo, items in _MENU:
        visibles = [
            {"endpoint": e, "etiqueta": et, "icono": ic, "prefijo": pre}
            for (e, et, ic, pantalla, pre) in items if puede(rol, pantalla)
        ]
        if visibles:
            menu.append((titulo, visibles))
    return menu


# ---------------------------------------------------------------------
# Claves de acceso al panel (en .env; no son las claves de Oracle)
# ---------------------------------------------------------------------
def clave_panel(rol):
    """Clave del panel para el rol (variable PANEL_PASSWORD_<ROL>) o None."""
    return os.environ.get(f"PANEL_PASSWORD_{rol.upper()}") or None


def clave_correcta(rol, clave):
    esperada = clave_panel(rol)
    if not esperada:
        return False
    return hmac.compare_digest(esperada.encode("utf-8"), (clave or "").encode("utf-8"))


# ---------------------------------------------------------------------
# Catalogo de reportes (procedimientos r_*)
# ---------------------------------------------------------------------
ESTADOS_INCIDENCIA = ("abierta", "en_revision", "resuelta")
GRAVEDADES = ("baja", "media", "alta")

# tipos de parametro: seccion, sesion, zona (listas o enteros), fecha, opcion
REPORTES = {
    "asistencia-seccion": {
        "titulo": "Asistencia por sección",
        "procedimiento": "r_asistencia_seccion",
        "descripcion": "Presentes, tardanzas, faltas y porcentaje de asistencia de cada estudiante (solo sesiones cerradas).",
        "roles": {"admin", "docente"},
        "parametros": [
            {"nombre": "id_seccion", "etiqueta": "Sección", "tipo": "seccion", "obligatorio": True},
        ],
    },
    "asistencia-sesion": {
        "titulo": "Asistencia de una sesión",
        "procedimiento": "r_asistencia_sesion",
        "descripcion": "Un registro por inscrito: presente, tardanza, falta o sin registro (hora local).",
        "roles": {"admin", "docente"},
        "parametros": [
            {"nombre": "id_sesion", "etiqueta": "Número de sesión", "tipo": "sesion", "obligatorio": True},
        ],
    },
    "alumnos-en-riesgo": {
        "titulo": "Alumnos en riesgo",
        "procedimiento": "r_alumnos_en_riesgo",
        "descripcion": "Estudiantes inhabilitados o a una falta de serlo, según el límite de faltas.",
        "roles": {"admin", "docente"},
        "parametros": [
            {"nombre": "id_seccion", "etiqueta": "Sección (vacío = todas)", "tipo": "seccion", "obligatorio": False},
        ],
    },
    "ranking-tardanzas": {
        "titulo": "Ranking de tardanzas",
        "procedimiento": "r_ranking_tardanzas",
        "descripcion": "Estudiantes con más tardanzas entre dos fechas, con posición (RANK).",
        "roles": {"admin", "docente"},
        "parametros": [
            {"nombre": "desde", "etiqueta": "Desde", "tipo": "fecha", "obligatorio": False},
            {"nombre": "hasta", "etiqueta": "Hasta", "tipo": "fecha", "obligatorio": False},
        ],
    },
    "accesos-denegados": {
        "titulo": "Accesos denegados",
        "procedimiento": "r_accesos_denegados",
        "descripcion": "Denegados agrupados por motivo y zona, con subtotales y total general.",
        "roles": {"admin", "vigilante"},
        "parametros": [
            {"nombre": "desde", "etiqueta": "Desde", "tipo": "fecha", "obligatorio": False},
            {"nombre": "hasta", "etiqueta": "Hasta", "tipo": "fecha", "obligatorio": False},
        ],
    },
    "incidencias": {
        "titulo": "Incidencias",
        "procedimiento": "r_incidencias",
        "descripcion": "Incidencias con filtro por estado y gravedad; las más graves primero.",
        "roles": {"admin", "vigilante"},
        "parametros": [
            {"nombre": "estado", "etiqueta": "Estado", "tipo": "opcion", "obligatorio": False,
             "opciones": ESTADOS_INCIDENCIA},
            {"nombre": "gravedad", "etiqueta": "Gravedad", "tipo": "opcion", "obligatorio": False,
             "opciones": GRAVEDADES},
        ],
    },
    "pases-vigentes": {
        "titulo": "Pases vigentes",
        "procedimiento": "r_pases_vigentes",
        "descripcion": "Pases de visitantes activos y dentro de su vigencia en este momento.",
        "roles": {"admin", "vigilante"},
        "parametros": [],
    },
    "uso-aulas": {
        "titulo": "Uso de aulas frente a sesiones",
        "procedimiento": "r_uso_aulas_vs_sesiones",
        "descripcion": "Por aula y laboratorio: sesiones programadas frente a accesos, asistentes y ocupación.",
        "roles": {"admin"},
        "parametros": [
            {"nombre": "fecha", "etiqueta": "Fecha (vacío = hoy)", "tipo": "fecha", "obligatorio": False},
        ],
    },
    "flujo-por-hora": {
        "titulo": "Flujo de personas por hora",
        "procedimiento": "r_flujo_por_hora",
        "descripcion": "Las 24 horas de un día con permitidos, denegados, entradas y salidas.",
        "roles": {"admin", "vigilante"},
        "parametros": [
            {"nombre": "fecha", "etiqueta": "Fecha (vacío = hoy)", "tipo": "fecha", "obligatorio": False},
            {"nombre": "id_zona", "etiqueta": "Zona (vacío = todas)", "tipo": "zona", "obligatorio": False},
        ],
    },
}


def reportes_para(rol):
    """[(clave, definicion)] de los reportes que el rol puede ejecutar."""
    return [(clave, r) for clave, r in REPORTES.items() if rol in r["roles"]]


def convertir_parametro(definicion, texto):
    """Convierte el texto de un formulario al valor del parametro del procedimiento.

    Devuelve None si esta vacio y no es obligatorio; lanza ValueError con un
    mensaje para el usuario si el dato no es valido.
    """
    etiqueta = definicion["etiqueta"]
    texto = (texto or "").strip()
    if not texto:
        if definicion.get("obligatorio"):
            raise ValueError(f"Falta el dato: {etiqueta}.")
        return None
    tipo = definicion["tipo"]
    if tipo in ("seccion", "sesion", "zona"):
        if not texto.isdigit():
            raise ValueError(f"{etiqueta} debe ser un número.")
        return int(texto)
    if tipo == "fecha":
        try:
            return datetime.strptime(texto, "%Y-%m-%d").date()
        except ValueError:
            raise ValueError(f"{etiqueta}: la fecha debe tener el formato AAAA-MM-DD.") from None
    if tipo == "opcion":
        if texto not in definicion["opciones"]:
            raise ValueError(f"{etiqueta}: valor no válido.")
        return texto
    raise ValueError(f"Tipo de parámetro no soportado: {tipo}")


# ---------------------------------------------------------------------
# Formato para las plantillas
# ---------------------------------------------------------------------
def valor(v):
    """Texto para mostrar en una celda: None -> '-', 3.0 -> '3'."""
    if v is None:
        return "-"
    if isinstance(v, float) and v.is_integer():
        return str(int(v))
    if isinstance(v, datetime):
        return v.strftime("%Y-%m-%d %H:%M")
    if isinstance(v, date):
        return v.isoformat()
    return str(v).strip()


_CLASES = {
    # resultados y estados
    "permitido": "success", "denegado": "danger",
    "activo": "success", "activa": "success", "inactivo": "secondary", "suspendido": "warning",
    "inhabilitado": "danger", "retirado": "secondary", "en_riesgo": "warning",
    "abierta": "danger", "en_revision": "warning", "resuelta": "success",
    "programada": "info", "en_curso": "primary", "cerrada": "secondary",
    "presente": "success", "tardanza": "warning", "falta": "danger", "sin_registro": "secondary",
    # gravedad
    "alta": "danger", "media": "warning", "baja": "info",
    # origen
    "sistema": "secondary", "vigilante": "primary",
}


def clase_insignia(v):
    """Color de Bootstrap para una insignia segun el valor."""
    return _CLASES.get(str(v).strip(), "secondary")


def celda_csv(v):
    """Valor para un CSV; neutraliza las celdas que Excel leeria como formula."""
    texto = valor(v)
    if texto == "-" and v is None:
        return ""
    if texto and texto[0] in "=+-@\t\r" and isinstance(v, str):
        return "'" + texto
    return texto


# ---------------------------------------------------------------------
# Encabezados de columna (las claves de los cursores no llevan tildes)
# ---------------------------------------------------------------------
ETIQUETAS_COLUMNAS = {
    "id_persona": "ID", "id_acceso": "N.º acceso", "id_seccion": "Sección", "id_sesion": "Sesión",
    "id_incidencia": "N.º", "id_pase": "N.º", "id_restriccion": "N.º", "codigo": "Código",
    "dni": "DNI", "fecha_registro": "Registro", "pct_asistencia": "% asistencia",
    "pct_faltas": "% faltas", "pct_tardanza": "% tardanza", "limite_pct": "Límite %",
    "estado_inscripcion": "Inscripción", "hora_registro": "Hora de registro",
    "sesiones_cerradas": "Sesiones cerradas", "sesiones_abiertas": "Sesiones abiertas",
    "tardanzas": "Tardanzas", "codigos_distintos": "Códigos distintos",
    "codigo_persona": "Código persona", "codigo_visitante": "Código visitante",
    "zona_destino": "Zona de destino", "horas_restantes": "Horas restantes",
    "inscritos_esperados": "Inscritos esperados", "accesos_permitidos": "Accesos permitidos",
    "personas_distintas": "Personas distintas", "ocupacion_pct": "Ocupación %",
    "observacion": "Observación", "descripcion": "Descripción", "nombre_curso": "Curso",
    "curso": "Curso", "tipo_persona": "Tipo", "fecha_hora": "Fecha y hora",
    "puesto": "Puesto", "asistidas": "Asistidas", "motivo": "Motivo",
    "sesiones": "Sesiones", "inscritos": "Inscritos", "confianza": "Confianza",
    "metodo": "Método", "hora": "Hora", "especialidad": "Especialidad",
    "ultimo": "Último", "primero": "Primero", "fecha": "Fecha", "zona": "Zona",
}


def etiqueta_columna(clave):
    """Encabezado legible para una columna de un cursor."""
    return ETIQUETAS_COLUMNAS.get(clave) or clave.replace("_", " ").capitalize()
