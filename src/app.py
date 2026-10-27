"""Panel web del Sistema de Control de Acceso, Asistencia y Seguridad Universitaria.

Pantallas: dashboard, personas, bitacora de accesos, asistencia, incidencias,
pases, restricciones y reportes (los procedimientos r_*).

Cada rol inicia sesion con su clave del panel (PANEL_PASSWORD_<ROL> en .env) y
TODAS sus consultas se hacen con su propio usuario de Oracle (u_admin,
u_vigilante o u_docente): la base, no esta aplicacion, decide que puede hacer.
Ningun usuario lee tablas; todo pasa por procedimientos almacenados.

Uso:
    ./venv/bin/python src/app.py            # http://127.0.0.1:5000
"""
import csv
import hmac
import io
import logging
import os
import re
import secrets
import sys
import time
from datetime import datetime, timedelta
from functools import wraps

import oracledb
from flask import (Flask, Response, abort, flash, g, redirect, render_template,
                   request, session, url_for)

import db            # carga .env (config) antes de leer las variables del panel
import panel
import repositorio

app = Flask(__name__)
app.config.update(
    SECRET_KEY=os.environ.get("PANEL_SECRET_KEY") or secrets.token_hex(32),
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SAMESITE="Lax",
    PERMANENT_SESSION_LIFETIME=timedelta(hours=8),
    MAX_CONTENT_LENGTH=64 * 1024,
)
app.jinja_env.filters["valor"] = panel.valor
app.jinja_env.filters["insignia"] = panel.clase_insignia
app.jinja_env.filters["columna"] = panel.etiqueta_columna

TIPOS_PERSONA = ("estudiante", "docente", "visitante", "vigilante", "administrativo")
ESTADOS_PERSONA = ("activo", "inactivo", "suspendido")
_CODIGO = re.compile(r"^\d{8}$")


# ---------------------------------------------------------------------
# Sesion, permisos y CSRF
# ---------------------------------------------------------------------
def csrf_token():
    if "csrf" not in session:
        session["csrf"] = secrets.token_urlsafe(32)
    return session["csrf"]


# global de Jinja (no solo contexto): los macros importados tambien lo necesitan
app.jinja_env.globals["csrf_token"] = csrf_token


@app.before_request
def proteger_formularios():
    """Todo POST debe traer el token CSRF de la sesion."""
    if request.method == "POST":
        enviado = request.form.get("csrf_token", "")
        esperado = session.get("csrf", "")
        if not esperado or not hmac.compare_digest(enviado, esperado):
            abort(400, description="El formulario venció o no es válido. Recargue la página e intente de nuevo.")


@app.context_processor
def contexto():
    rol = session.get("rol")
    return {
        "csrf_token": csrf_token,
        "rol": rol,
        "nombre_rol": panel.ROLES.get(rol),
        "puede": lambda pantalla: bool(rol) and panel.puede(rol, pantalla),
        "menu": panel.menu_para(rol) if rol else [],
    }


def requiere(pantalla):
    """Exige sesion iniciada y un rol con permiso para la pantalla."""
    def decorador(vista):
        @wraps(vista)
        def envoltura(*args, **kwargs):
            if "rol" not in session:
                return redirect(url_for("login", siguiente=request.full_path.rstrip("?")))
            if not panel.puede(session["rol"], pantalla):
                abort(403)
            return vista(*args, **kwargs)
        return envoltura
    return decorador


# ---------------------------------------------------------------------
# Conexion a Oracle: una por solicitud, con el usuario del rol
# ---------------------------------------------------------------------
def conexion():
    if "conn" not in g:
        g.conn = db.get_connection(session["rol"])
    return g.conn


@app.teardown_request
def cerrar_conexion(_exc):
    conn = g.pop("conn", None)
    if conn is not None:
        try:
            conn.close()
        except oracledb.Error:
            pass


def consultar(procedimiento, *parametros):
    return repositorio.consultar_cursor(conexion(), procedimiento, *parametros)


def desfase_minutos():
    if "desfase" not in g:
        g.desfase = repositorio.obtener_desfase(conexion())
    return g.desfase


def ahora_local():
    """Fecha y hora actuales segun la hora local del campus (de r_resumen_hoy)."""
    if "ahora_local" not in g:
        fila = consultar("r_resumen_hoy")[0]
        g.ahora_local = datetime.strptime(fila["fecha_hora_local"], "%Y-%m-%d %H:%M")
    return g.ahora_local


def hoy_local():
    return ahora_local().date()


def local_a_servidor(texto):
    """Convierte 'AAAA-MM-DDTHH:MM' (hora local, de un input datetime-local) a la
    hora del servidor, que es la que esperan los procedimientos. None si esta vacio."""
    texto = (texto or "").strip()
    if not texto:
        return None
    for formato in ("%Y-%m-%dT%H:%M", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%d %H:%M"):
        try:
            return datetime.strptime(texto, formato) + timedelta(minutes=desfase_minutos())
        except ValueError:
            continue
    raise ValueError("La fecha y hora deben tener el formato AAAA-MM-DD HH:MM.")


def entero_arg(nombre):
    texto = (request.args.get(nombre) or "").strip()
    if not texto:
        return None
    if not texto.isdigit():
        abort(400, description=f"El dato '{nombre}' debe ser un número.")
    return int(texto)


def fecha_arg(nombre, defecto=None):
    texto = (request.args.get(nombre) or "").strip()
    if not texto:
        return defecto
    try:
        return datetime.strptime(texto, "%Y-%m-%d").date()
    except ValueError:
        abort(400, description=f"La fecha '{nombre}' debe tener el formato AAAA-MM-DD.")


def persona_por_codigo(codigo):
    fila = repositorio.buscar_persona_por_codigo(conexion(), codigo)
    if fila is None:
        raise ValueError(f"No existe una persona con el código {(codigo or '').strip() or '(vacío)'}.")
    return fila


def entero_form(nombre, etiqueta, obligatorio=True):
    texto = (request.form.get(nombre) or "").strip()
    if not texto:
        if obligatorio:
            raise ValueError(f"Falta el dato: {etiqueta}.")
        return None
    if not texto.isdigit():
        raise ValueError(f"{etiqueta} debe ser un número.")
    return int(texto)


def intentar(operacion, exito, destino):
    """Ejecuta una accion de formulario: informa el resultado y redirige.

    exito: texto fijo, o funcion que recibe lo que devolvio operacion() y
    devuelve el texto (nunca se usa str.format sobre datos del usuario).
    Los datos invalidos (ValueError) y los errores controlados de Oracle se
    muestran como aviso, sin romper la pagina.
    """
    try:
        resultado = operacion()
        flash(exito(resultado) if callable(exito) else exito, "success")
    except ValueError as exc:
        flash(str(exc), "danger")
    except db.ErrorAplicacion as exc:
        flash(exc.mensaje, "danger")
    return redirect(destino)


# ---------------------------------------------------------------------
# Inicio y cierre de sesion
# ---------------------------------------------------------------------
_FALLOS = {}            # ip -> instantes de los intentos fallidos
_MAX_FALLOS = 5
_VENTANA_FALLOS = 300   # segundos


def _bloqueada(ip):
    ahora = time.time()
    recientes = [t for t in _FALLOS.get(ip, []) if ahora - t < _VENTANA_FALLOS]
    _FALLOS[ip] = recientes
    return len(recientes) >= _MAX_FALLOS


@app.route("/login", methods=["GET", "POST"])
def login():
    roles = [(r, nombre) for r, nombre in panel.ROLES.items() if panel.clave_panel(r)]
    if request.method == "POST":
        ip = request.remote_addr or "?"
        if _bloqueada(ip):
            flash("Demasiados intentos fallidos. Espere unos minutos e intente de nuevo.", "danger")
            return render_template("login.html", roles=roles), 429
        rol = request.form.get("rol", "")
        if rol in panel.ROLES and panel.clave_correcta(rol, request.form.get("clave", "")):
            session.clear()
            session["rol"] = rol
            session.permanent = True
            csrf_token()
            _FALLOS.pop(ip, None)
            destino = request.args.get("siguiente", "")
            if not destino.startswith("/") or destino.startswith("//") or destino.startswith("/login"):
                destino = url_for("dashboard")
            return redirect(destino)
        _FALLOS.setdefault(ip, []).append(time.time())
        time.sleep(0.4)  # frena los intentos por fuerza bruta
        flash("Rol o clave incorrectos.", "danger")
        return render_template("login.html", roles=roles), 401
    if "rol" in session:
        return redirect(url_for("dashboard"))
    return render_template("login.html", roles=roles)


@app.post("/logout")
def logout():
    session.clear()
    flash("Sesión cerrada.", "info")
    return redirect(url_for("login"))


# ---------------------------------------------------------------------
# Dashboard
# ---------------------------------------------------------------------
@app.route("/")
@requiere("dashboard")
def dashboard():
    if session["rol"] == "docente":
        return render_template("dashboard_docente.html", secciones=consultar("r_secciones"))

    resumen = consultar("r_resumen_hoy")[0]
    flujo = consultar("r_flujo_por_hora", None, None)
    maximo = max([f["total"] for f in flujo] or [0])
    for hora in flujo:
        total = hora["total"]
        hora["pct_total"] = round(100 * total / maximo, 1) if maximo else 0
        hora["pct_no"] = round(100 * hora["denegados"] / total, 1) if total else 0
        hora["pct_ok"] = round(100 - hora["pct_no"], 1) if total else 0
    return render_template(
        "dashboard.html",
        resumen=resumen,
        flujo=flujo,
        denegados=consultar("r_accesos_bitacora", None, None, "denegado", None, None, 8),
        incidencias=consultar("r_incidencias", "abierta", None)[:6],
    )


# ---------------------------------------------------------------------
# Personas
# ---------------------------------------------------------------------
@app.route("/personas")
@requiere("personas")
def personas():
    texto = (request.args.get("texto") or "").strip()
    tipo = request.args.get("tipo") or ""
    estado = request.args.get("estado") or ""
    if (tipo and tipo not in TIPOS_PERSONA) or (estado and estado not in ESTADOS_PERSONA):
        abort(400, description="Filtro no válido.")
    filas = repositorio.buscar_personas(conexion(), texto or None, tipo or None, estado or None)
    return render_template("personas.html", filas=filas, texto=texto, tipo=tipo, estado=estado,
                           tipos=TIPOS_PERSONA, estados=ESTADOS_PERSONA)


def _datos_formulario_persona():
    f = request.form
    return {
        "codigo": (f.get("codigo") or "").strip(),
        "tipo": (f.get("tipo") or "").strip(),
        "nombre": (f.get("nombre") or "").strip(),
        "dni": (f.get("dni") or "").strip(),
        "correo": (f.get("correo") or "").strip() or None,
        "id_escuela": entero_form("id_escuela", "Escuela", obligatorio=False),
        "ciclo": entero_form("ciclo", "Ciclo", obligatorio=False),
        "especialidad": (f.get("especialidad") or "").strip() or None,
    }


@app.route("/personas/nueva", methods=["GET", "POST"])
@requiere("personas_editar")
def persona_nueva():
    escuelas = repositorio.listar_escuelas(conexion())
    datos = {}
    if request.method == "POST":
        try:
            datos = _datos_formulario_persona()
            repositorio.registrar_persona(conexion(), **datos)
            flash(f"Persona {datos['codigo']} registrada. El rostro se registra en el punto de acceso "
                  "(menú de consola, opción 2.3).", "success")
            return redirect(url_for("personas", texto=datos["codigo"]))
        except ValueError as exc:
            flash(str(exc), "danger")
        except db.ErrorAplicacion as exc:
            flash(exc.mensaje, "danger")
    return render_template("persona_form.html", editar=False, persona=datos, escuelas=escuelas,
                           tipos=TIPOS_PERSONA, estados=ESTADOS_PERSONA)


@app.route("/personas/<codigo>/editar", methods=["GET", "POST"])
@requiere("personas_editar")
def persona_editar(codigo):
    if not _CODIGO.match(codigo):
        abort(404)
    persona = repositorio.buscar_persona_por_codigo(conexion(), codigo)
    if persona is None:
        abort(404)
    if request.method == "POST":
        try:
            datos = _datos_formulario_persona()
            repositorio.modificar_persona(
                conexion(), codigo, nombre=datos["nombre"] or None, dni=datos["dni"] or None,
                correo=datos["correo"], estado=(request.form.get("estado") or None),
                id_escuela=datos["id_escuela"], ciclo=datos["ciclo"], especialidad=datos["especialidad"])
            flash(f"Persona {codigo} actualizada.", "success")
            return redirect(url_for("personas", texto=codigo))
        except ValueError as exc:
            flash(str(exc), "danger")
        except db.ErrorAplicacion as exc:
            flash(exc.mensaje, "danger")
    return render_template("persona_form.html", editar=True, persona=persona,
                           escuelas=repositorio.listar_escuelas(conexion()),
                           tipos=TIPOS_PERSONA, estados=ESTADOS_PERSONA)


@app.post("/personas/<codigo>/eliminar")
@requiere("personas_editar")
def persona_eliminar(codigo):
    if not _CODIGO.match(codigo):
        abort(404)

    def operacion():
        accion = repositorio.eliminar_persona(conexion(), codigo)
        if accion == "eliminada":
            import biometria  # carga OpenCV: solo se necesita al borrar de verdad
            biometria.borrar_archivos(codigo)
            return f"Persona {codigo} eliminada."
        return f"La persona {codigo} tiene historial: se dio de baja (estado inactivo)."

    try:
        flash(operacion(), "success")
    except db.ErrorAplicacion as exc:
        flash(exc.mensaje, "danger")
    return redirect(url_for("personas"))


# ---------------------------------------------------------------------
# Bitacora de accesos
# ---------------------------------------------------------------------
@app.route("/accesos")
@requiere("accesos")
def accesos():
    hoy = hoy_local()
    enviado = "filtrar" in request.args
    desde = fecha_arg("desde", None if enviado else hoy - timedelta(days=6))
    hasta = fecha_arg("hasta", None if enviado else hoy)
    resultado = request.args.get("resultado") or None
    if resultado not in (None, "permitido", "denegado"):
        abort(400, description="Resultado no válido.")
    zona = entero_arg("zona")
    texto = (request.args.get("texto") or "").strip() or None
    maximo = entero_arg("max") or 200
    try:
        filas = consultar("r_accesos_bitacora", desde, hasta, resultado, zona, texto, maximo)
        error = None
    except db.ErrorAplicacion as exc:
        filas, error = [], exc.mensaje
    return render_template(
        "accesos.html", filas=filas, error=error, zonas=consultar("r_zonas"),
        filtros={"desde": desde, "hasta": hasta, "resultado": resultado or "", "zona": zona,
                 "texto": texto or "", "max": maximo},
        limite_alcanzado=len(filas) >= maximo)


# ---------------------------------------------------------------------
# Asistencia (secciones y sesiones)
# ---------------------------------------------------------------------
def _seccion(id_seccion):
    for fila in consultar("r_secciones"):
        if fila["id_seccion"] == id_seccion:
            return fila
    abort(404)


@app.route("/asistencia")
@requiere("asistencia")
def asistencia():
    return render_template("asistencia.html", secciones=consultar("r_secciones"))


@app.route("/asistencia/seccion/<int:id_seccion>")
@requiere("asistencia")
def asistencia_seccion(id_seccion):
    seccion = _seccion(id_seccion)
    return render_template(
        "asistencia_seccion.html", seccion=seccion,
        resumen=consultar("r_asistencia_seccion", id_seccion),
        sesiones=consultar("r_sesiones", id_seccion),
        riesgo=consultar("r_alumnos_en_riesgo", id_seccion),
        inicio_sugerido=(ahora_local() + timedelta(hours=1)).replace(minute=0).strftime("%Y-%m-%dT%H:%M")
        if session["rol"] == "admin" else "")


@app.post("/asistencia/seccion/<int:id_seccion>/sesiones")
@requiere("sesiones_gestionar")
def sesion_programar(id_seccion):
    _seccion(id_seccion)  # 404 si la seccion no existe, antes de tocar la base

    def operacion():
        inicio = local_a_servidor(request.form.get("inicio"))
        if inicio is None:
            raise ValueError("Falta el dato: hora de inicio.")
        minutos = entero_form("duracion", "Duración (minutos)")
        if not 15 <= minutos <= 720:
            raise ValueError("La duración debe estar entre 15 y 720 minutos.")
        return repositorio.crear_sesion(conexion(), id_seccion, inicio, inicio + timedelta(minutes=minutos))

    return intentar(operacion, lambda id_sesion: f"Sesión {id_sesion} programada.",
                    url_for("asistencia_seccion", id_seccion=id_seccion))


@app.route("/asistencia/seccion/<int:id_seccion>/sesion/<int:id_sesion>")
@requiere("asistencia")
def asistencia_sesion(id_seccion, id_sesion):
    seccion = _seccion(id_seccion)
    sesion = next((s for s in consultar("r_sesiones", id_seccion) if s["id_sesion"] == id_sesion), None)
    if sesion is None:
        abort(404)
    return render_template("asistencia_sesion.html", seccion=seccion, sesion=sesion,
                           detalle=consultar("r_asistencia_sesion", id_sesion))


@app.post("/asistencia/seccion/<int:id_seccion>/sesion/<int:id_sesion>/cancelar")
@requiere("sesiones_gestionar")
def sesion_cancelar(id_seccion, id_sesion):
    _seccion(id_seccion)
    return intentar(lambda: repositorio.cancelar_sesion(conexion(), id_sesion),
                    f"Sesión {id_sesion} cancelada.", url_for("asistencia_seccion", id_seccion=id_seccion))


@app.post("/asistencia/seccion/<int:id_seccion>/sesion/<int:id_sesion>/cerrar")
@requiere("sesiones_gestionar")
def sesion_cerrar(id_seccion, id_sesion):
    _seccion(id_seccion)

    def operacion():
        faltas, inhabilitados = repositorio.cerrar_sesion(conexion(), id_sesion)
        return f"Sesión {id_sesion} cerrada: {faltas} falta(s) registrada(s) y {inhabilitados} estudiante(s) inhabilitado(s)."

    return intentar(operacion, lambda texto: texto,
                    url_for("asistencia_sesion", id_seccion=id_seccion, id_sesion=id_sesion))


# ---------------------------------------------------------------------
# Incidencias
# ---------------------------------------------------------------------
@app.route("/incidencias")
@requiere("incidencias")
def incidencias():
    estado = request.args.get("estado") or None
    gravedad = request.args.get("gravedad") or None
    if estado not in (None, *panel.ESTADOS_INCIDENCIA) or gravedad not in (None, *panel.GRAVEDADES):
        abort(400, description="Filtro no válido.")
    return render_template("incidencias.html", filas=consultar("r_incidencias", estado, gravedad),
                           zonas=consultar("r_zonas"), estado=estado or "", gravedad=gravedad or "",
                           estados=panel.ESTADOS_INCIDENCIA, gravedades=panel.GRAVEDADES)


@app.post("/incidencias/nueva")
@requiere("incidencias")
def incidencia_nueva():
    def operacion():
        codigo = (request.form.get("codigo_persona") or "").strip()
        id_persona = persona_por_codigo(codigo)["id_persona"] if codigo else None
        return repositorio.registrar_incidencia(
            conexion(), entero_form("zona", "Zona"), id_persona,
            entero_form("id_acceso", "Número de acceso", obligatorio=False),
            (request.form.get("tipo") or "").strip(), request.form.get("gravedad") or "",
            (request.form.get("descripcion") or "").strip() or None)

    return intentar(operacion, lambda id_incidencia: f"Incidencia {id_incidencia} registrada.",
                    url_for("incidencias"))


@app.post("/incidencias/<int:id_incidencia>/estado")
@requiere("incidencias")
def incidencia_estado(id_incidencia):
    nuevo = request.form.get("estado") or ""
    comentario = (request.form.get("comentario") or "").strip() or None

    def operacion():
        repositorio.resolver_incidencia(conexion(), id_incidencia, nuevo, comentario)

    return intentar(operacion, f"Incidencia {id_incidencia} actualizada a '{nuevo}'.", url_for("incidencias"))


# ---------------------------------------------------------------------
# Pases de visitantes
# ---------------------------------------------------------------------
@app.route("/pases")
@requiere("pases")
def pases():
    ahora = ahora_local()
    return render_template(
        "pases.html", filas=consultar("r_pases_vigentes"), zonas=consultar("r_zonas"),
        desde_sugerido=ahora.strftime("%Y-%m-%dT%H:%M"),
        hasta_sugerido=(ahora + timedelta(hours=4)).strftime("%Y-%m-%dT%H:%M"))


@app.post("/pases/nuevo")
@requiere("pases")
def pase_nuevo():
    def operacion():
        visitante = persona_por_codigo(request.form.get("codigo_visitante"))
        anfitrion = persona_por_codigo(request.form.get("codigo_anfitrion"))
        hasta = local_a_servidor(request.form.get("hasta"))
        if hasta is None:
            raise ValueError("Falta el dato: vigente hasta.")
        return repositorio.emitir_pase(
            conexion(), visitante["id_persona"], anfitrion["id_persona"],
            entero_form("zona", "Zona de destino"), local_a_servidor(request.form.get("desde")), hasta,
            (request.form.get("motivo") or "").strip() or None)

    return intentar(operacion, lambda id_pase: f"Pase {id_pase} emitido.", url_for("pases"))


@app.post("/pases/<int:id_pase>/revocar")
@requiere("pases")
def pase_revocar(id_pase):
    return intentar(lambda: repositorio.revocar_pase(conexion(), id_pase),
                    f"Pase {id_pase} revocado.", url_for("pases"))


# ---------------------------------------------------------------------
# Restricciones
# ---------------------------------------------------------------------
@app.route("/restricciones")
@requiere("restricciones")
def restricciones():
    return render_template("restricciones.html", filas=consultar("r_restricciones"))


@app.post("/restricciones/nueva")
@requiere("restricciones")
def restriccion_nueva():
    def operacion():
        persona = persona_por_codigo(request.form.get("codigo_persona"))
        return repositorio.registrar_restriccion(
            conexion(), persona["id_persona"], (request.form.get("motivo") or "").strip(),
            local_a_servidor(request.form.get("fecha_fin")))

    return intentar(operacion, lambda id_restriccion: f"Restricción {id_restriccion} registrada.",
                    url_for("restricciones"))


@app.post("/restricciones/<int:id_restriccion>/levantar")
@requiere("restricciones")
def restriccion_levantar(id_restriccion):
    return intentar(lambda: repositorio.levantar_restriccion(conexion(), id_restriccion),
                    f"Restricción {id_restriccion} levantada.", url_for("restricciones"))


# ---------------------------------------------------------------------
# Reportes (procedimientos r_*)
# ---------------------------------------------------------------------
@app.route("/reportes")
@requiere("reportes")
def reportes():
    return render_template("reportes.html", reportes=panel.reportes_para(session["rol"]))


def _respuesta_csv(filas, nombre):
    salida = io.StringIO()
    escritor = csv.writer(salida)
    if filas:
        escritor.writerow(filas[0].keys())
        for fila in filas:
            escritor.writerow([panel.celda_csv(v) for v in fila.values()])
    return Response("﻿" + salida.getvalue(), mimetype="text/csv",
                    headers={"Content-Disposition": f'attachment; filename="{nombre}.csv"'})


@app.route("/reportes/<clave>")
@requiere("reportes")
def reporte(clave):
    definicion = panel.REPORTES.get(clave)
    if definicion is None:
        abort(404)
    if session["rol"] not in definicion["roles"]:
        abort(403)

    parametros = definicion["parametros"]
    tipos = {p["tipo"] for p in parametros}
    valores = {p["nombre"]: request.args.get(p["nombre"], "") for p in parametros}
    ejecutar = "ejecutar" in request.args or not parametros

    filas, error = None, None
    if ejecutar:
        try:
            argumentos = [panel.convertir_parametro(p, valores[p["nombre"]]) for p in parametros]
            filas = consultar(definicion["procedimiento"], *argumentos)
        except ValueError as exc:
            error = str(exc)
        except db.ErrorAplicacion as exc:
            error = exc.mensaje
    if filas is not None and request.args.get("formato") == "csv":
        return _respuesta_csv(filas, clave)

    return render_template(
        "reporte.html", clave=clave, reporte=definicion, valores=valores, filas=filas, error=error,
        ejecutado=ejecutar,
        secciones=consultar("r_secciones") if "seccion" in tipos else [],
        zonas=consultar("r_zonas") if "zona" in tipos else [])


# ---------------------------------------------------------------------
# Errores
# ---------------------------------------------------------------------
def _pagina_error(codigo, titulo, mensaje):
    return render_template("error.html", codigo=codigo, titulo=titulo, mensaje=mensaje), codigo


@app.errorhandler(400)
def error_400(exc):
    return _pagina_error(400, "Solicitud no válida", exc.description)


@app.errorhandler(403)
def error_403(_exc):
    return _pagina_error(403, "Sin permiso", "Su rol no tiene acceso a esta pantalla o acción.")


@app.errorhandler(404)
def error_404(_exc):
    return _pagina_error(404, "No encontrado", "La página o el registro que busca no existe.")


@app.errorhandler(db.ErrorAplicacion)
def error_aplicacion(exc):
    return _pagina_error(400, "No se pudo completar la operación", exc.mensaje)


@app.errorhandler(db.ConfiguracionError)
def error_configuracion(exc):
    return _pagina_error(500, "Configuración incompleta", str(exc))


@app.errorhandler(oracledb.Error)
def error_base_de_datos(exc):
    app.logger.error("Error de Oracle: %s", exc)
    texto = str(exc)
    if "PLS-00201" in texto or "ORA-00942" in texto or "ORA-06550" in texto:
        return _pagina_error(403, "Sin permiso en la base de datos",
                             "El usuario de Oracle de su rol no puede ejecutar esta operación.")
    return _pagina_error(503, "Base de datos no disponible",
                         "No se pudo usar Oracle. Verifique que el contenedor oracle-xe esté encendido.")


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    if not any(panel.clave_panel(r) for r in panel.ROLES):
        print("Aviso: no hay claves del panel. Defina PANEL_PASSWORD_ADMIN, PANEL_PASSWORD_VIGILANTE "
              "y PANEL_PASSWORD_DOCENTE en .env (ver .env.example).", file=sys.stderr)
    app.run(host=os.environ.get("PANEL_HOST", "127.0.0.1"),
            port=int(os.environ.get("PANEL_PORT", "5000")), debug=False)
