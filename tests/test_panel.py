"""Pruebas del panel web (Etapa 7).

Ejecutar desde la raiz del repositorio, con el contenedor oracle-xe encendido y
las claves PANEL_PASSWORD_* y DB_PASSWORD_* en .env:

    ./venv/bin/python -m unittest discover -s tests -v

Usan el cliente de pruebas de Flask contra Oracle real: cada rol entra con su
clave del panel y todas las consultas se hacen con su usuario de Oracle. Las
pruebas limpian lo que crean (personas, pases, sesiones, restricciones); solo
quedan registros historicos que la aplicacion no puede borrar (incidencias
resueltas, restricciones levantadas y accesos de prueba con metodo 'simulado').
"""
import random
import re
import string
import sys
import unittest
from datetime import datetime, timedelta
from pathlib import Path
from unittest import mock
from zoneinfo import ZoneInfo

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import app as panel_app  # noqa: E402
import db  # noqa: E402
import panel  # noqa: E402
import repositorio  # noqa: E402
import utiles  # noqa: E402

ROLES = ("admin", "vigilante", "docente")


def _hay_panel():
    try:
        for rol in ROLES:
            if not panel.clave_panel(rol):
                return False
            db.get_connection(rol).close()
        db.get_connection("punto").close()
        return True
    except Exception:  # sin contenedor, sin claves en .env, etc.
        return False


HAY_PANEL = _hay_panel()
requiere_panel = unittest.skipUnless(
    HAY_PANEL, "Oracle no disponible o faltan claves (DB_PASSWORD_* y PANEL_PASSWORD_*) en .env")

panel_app.app.config.update(TESTING=True)
TOKEN = re.compile(r'name="csrf_token" value="([^"]+)"')


def _codigo(prefijo):
    return prefijo + "".join(random.choices(string.digits, k=8 - len(prefijo)))


class Sesion:
    """Cliente de pruebas con la sesion iniciada de un rol."""

    def __init__(self, rol):
        self.rol = rol
        self.c = panel_app.app.test_client()
        html = self.c.get("/login").get_data(as_text=True)
        respuesta = self.c.post("/login", data={
            "csrf_token": TOKEN.search(html).group(1), "rol": rol, "clave": panel.clave_panel(rol)})
        assert respuesta.status_code == 302, f"no se pudo iniciar sesion como {rol}"
        self._token = None

    def token(self):
        if self._token is None:
            self._token = TOKEN.search(self.c.get("/").get_data(as_text=True)).group(1)
        return self._token

    def get(self, ruta):
        respuesta = self.c.get(ruta)
        return respuesta.status_code, respuesta.get_data(as_text=True)

    def post(self, ruta, datos=None, seguir=True):
        datos = dict(datos or {})
        datos["csrf_token"] = self.token()
        respuesta = self.c.post(ruta, data=datos, follow_redirects=seguir)
        return respuesta.status_code, respuesta.get_data(as_text=True)


def ahora_local_db():
    """Hora local del campus segun Oracle (r_resumen_hoy)."""
    conn = db.get_connection("vigilante")
    try:
        fila = repositorio.consultar_cursor(conn, "r_resumen_hoy")[0]
    finally:
        conn.close()
    return datetime.strptime(fila["fecha_hora_local"], "%Y-%m-%d %H:%M")


def formato_local(dt):
    return dt.strftime("%Y-%m-%dT%H:%M")


# ---------------------------------------------------------------------
# Reglas del panel que no necesitan la base
# ---------------------------------------------------------------------
class TestReglasDelPanel(unittest.TestCase):
    def test_cada_pantalla_tiene_al_menos_un_rol(self):
        for pantalla, roles in panel.PERMISOS.items():
            self.assertTrue(roles, pantalla)
            self.assertTrue(roles <= set(panel.ROLES), pantalla)

    def test_el_menu_se_filtra_por_rol(self):
        etiquetas = {rol: {it["etiqueta"] for _, items in panel.menu_para(rol) for it in items}
                     for rol in ROLES}
        self.assertIn("Personas", etiquetas["admin"])
        self.assertNotIn("Asistencia", etiquetas["vigilante"])
        self.assertNotIn("Personas", etiquetas["docente"])
        self.assertNotIn("Bitácora de accesos", etiquetas["docente"])
        self.assertEqual(panel.menu_para("desconocido"), [])

    def test_los_reportes_por_rol_coinciden_con_los_permisos_de_oracle(self):
        # los GRANT de sql/06_permisos.sql: el vigilante solo ejecuta reportes de seguridad
        # y el docente solo los de asistencia
        procs = {rol: {r["procedimiento"] for _, r in panel.reportes_para(rol)} for rol in ROLES}
        self.assertEqual(procs["vigilante"], {"r_accesos_denegados", "r_incidencias",
                                              "r_pases_vigentes", "r_flujo_por_hora"})
        self.assertEqual(procs["docente"], {"r_asistencia_seccion", "r_asistencia_sesion",
                                            "r_alumnos_en_riesgo", "r_ranking_tardanzas"})
        self.assertEqual(len(procs["admin"]), len(panel.REPORTES))

    def test_conversion_de_parametros(self):
        fecha = {"nombre": "d", "etiqueta": "Desde", "tipo": "fecha", "obligatorio": False}
        self.assertEqual(panel.convertir_parametro(fecha, "2026-10-27").isoformat(), "2026-10-27")
        self.assertIsNone(panel.convertir_parametro(fecha, "  "))
        with self.assertRaises(ValueError):
            panel.convertir_parametro(fecha, "27/10/2026")
        seccion = {"nombre": "s", "etiqueta": "Sección", "tipo": "seccion", "obligatorio": True}
        self.assertEqual(panel.convertir_parametro(seccion, "3"), 3)
        with self.assertRaises(ValueError):
            panel.convertir_parametro(seccion, "")
        with self.assertRaises(ValueError):
            panel.convertir_parametro(seccion, "3; drop table x")
        opcion = {"nombre": "e", "etiqueta": "Estado", "tipo": "opcion", "obligatorio": False,
                  "opciones": ("abierta", "resuelta")}
        self.assertEqual(panel.convertir_parametro(opcion, "abierta"), "abierta")
        with self.assertRaises(ValueError):
            panel.convertir_parametro(opcion, "cualquiera")

    def test_formato_de_celdas(self):
        self.assertEqual(panel.valor(None), "-")
        self.assertEqual(panel.valor(3.0), "3")
        self.assertEqual(panel.valor(2.5), "2.5")
        self.assertEqual(panel.valor("  hola "), "hola")
        self.assertEqual(panel.clase_insignia("denegado"), "danger")
        self.assertEqual(panel.clase_insignia("lo-que-sea"), "secondary")

    def test_csv_neutraliza_formulas(self):
        self.assertEqual(panel.celda_csv("=1+1"), "'=1+1")
        self.assertEqual(panel.celda_csv("@cmd"), "'@cmd")
        self.assertEqual(panel.celda_csv(-5), "-5")
        self.assertEqual(panel.celda_csv(None), "")

    def test_clave_incorrecta_o_rol_sin_clave(self):
        with mock.patch.dict("os.environ", {"PANEL_PASSWORD_ADMIN": "secreta"}):
            self.assertTrue(panel.clave_correcta("admin", "secreta"))
            self.assertFalse(panel.clave_correcta("admin", "otra"))
            self.assertFalse(panel.clave_correcta("admin", ""))
        with mock.patch.dict("os.environ", {"PANEL_PASSWORD_DOCENTE": ""}):
            self.assertFalse(panel.clave_correcta("docente", ""))



# ---------------------------------------------------------------------
# Autenticacion y seguridad web
# ---------------------------------------------------------------------
@requiere_panel
class TestAutenticacion(unittest.TestCase):
    def setUp(self):
        panel_app._FALLOS.clear()

    def tearDown(self):
        panel_app._FALLOS.clear()

    def _login(self, cliente, rol, clave, ruta="/login"):
        html = cliente.get("/login").get_data(as_text=True)
        return cliente.post(ruta, data={"csrf_token": TOKEN.search(html).group(1),
                                        "rol": rol, "clave": clave})

    def test_sin_sesion_se_redirige_al_login(self):
        respuesta = panel_app.app.test_client().get("/personas")
        self.assertEqual(respuesta.status_code, 302)
        self.assertIn("/login", respuesta.headers["Location"])

    def test_clave_incorrecta_no_inicia_sesion(self):
        c = panel_app.app.test_client()
        respuesta = self._login(c, "admin", "clave-equivocada")
        self.assertEqual(respuesta.status_code, 401)
        self.assertIn("Rol o clave incorrectos", respuesta.get_data(as_text=True))
        self.assertEqual(c.get("/").status_code, 302)

    def test_rol_inexistente(self):
        respuesta = self._login(panel_app.app.test_client(), "root", "x")
        self.assertEqual(respuesta.status_code, 401)

    def test_login_y_logout(self):
        c = panel_app.app.test_client()
        respuesta = self._login(c, "admin", panel.clave_panel("admin"))
        self.assertEqual(respuesta.status_code, 302)
        self.assertEqual(c.get("/").status_code, 200)
        html = c.get("/").get_data(as_text=True)
        salida = c.post("/logout", data={"csrf_token": TOKEN.search(html).group(1)})
        self.assertEqual(salida.status_code, 302)
        self.assertEqual(c.get("/").status_code, 302)

    def test_post_sin_token_csrf_se_rechaza(self):
        sesion = Sesion("admin")
        respuesta = sesion.c.post("/logout", data={})
        self.assertEqual(respuesta.status_code, 400)
        respuesta = sesion.c.post("/personas/25200001/eliminar", data={"csrf_token": "falso"})
        self.assertEqual(respuesta.status_code, 400)
        self.assertEqual(sesion.get("/")[0], 200)  # la sesion sigue activa

    def test_el_destino_despues_del_login_solo_puede_ser_interno(self):
        for destino in ("//evil.example.com", "https://evil.example.com", "/login"):
            c = panel_app.app.test_client()
            respuesta = self._login(c, "admin", panel.clave_panel("admin"),
                                    ruta=f"/login?siguiente={destino}")
            self.assertEqual(respuesta.status_code, 302)
            self.assertEqual(respuesta.headers["Location"], "/", destino)

    def test_el_destino_interno_se_respeta(self):
        c = panel_app.app.test_client()
        respuesta = self._login(c, "admin", panel.clave_panel("admin"), ruta="/login?siguiente=/incidencias")
        self.assertEqual(respuesta.headers["Location"], "/incidencias")

    def test_cookie_de_sesion_httponly_y_samesite(self):
        c = panel_app.app.test_client()
        respuesta = self._login(c, "docente", panel.clave_panel("docente"))
        cookie = respuesta.headers.get("Set-Cookie", "")
        self.assertIn("HttpOnly", cookie)
        self.assertIn("SameSite=Lax", cookie)

    def test_bloqueo_tras_varios_intentos_fallidos(self):
        c = panel_app.app.test_client()
        for _ in range(5):
            self.assertEqual(self._login(c, "admin", "mala").status_code, 401)
        bloqueado = self._login(c, "admin", panel.clave_panel("admin"))
        self.assertEqual(bloqueado.status_code, 429)  # ni con la clave correcta mientras dura el bloqueo


# ---------------------------------------------------------------------
# Quien puede entrar a que pantalla
# ---------------------------------------------------------------------
@requiere_panel
class TestPermisosPorRol(unittest.TestCase):
    ESPERADO = {
        "admin": {
            200: ["/", "/personas", "/personas/nueva", "/personas/25200001/editar", "/accesos", "/asistencia",
                  "/asistencia/seccion/1", "/asistencia/seccion/1/sesion/6", "/incidencias", "/pases",
                  "/restricciones", "/reportes", "/reportes/uso-aulas", "/reportes/flujo-por-hora"],
        },
        "vigilante": {
            200: ["/", "/personas", "/accesos", "/incidencias", "/pases", "/restricciones", "/reportes",
                  "/reportes/accesos-denegados"],
            403: ["/personas/nueva", "/personas/25200001/editar", "/asistencia", "/asistencia/seccion/1",
                  "/reportes/uso-aulas", "/reportes/asistencia-seccion"],
        },
        "docente": {
            200: ["/", "/asistencia", "/asistencia/seccion/1", "/asistencia/seccion/1/sesion/6", "/reportes",
                  "/reportes/alumnos-en-riesgo"],
            403: ["/personas", "/personas/nueva", "/accesos", "/incidencias", "/pases", "/restricciones",
                  "/reportes/accesos-denegados", "/reportes/flujo-por-hora"],
        },
    }

    def test_matriz_de_pantallas(self):
        for rol, casos in self.ESPERADO.items():
            sesion = Sesion(rol)
            for codigo, rutas in casos.items():
                for ruta in rutas:
                    with self.subTest(rol=rol, ruta=ruta):
                        self.assertEqual(sesion.get(ruta)[0], codigo)

    def test_acciones_de_escritura_prohibidas(self):
        docente, vigilante = Sesion("docente"), Sesion("vigilante")
        casos = [
            (docente, "/asistencia/seccion/1/sesiones", {"inicio": "2031-01-01T10:00", "duracion": "60"}),
            (docente, "/asistencia/seccion/1/sesion/1/cerrar", {}),
            (docente, "/pases/nuevo", {}),
            (vigilante, "/personas/nueva", {}),
            (vigilante, "/personas/25200001/eliminar", {}),
            (vigilante, "/asistencia/seccion/1/sesion/1/cerrar", {}),
            (vigilante, "/asistencia/seccion/1/sesion/1/cancelar", {}),
        ]
        for sesion, ruta, datos in casos:
            with self.subTest(rol=sesion.rol, ruta=ruta):
                self.assertEqual(sesion.post(ruta, datos, seguir=False)[0], 403)

    def test_el_menu_muestra_solo_lo_permitido(self):
        _, html = Sesion("docente").get("/")
        self.assertIn('href="/asistencia"', html)
        for oculto in ("/personas", "/accesos", "/incidencias", "/pases", "/restricciones"):
            self.assertNotIn(f'href="{oculto}"', html)
        _, html = Sesion("vigilante").get("/")
        for visible in ("/accesos", "/incidencias", "/pases", "/restricciones", "/personas"):
            self.assertIn(f'href="{visible}"', html)
        self.assertNotIn('href="/asistencia"', html)

    def test_paginas_inexistentes_y_parametros_invalidos(self):
        admin = Sesion("admin")
        self.assertEqual(admin.get("/no-existe")[0], 404)
        self.assertEqual(admin.get("/personas/abc/editar")[0], 404)
        self.assertEqual(admin.get("/personas/12345678/editar")[0], 404)
        self.assertEqual(admin.get("/reportes/no-existe")[0], 404)
        self.assertEqual(admin.get("/asistencia/seccion/9999")[0], 404)
        self.assertEqual(admin.get("/accesos?desde=ayer")[0], 400)
        self.assertEqual(admin.get("/accesos?resultado=quizas")[0], 400)
        self.assertEqual(admin.get("/accesos?zona=x")[0], 400)
        self.assertEqual(admin.get("/personas?tipo=alien")[0], 400)
        self.assertEqual(admin.get("/incidencias?gravedad=extrema")[0], 400)


# ---------------------------------------------------------------------
# Dashboard
# ---------------------------------------------------------------------
@requiere_panel
class TestDashboard(unittest.TestCase):
    def test_dashboard_de_admin_y_vigilante(self):
        for rol in ("admin", "vigilante"):
            with self.subTest(rol=rol):
                estado, html = Sesion(rol).get("/")
                self.assertEqual(estado, 200)
                for texto in ("Accesos de hoy", "Accesos denegados hoy", "Incidencias abiertas",
                              "Sesiones de clase en curso", "Flujo de hoy por hora", "(hora local)"):
                    self.assertIn(texto, html)
                self.assertEqual(html.count('class="flujo-col"'), 24)

    def test_dashboard_del_docente_lista_secciones(self):
        estado, html = Sesion("docente").get("/")
        self.assertEqual(estado, 200)
        self.assertIn("SIS301", html)
        self.assertIn("Ver asistencia", html)

    def test_el_resumen_usa_la_hora_local_del_campus(self):
        local_db = ahora_local_db()
        lima = datetime.now(ZoneInfo("America/Lima")).replace(tzinfo=None)
        self.assertLess(abs((local_db - lima).total_seconds()), 180,
                        f"Oracle dice {local_db}, el reloj de Lima marca {lima}")

    def test_conversion_de_hora_local_a_hora_del_servidor(self):
        conn = db.get_connection("vigilante")
        try:
            desfase = repositorio.obtener_desfase(conn)
        finally:
            conn.close()
        self.assertEqual(desfase, 300)  # servidor en UTC y campus en America/Lima
        with panel_app.app.test_request_context("/"):
            from flask import session
            session["rol"] = "vigilante"
            convertido = panel_app.local_a_servidor("2030-01-01T10:00")
            self.assertEqual(convertido, datetime(2030, 1, 1, 15, 0))
            self.assertIsNone(panel_app.local_a_servidor("  "))
            with self.assertRaises(ValueError):
                panel_app.local_a_servidor("manana")


# ---------------------------------------------------------------------
# Personas
# ---------------------------------------------------------------------
@requiere_panel
class TestPersonas(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.admin = Sesion("admin")
        cls.vigilante = Sesion("vigilante")

    def _alta(self, **extra):
        datos = {"tipo": "visitante", "codigo": _codigo("86"), "nombre": "Prueba Panel Web",
                 "dni": _codigo("85"), "correo": "", "id_escuela": "", "ciclo": "", "especialidad": ""}
        datos.update(extra)
        return datos, self.admin.post("/personas/nueva", datos)

    def test_listado_y_filtros(self):
        _, html = self.admin.get("/personas")
        self.assertIn("Ana Torres Quispe", html)
        self.assertIn("Carlos Mendoza Rios", html)
        _, html = self.admin.get("/personas?texto=torres")
        self.assertIn("Ana Torres Quispe", html)
        self.assertNotIn("Carlos Mendoza Rios", html)
        _, html = self.admin.get("/personas?tipo=docente")
        self.assertIn("Carlos Mendoza Rios", html)
        self.assertNotIn("Ana Torres Quispe", html)
        _, html = self.admin.get("/personas?estado=inactivo")
        self.assertIn("Camila Rojas Prado", html)
        self.assertNotIn("Ana Torres Quispe", html)

    def test_el_vigilante_solo_busca(self):
        estado, html = self.vigilante.get("/personas?texto=torres")
        self.assertEqual(estado, 200)
        self.assertIn("Ana Torres Quispe", html)
        self.assertNotIn("Nueva persona", html)
        self.assertNotIn("Eliminar", html)

    def test_alta_edicion_y_eliminacion(self):
        datos, (estado, html) = self._alta()
        self.assertEqual(estado, 200)
        self.assertIn("registrada", html)
        self.assertIn("Prueba Panel Web", html)

        estado, html = self.admin.post(f"/personas/{datos['codigo']}/editar", {
            "nombre": "Nombre Editado Web", "dni": datos["dni"], "correo": "web@campus.test",
            "estado": "suspendido", "id_escuela": "", "ciclo": "", "especialidad": ""})
        self.assertIn("actualizada", html)
        self.assertIn("Nombre Editado Web", html)
        self.assertIn("suspendido", html)

        estado, html = self.admin.post(f"/personas/{datos['codigo']}/eliminar")
        self.assertIn("eliminada", html)
        self.assertNotIn("Nombre Editado Web", self.admin.get(f"/personas?texto={datos['codigo']}")[1])

    def test_alta_de_estudiante_con_escuela_y_ciclo(self):
        datos, (_, html) = self._alta(tipo="estudiante", id_escuela="1", ciclo="5")
        try:
            self.assertIn("registrada", html)
            self.assertIn("Ingenieria de Sistemas, ciclo 5", html)
        finally:
            self.admin.post(f"/personas/{datos['codigo']}/eliminar")

    def test_los_datos_del_usuario_se_escapan(self):
        malicioso = "<script>alert(1)</script>"
        datos, (_, html) = self._alta(nombre=malicioso)
        try:
            self.assertNotIn(malicioso, html)
            self.assertIn("&lt;script&gt;alert(1)&lt;/script&gt;", html)
        finally:
            self.admin.post(f"/personas/{datos['codigo']}/eliminar")

    def test_errores_de_validacion_se_muestran_sin_romper_la_pagina(self):
        _, (estado, html) = self._alta(codigo="123")
        self.assertEqual(estado, 200)
        self.assertIn("8 digitos", html)
        _, (estado, html) = self._alta(tipo="estudiante", ciclo="abc")
        self.assertIn("Ciclo debe ser un número", html)
        _, (estado, html) = self._alta(tipo="estudiante")  # falta escuela y ciclo
        self.assertIn("necesita escuela y ciclo", html)

    def test_codigo_duplicado(self):
        datos, _ = self._alta()
        try:
            estado, html = self.admin.post("/personas/nueva", datos)
            self.assertEqual(estado, 200)
            self.assertIn("Ya existe una persona", html)
        finally:
            self.admin.post(f"/personas/{datos['codigo']}/eliminar")


# ---------------------------------------------------------------------
# Bitacora de accesos (de la lectura en el punto de control a la pantalla)
# ---------------------------------------------------------------------
@requiere_panel
class TestAccesos(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.vigilante = Sesion("vigilante")
        cls.admin = Sesion("admin")

    def test_la_bitacora_trae_los_ultimos_dias(self):
        estado, html = self.vigilante.get("/accesos")
        self.assertEqual(estado, 200)
        self.assertIn("acceso(s)", html)
        self.assertIn("permitido", html)

    def test_un_acceso_leido_en_el_punto_aparece_en_la_bitacora(self):
        codigo = _codigo("7")  # codigo que no existe
        punto = db.get_connection("punto")
        try:
            resultado = repositorio.registrar_acceso(punto, codigo, 1, False, None, "simulado")
        finally:
            punto.close()
        self.assertEqual(resultado.motivo, "codigo_inexistente")
        _, html = self.vigilante.get(f"/accesos?filtrar=1&texto={codigo}")
        self.assertIn(codigo, html)
        self.assertIn("codigo_inexistente", html)
        self.assertIn("(codigo no registrado)", html)
        self.assertIn(f"<td>{resultado.id_acceso}</td>", html)

    def test_filtro_por_resultado(self):
        _, html = self.vigilante.get("/accesos?filtrar=1&resultado=denegado")
        self.assertIn('bg-danger">denegado', html)
        self.assertNotIn('bg-success">permitido', html)
        _, html = self.vigilante.get("/accesos?filtrar=1&resultado=permitido&max=50")
        self.assertIn('bg-success">permitido', html)
        self.assertNotIn('bg-danger">denegado', html)

    def test_filtro_por_texto_y_zona(self):
        _, html = self.vigilante.get("/accesos?filtrar=1&texto=torres")
        self.assertIn("Ana Torres Quispe", html)
        self.assertNotIn("Pedro Vargas Leon", html)
        _, html = self.vigilante.get("/accesos?filtrar=1&zona=2")  # Biblioteca Central
        self.assertIn("Biblioteca Central", html)
        self.assertNotIn("Puerta Principal</td>", html)

    def test_rango_de_fechas_al_reves_se_informa(self):
        _, html = self.vigilante.get("/accesos?filtrar=1&desde=2026-10-10&hasta=2026-10-01")
        self.assertIn("La fecha desde no puede ser posterior", html)

    def test_se_avisa_cuando_hay_mas_filas_que_el_maximo(self):
        _, html = self.vigilante.get("/accesos?filtrar=1&max=50")
        self.assertIn("hay más con estos filtros", html)


# ---------------------------------------------------------------------
# Asistencia, sesiones
# ---------------------------------------------------------------------
@requiere_panel
class TestAsistencia(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.admin = Sesion("admin")
        cls.docente = Sesion("docente")

    def test_listado_de_secciones(self):
        _, html = self.docente.get("/asistencia")
        for curso in ("SIS301", "SIS302", "SIS201", "CC101"):
            self.assertIn(curso, html)

    def test_detalle_de_una_seccion(self):
        for sesion in (self.admin, self.docente):
            estado, html = sesion.get("/asistencia/seccion/1")
            self.assertEqual(estado, 200)
            self.assertIn("Resumen por estudiante", html)
            self.assertIn("Ana Torres Quispe", html)
            self.assertIn("Alumnos en riesgo", html)
        self.assertIn("Programar una sesión", self.admin.get("/asistencia/seccion/1")[1])
        self.assertNotIn("Programar una sesión", self.docente.get("/asistencia/seccion/1")[1])

    def test_detalle_de_una_sesion_cerrada(self):
        _, html = self.docente.get("/asistencia/seccion/1/sesion/6")
        self.assertIn("Sesión cerrada", html)
        self.assertIn("Presentes", html)
        self.assertNotIn("Cerrar sesión", html)  # el docente no cierra sesiones

    def test_programar_y_cancelar_una_sesion(self):
        inicio = datetime(2031, random.randint(1, 12), random.randint(1, 28),
                          random.randint(6, 20), random.choice((0, 15, 30, 45)))
        estado, html = self.admin.post("/asistencia/seccion/1/sesiones",
                                       {"inicio": formato_local(inicio), "duracion": "75"})
        self.assertEqual(estado, 200)
        encontrado = re.search(r"Sesión (\d+) programada", html)
        self.assertIsNotNone(encontrado, html[:300])
        id_sesion = encontrado.group(1)
        try:
            self.assertIn(inicio.strftime("%Y-%m-%d %H:%M"), html)  # se muestra en hora local
            self.assertIn("programada", html)
            self.assertIn("Cancelar", html)
        finally:
            _, html = self.admin.post(f"/asistencia/seccion/1/sesion/{id_sesion}/cancelar")
        self.assertIn(f"Sesión {id_sesion} cancelada", html)
        self.assertNotIn(inicio.strftime("%Y-%m-%d %H:%M"), html)

    def test_errores_al_programar(self):
        casos = [
            ({"inicio": "", "duracion": "60"}, "Falta el dato: hora de inicio"),
            ({"inicio": "2031-01-01T10:00", "duracion": "5"}, "entre 15 y 720"),
            ({"inicio": "2031-01-01T10:00", "duracion": "abc"}, "debe ser un número"),
            ({"inicio": "no-es-fecha", "duracion": "60"}, "formato AAAA-MM-DD HH:MM"),
        ]
        for datos, mensaje in casos:
            with self.subTest(datos=datos):
                _, html = self.admin.post("/asistencia/seccion/1/sesiones", datos)
                self.assertIn(mensaje, html)

    def test_una_seccion_inexistente_responde_404_sin_dejar_avisos_colgados(self):
        for ruta in ("/asistencia/seccion/999/sesiones", "/asistencia/seccion/999/sesion/1/cerrar",
                     "/asistencia/seccion/999/sesion/1/cancelar"):
            with self.subTest(ruta=ruta):
                estado, _ = self.admin.post(ruta, {"inicio": "2031-01-01T10:00", "duracion": "60"}, seguir=False)
                self.assertEqual(estado, 404)
        _, html = self.admin.get("/asistencia")
        self.assertNotIn("alert-danger", html)  # no quedo ningun aviso pendiente

    def test_no_se_puede_cerrar_dos_veces_ni_cancelar_una_cerrada(self):
        _, html = self.admin.post("/asistencia/seccion/1/sesion/1/cerrar")
        self.assertIn("ya esta cerrada", html)
        _, html = self.admin.post("/asistencia/seccion/1/sesion/1/cancelar")
        self.assertIn("Solo se pueden cancelar sesiones programadas", html)

    def test_el_boton_de_cerrar_aparece_solo_para_el_admin_en_sesiones_abiertas(self):
        inicio = datetime(2032, random.randint(1, 12), random.randint(1, 28), 9, random.randint(0, 59))
        _, html = self.admin.post("/asistencia/seccion/2/sesiones", {"inicio": formato_local(inicio), "duracion": "90"})
        id_sesion = re.search(r"Sesión (\d+) programada", html).group(1)
        try:
            _, html_admin = self.admin.get(f"/asistencia/seccion/2/sesion/{id_sesion}")
            self.assertIn("Cerrar sesión", html_admin)
            _, html_docente = self.docente.get(f"/asistencia/seccion/2/sesion/{id_sesion}")
            self.assertNotIn("Cerrar sesión", html_docente)
        finally:
            self.admin.post(f"/asistencia/seccion/2/sesion/{id_sesion}/cancelar")


# ---------------------------------------------------------------------
# Incidencias
# ---------------------------------------------------------------------
@requiere_panel
class TestIncidencias(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.vigilante = Sesion("vigilante")

    def _registrar(self, **extra):
        datos = {"zona": "5", "tipo": "prueba_panel", "gravedad": "media",
                 "descripcion": "Incidencia creada por la prueba automatica", "codigo_persona": "", "id_acceso": ""}
        datos.update(extra)
        return self.vigilante.post("/incidencias/nueva", datos)

    def test_registrar_revisar_y_resolver(self):
        estado, html = self._registrar()
        self.assertEqual(estado, 200)
        encontrado = re.search(r"Incidencia (\d+) registrada", html)
        self.assertIsNotNone(encontrado, html[:300])
        id_incidencia = encontrado.group(1)
        self.assertIn("prueba_panel", html)

        _, html = self.vigilante.post(f"/incidencias/{id_incidencia}/estado",
                                      {"estado": "en_revision", "comentario": "Se revisa"})
        self.assertIn("actualizada a &#39;en_revision&#39;", html)
        _, html = self.vigilante.get("/incidencias?estado=en_revision")
        self.assertIn("Se revisa", html)

        _, html = self.vigilante.post(f"/incidencias/{id_incidencia}/estado",
                                      {"estado": "resuelta", "comentario": "Cerrada en la prueba"})
        self.assertIn("actualizada a &#39;resuelta&#39;", html)
        _, html = self.vigilante.get("/incidencias?estado=resuelta&gravedad=media")
        self.assertIn("Cerrada en la prueba", html)

        _, html = self.vigilante.post(f"/incidencias/{id_incidencia}/estado", {"estado": "resuelta"})
        self.assertIn("ya esta resuelta", html)  # no se puede volver a resolver

    def test_errores_de_registro(self):
        _, html = self._registrar(gravedad="gravisima")
        self.assertIn("La gravedad debe ser baja, media o alta", html)
        _, html = self._registrar(codigo_persona="00000000")
        self.assertIn("No existe una persona con el código 00000000", html)
        _, html = self._registrar(id_acceso="99999999")
        self.assertIn("El acceso 99999999 no existe", html)
        _, html = self._registrar(zona="")
        self.assertIn("Falta el dato: Zona", html)

    def test_estado_no_valido(self):
        _, html = self.vigilante.post("/incidencias/1000/estado", {"estado": "inventado"})
        self.assertIn("El nuevo estado debe ser en_revision o resuelta", html)

    def test_incidencia_inexistente(self):
        _, html = self.vigilante.post("/incidencias/99999/estado", {"estado": "resuelta"})
        self.assertIn("no existe", html)

    def test_las_incidencias_se_ordenan_por_gravedad(self):
        _, html = self.vigilante.get("/incidencias")
        self.assertLess(html.index('bg-danger">alta'), html.index('bg-info">baja'))


# ---------------------------------------------------------------------
# Pases de visitantes
# ---------------------------------------------------------------------
@requiere_panel
class TestPases(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.vigilante = Sesion("vigilante")
        cls.incidencias_previas = utiles.maximo_incidencia()

    @classmethod
    def tearDownClass(cls):
        utiles.cerrar_incidencias_nuevas(cls.incidencias_previas)

    def _emitir(self, ahora, **extra):
        datos = {"codigo_visitante": "99000002", "codigo_anfitrion": "80000001", "zona": "2",
                 "desde": formato_local(ahora - timedelta(minutes=2)),
                 "hasta": formato_local(ahora + timedelta(hours=1)), "motivo": "Prueba automatica del panel"}
        datos.update(extra)
        return self.vigilante.post("/pases/nuevo", datos)

    def test_emitir_y_revocar_un_pase(self):
        estado, html = self._emitir(ahora_local_db())
        self.assertEqual(estado, 200)
        encontrado = re.search(r"Pase (\d+) emitido", html)
        self.assertIsNotNone(encontrado, html[:300])
        id_pase = encontrado.group(1)
        try:
            self.assertIn("Hugo Villanueva Rey", html)
            self.assertIn("Biblioteca Central", html)
            self.assertIn("Prueba automatica del panel", html)
        finally:
            _, html = self.vigilante.post(f"/pases/{id_pase}/revocar")
        self.assertIn(f"Pase {id_pase} revocado", html)
        self.assertNotIn("Prueba automatica del panel", html)
        _, html = self.vigilante.post(f"/pases/{id_pase}/revocar")
        self.assertIn("ya esta revocado", html)

    def test_el_pase_emitido_en_el_panel_abre_la_puerta_en_el_punto_de_control(self):
        ahora = ahora_local_db()
        _, html = self._emitir(ahora, zona="3")  # Aula A-101
        id_pase = re.search(r"Pase (\d+) emitido", html).group(1)
        punto = db.get_connection("punto")
        try:
            con_pase = repositorio.registrar_acceso(punto, "99000002", 4, True, 26, "simulado")
            self.vigilante.post(f"/pases/{id_pase}/revocar")
            sin_pase = repositorio.registrar_acceso(punto, "99000002", 4, True, 26, "simulado")
        finally:
            punto.close()
        self.assertEqual(con_pase.resultado, "permitido")
        self.assertEqual((sin_pase.resultado, sin_pase.motivo), ("denegado", "sin_pase_vigente"))

    def test_errores_al_emitir(self):
        ahora = ahora_local_db()
        casos = [
            ({"codigo_visitante": "00000000"}, "No existe una persona con el código 00000000"),
            ({"codigo_visitante": "25200001"}, "no es de tipo visitante"),
            ({"codigo_anfitrion": "99000001"}, "Un visitante no puede ser anfitrion"),
            ({"hasta": formato_local(ahora - timedelta(hours=1)),
              "desde": formato_local(ahora - timedelta(hours=2))}, "ya estaria vencido"),
            ({"hasta": ""}, "Falta el dato: vigente hasta"),
            ({"zona": "99"}, "La zona 99 no existe"),
        ]
        for extra, mensaje in casos:
            with self.subTest(extra=extra):
                _, html = self._emitir(ahora, **extra)
                self.assertIn(mensaje, html)

    def test_un_codigo_con_html_se_muestra_escapado(self):
        _, html = self._emitir(ahora_local_db(), codigo_visitante="<b>x</b>")
        self.assertNotIn("<b>x</b>", html)
        self.assertIn("&lt;b&gt;x&lt;/b&gt;", html)


# ---------------------------------------------------------------------
# Restricciones
# ---------------------------------------------------------------------
@requiere_panel
class TestRestricciones(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.vigilante = Sesion("vigilante")
        cls.incidencias_previas = utiles.maximo_incidencia()

    @classmethod
    def tearDownClass(cls):
        utiles.cerrar_incidencias_nuevas(cls.incidencias_previas)

    def test_una_restriccion_registrada_en_el_panel_bloquea_en_el_punto_de_control(self):
        ahora = ahora_local_db()
        estado, html = self.vigilante.post("/restricciones/nueva", {
            "codigo_persona": "99000002", "motivo": "Prueba automatica del panel",
            "fecha_fin": formato_local(ahora + timedelta(days=1))})
        self.assertEqual(estado, 200)
        encontrado = re.search(r"Restricción (\d+) registrada", html)
        self.assertIsNotNone(encontrado, html[:300])
        id_restriccion = encontrado.group(1)
        self.assertIn("Hugo Villanueva Rey", html)
        self.assertIn("Prueba automatica del panel", html)
        self.assertNotIn("indefinida", html.split("Hugo Villanueva Rey")[1].split("</tr>")[0])

        punto = db.get_connection("punto")
        try:
            bloqueado = repositorio.registrar_acceso(punto, "99000002", 1, True, 26, "simulado")
            _, html = self.vigilante.post(f"/restricciones/{id_restriccion}/levantar")
            libre = repositorio.registrar_acceso(punto, "99000002", 1, True, 26, "simulado")
        finally:
            punto.close()  # la incidencia de gravedad alta que genero la denegacion se cierra en tearDownClass

        self.assertEqual((bloqueado.resultado, bloqueado.motivo), ("denegado", "persona_restringida"))
        self.assertIn(f"Restricción {id_restriccion} levantada", html)
        self.assertEqual((libre.resultado, libre.motivo), ("denegado", "sin_pase_vigente"))  # sin restriccion
        self.assertNotIn("Prueba automatica del panel", html)

    def test_errores_al_registrar(self):
        casos = [
            ({"codigo_persona": "00000000", "motivo": "x"}, "No existe una persona con el código 00000000"),
            ({"codigo_persona": "99000002", "motivo": ""}, "El motivo de la restriccion es obligatorio"),
            ({"codigo_persona": "99000002", "motivo": "x", "fecha_fin": "2020-01-01T10:00"},
             "fecha_fin debe ser una fecha futura"),
        ]
        for datos, mensaje in casos:
            with self.subTest(datos=datos):
                _, html = self.vigilante.post("/restricciones/nueva", datos)
                self.assertIn(mensaje, html)

    def test_no_se_levanta_dos_veces(self):
        _, html = self.vigilante.post("/restricciones/nueva", {"codigo_persona": "99000002", "motivo": "Doble levantamiento"})
        id_restriccion = re.search(r"Restricción (\d+) registrada", html).group(1)
        self.vigilante.post(f"/restricciones/{id_restriccion}/levantar")
        _, html = self.vigilante.post(f"/restricciones/{id_restriccion}/levantar")
        self.assertIn("ya esta levantada", html)

    def test_una_persona_no_puede_tener_dos_restricciones_vigentes(self):
        _, html = self.vigilante.post("/restricciones/nueva", {"codigo_persona": "99000002", "motivo": "Primera"})
        id_restriccion = re.search(r"Restricción (\d+) registrada", html).group(1)
        try:
            _, html = self.vigilante.post("/restricciones/nueva", {"codigo_persona": "99000002", "motivo": "Segunda"})
            self.assertIn("ya tiene una restriccion vigente", html)
        finally:
            self.vigilante.post(f"/restricciones/{id_restriccion}/levantar")


# ---------------------------------------------------------------------
# Reportes
# ---------------------------------------------------------------------
@requiere_panel
class TestReportes(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sesiones = {rol: Sesion(rol) for rol in ROLES}

    def test_el_indice_muestra_los_reportes_del_rol(self):
        for rol in ROLES:
            with self.subTest(rol=rol):
                _, html = self.sesiones[rol].get("/reportes")
                for _, definicion in panel.reportes_para(rol):
                    self.assertIn(definicion["procedimiento"], html)
                fuera = [d for c, d in panel.REPORTES.items() if rol not in d["roles"]]
                for definicion in fuera:
                    self.assertNotIn(definicion["procedimiento"], html)

    def test_cada_reporte_se_ejecuta_con_el_usuario_oracle_de_su_rol(self):
        consultas = {
            "asistencia-seccion": "?ejecutar=1&id_seccion=1",
            "asistencia-sesion": "?ejecutar=1&id_sesion=6",
            "alumnos-en-riesgo": "?ejecutar=1",
            "ranking-tardanzas": "?ejecutar=1",
            "accesos-denegados": "?ejecutar=1",
            "incidencias": "?ejecutar=1&estado=abierta",
            "pases-vigentes": "",
            "uso-aulas": "?ejecutar=1",
            "flujo-por-hora": "?ejecutar=1&id_zona=1",
        }
        self.assertEqual(set(consultas), set(panel.REPORTES))
        for rol in ROLES:
            for clave, definicion in panel.reportes_para(rol):
                with self.subTest(rol=rol, reporte=clave):
                    estado, html = self.sesiones[rol].get(f"/reportes/{clave}{consultas[clave]}")
                    self.assertEqual(estado, 200)
                    self.assertIn("fila(s)", html)
                    self.assertNotIn("alert-danger", html)

    def test_contenido_de_algunos_reportes(self):
        _, html = self.sesiones["admin"].get("/reportes/accesos-denegados?ejecutar=1")
        self.assertIn("TOTAL GENERAL", html)
        self.assertIn("Subtotal del motivo", html)
        _, html = self.sesiones["admin"].get("/reportes/flujo-por-hora?ejecutar=1")
        self.assertEqual(html.count("<tr>") - 1, 24)  # encabezado + 24 horas
        _, html = self.sesiones["docente"].get("/reportes/asistencia-seccion?ejecutar=1&id_seccion=1")
        self.assertIn("Ana Torres Quispe", html)
        self.assertIn("% asistencia", html)

    def test_parametros_invalidos_se_informan(self):
        admin = self.sesiones["admin"]
        _, html = admin.get("/reportes/asistencia-seccion?ejecutar=1&id_seccion=abc")
        self.assertIn("debe ser un número", html)
        _, html = admin.get("/reportes/asistencia-seccion?ejecutar=1")
        self.assertIn("Falta el dato", html)
        _, html = admin.get("/reportes/asistencia-seccion?ejecutar=1&id_seccion=999")
        self.assertIn("La seccion 999 no existe", html)
        _, html = admin.get("/reportes/ranking-tardanzas?ejecutar=1&desde=2026-12-31&hasta=2026-01-01")
        self.assertIn("La fecha desde no puede ser posterior", html)
        _, html = admin.get("/reportes/accesos-denegados?ejecutar=1&desde=hoy")
        self.assertIn("AAAA-MM-DD", html)
        _, html = admin.get("/reportes/incidencias?ejecutar=1&estado=cerrada")
        self.assertIn("valor no válido", html)

    def test_descarga_csv(self):
        respuesta = self.sesiones["admin"].c.get("/reportes/accesos-denegados?ejecutar=1&formato=csv")
        self.assertEqual(respuesta.status_code, 200)
        self.assertTrue(respuesta.mimetype.startswith("text/csv"))
        self.assertIn("attachment", respuesta.headers["Content-Disposition"])
        texto = respuesta.get_data(as_text=True)
        self.assertTrue(texto.startswith("﻿"))
        self.assertIn("motivo,zona,total", texto.splitlines()[0])
        self.assertIn("TOTAL GENERAL", texto)

    def test_un_rol_no_ejecuta_reportes_de_otro(self):
        self.assertEqual(self.sesiones["vigilante"].get("/reportes/uso-aulas?ejecutar=1")[0], 403)
        self.assertEqual(self.sesiones["docente"].get("/reportes/accesos-denegados?ejecutar=1")[0], 403)
        self.assertEqual(self.sesiones["docente"].c.get("/reportes/flujo-por-hora?ejecutar=1&formato=csv").status_code, 403)


if __name__ == "__main__":
    unittest.main()
