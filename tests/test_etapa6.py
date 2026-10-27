"""Pruebas de la parte Python (Etapa 6).

Ejecutar desde la raiz del repositorio, con el contenedor oracle-xe encendido:

    ./venv/bin/python -m unittest discover -s tests -v

Las pruebas que usan la base se conectan de verdad (usuarios u_punto y u_admin
de .env) y se omiten solas si Oracle no esta disponible. Las de camara usan
una camara falsa y un modelo LBPH sintetico: no se enciende ninguna webcam y
no se usan fotos de personas.
"""
import contextlib
import io
import math
import random
import string
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import cv2
import numpy as np
import oracledb
import qrcode

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))

import acceder_rostro  # noqa: E402
import biometria  # noqa: E402
import config  # noqa: E402
import db  # noqa: E402
import escanear_qr  # noqa: E402
import punto_acceso  # noqa: E402
import registro  # noqa: E402
import repositorio  # noqa: E402


def _db_disponible():
    try:
        db.get_connection("punto").close()
        db.get_connection("admin").close()
        return True
    except Exception:  # sin contenedor, sin claves en .env, etc.
        return False


HAY_DB = _db_disponible()
requiere_db = unittest.skipUnless(HAY_DB, "Oracle no disponible o faltan claves en .env")


def _codigo_aleatorio(prefijo):
    return prefijo + "".join(random.choices(string.digits, k=8 - len(prefijo)))


def _silencio():
    return contextlib.redirect_stdout(io.StringIO())


class CapturaFalsa:
    """Camara de mentira: devuelve siempre los mismos fotogramas."""

    def __init__(self, frames):
        self.frames = list(frames)
        self.indice = 0
        self.liberada = False

    def read(self):
        if not self.frames:
            return False, None
        frame = self.frames[self.indice % len(self.frames)]
        self.indice += 1
        return True, frame.copy()

    def release(self):
        self.liberada = True


def _bgr(gris):
    return cv2.cvtColor(gris, cv2.COLOR_GRAY2BGR)


# ---------------------------------------------------------------------
# Configuracion y rutas (no necesitan la base)
# ---------------------------------------------------------------------
class TestConfig(unittest.TestCase):
    def test_env_conserva_el_numeral_dentro_de_la_clave(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = Path(tmp) / ".env"
            env.write_text(
                "# comentario\n\nCLAVE_PRUEBA_A=Abc#123\nCLAVE_PRUEBA_B=\"con espacios y #\"\n"
                "VACIA_PRUEBA=\n", encoding="utf-8")
            with mock.patch.dict("os.environ", {}, clear=False):
                config.cargar_env(env)
                import os
                self.assertEqual(os.environ["CLAVE_PRUEBA_A"], "Abc#123")
                self.assertEqual(os.environ["CLAVE_PRUEBA_B"], "con espacios y #")
                self.assertEqual(os.environ["VACIA_PRUEBA"], "")
                for nombre in ("CLAVE_PRUEBA_A", "CLAVE_PRUEBA_B", "VACIA_PRUEBA"):
                    os.environ.pop(nombre, None)

    def test_rol_desconocido(self):
        with self.assertRaises(ValueError):
            config.credenciales("superusuario")

    def test_usuarios_por_defecto(self):
        with mock.patch.dict("os.environ", {}, clear=True):
            self.assertEqual(config.credenciales("punto"), ("u_punto", None))
            self.assertEqual(config.credenciales("admin"), ("u_admin", None))

    def test_rutas_biometricas_dentro_de_datos(self):
        self.assertEqual(config.ruta_modelo("25200001").name, "modelo_lbph_25200001.yml")
        self.assertEqual(config.ruta_qr("25200001").name, "qr_25200001.png")
        for ruta in (config.ruta_modelo("25200001"), config.ruta_qr("25200001"),
                     config.ruta_rostros("25200001")):
            self.assertIn(config.DATOS_DIR, ruta.parents)

    def test_codigo_invalido_no_se_acepta_en_rutas(self):
        for malo in ("../../etc", "1234567", "abcdefgh", "123456789", ""):
            with self.assertRaises(ValueError):
                biometria.validar_codigo(malo)


# ---------------------------------------------------------------------
# Lectura de QR con camara falsa
# ---------------------------------------------------------------------
class TestLecturaQR(unittest.TestCase):
    def _frame_qr(self, texto):
        imagen = qrcode.make(texto).convert("RGB")
        return cv2.cvtColor(np.array(imagen), cv2.COLOR_RGB2BGR)

    def test_lee_el_codigo_de_un_qr(self):
        captura = CapturaFalsa([self._frame_qr("25200001")])
        codigo = escanear_qr.leer_qr_camara(timeout=5, mostrar_ventana=False, captura=captura)
        self.assertEqual(codigo, "25200001")

    def test_sin_qr_vence_el_tiempo_y_devuelve_none(self):
        captura = CapturaFalsa([np.full((240, 320, 3), 255, dtype=np.uint8)])
        codigo = escanear_qr.leer_qr_camara(timeout=0.3, mostrar_ventana=False, captura=captura)
        self.assertIsNone(codigo)

    def test_camara_que_falla_termina_sin_error(self):
        codigo = escanear_qr.leer_qr_camara(timeout=1, mostrar_ventana=False,
                                            captura=CapturaFalsa([]))
        self.assertIsNone(codigo)


# ---------------------------------------------------------------------
# Verificacion de rostro con modelo sintetico y camara falsa
# ---------------------------------------------------------------------
class FalsoDetector:
    """Reemplaza al Haar Cascade: siempre 'detecta' un rostro que ocupa todo el fotograma."""

    def __init__(self, *args, **kwargs):
        pass

    def detectMultiScale(self, *args, **kwargs):
        return [(0, 0, 200, 200)]


class TestVerificarRostro(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        rng = np.random.default_rng(7)
        cls.rostro_a = rng.integers(0, 256, (200, 200), dtype=np.uint8)
        # imagen suave, muy distinta en textura (LBP) al ruido del modelo
        cls.rostro_b = np.tile(np.linspace(0, 255, 200).astype(np.uint8), (200, 1))
        cls.tmp = tempfile.TemporaryDirectory()
        cls.modelo = Path(cls.tmp.name) / "modelo_lbph_99999999.yml"
        reconocedor = cv2.face.LBPHFaceRecognizer_create(
            radius=1, neighbors=8, grid_x=8, grid_y=8, threshold=100.0)
        reconocedor.train([cls.rostro_a], np.array([0]))
        reconocedor.save(str(cls.modelo))

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def _verificar(self, frame, umbral=40, timeout=1.0, detector=FalsoDetector):
        captura = CapturaFalsa([_bgr(frame)])
        with mock.patch.object(acceder_rostro.cv2, "CascadeClassifier", detector):
            resultado = acceder_rostro.verificar_rostro(
                "99999999", umbral, timeout=timeout, mostrar_ventana=False,
                captura=captura, ruta_modelo=self.modelo)
        return resultado

    def test_coincide_con_el_rostro_del_modelo(self):
        r = self._verificar(self.rostro_a)
        self.assertTrue(r.ok)
        self.assertEqual(r.detalle, "coincide")
        self.assertLess(r.confianza, 40)

    def test_no_coincide_con_otro_rostro_y_la_confianza_cabe_en_la_base(self):
        r = self._verificar(self.rostro_b, timeout=0.3)
        self.assertFalse(r.ok)
        self.assertEqual(r.detalle, "no_coincide")
        self.assertGreaterEqual(r.confianza, 40)
        self.assertLessEqual(r.confianza, acceder_rostro.CONFIANZA_MAXIMA)  # number(6,2)

    def test_sin_rostro_en_la_imagen(self):
        class SinRostros(FalsoDetector):
            def detectMultiScale(self, *args, **kwargs):
                return []

        r = self._verificar(self.rostro_a, timeout=0.3, detector=SinRostros)
        self.assertEqual(r, acceder_rostro.ResultadoRostro(False, None, "sin_rostro"))

    def test_sin_modelo(self):
        r = acceder_rostro.verificar_rostro(
            "25200001", 40, timeout=0.2, mostrar_ventana=False,
            captura=CapturaFalsa([]), ruta_modelo=Path(self.tmp.name) / "no_existe.yml")
        self.assertEqual(r, acceder_rostro.ResultadoRostro(False, None, "sin_modelo"))

    def test_modelo_danado_se_trata_como_sin_modelo(self):
        danado = Path(self.tmp.name) / "danado.yml"
        danado.write_text("esto no es un modelo", encoding="utf-8")
        r = acceder_rostro.verificar_rostro(
            "25200001", 40, timeout=0.2, mostrar_ventana=False,
            captura=CapturaFalsa([]), ruta_modelo=danado)
        self.assertEqual(r.detalle, "sin_modelo")

    def test_camara_que_no_entrega_imagen(self):
        r = acceder_rostro.verificar_rostro(
            "99999999", 40, timeout=0.5, mostrar_ventana=False,
            captura=CapturaFalsa([]), ruta_modelo=self.modelo)
        self.assertEqual(r.detalle, "camara")

    def test_acotar_valores_enormes_o_infinitos(self):
        self.assertEqual(acceder_rostro._acotar(1.7976931348623157e308), 9999.99)
        self.assertEqual(acceder_rostro._acotar(math.inf), 9999.99)
        self.assertEqual(acceder_rostro._acotar(math.nan), 9999.99)
        self.assertAlmostEqual(acceder_rostro._acotar(12.34), 12.34)


# ---------------------------------------------------------------------
# Conexion y repositorio (Oracle real)
# ---------------------------------------------------------------------
@requiere_db
class TestConexion(unittest.TestCase):
    def test_sesion_de_u_punto_con_esquema_del_dueno(self):
        conn = db.get_connection("punto")
        try:
            with conn.cursor() as cur:
                cur.execute("select sys_context('USERENV','SESSION_USER'), "
                            "sys_context('USERENV','CURRENT_SCHEMA') from dual")
                usuario, esquema = cur.fetchone()
        finally:
            conn.close()
        self.assertEqual(usuario, "U_PUNTO")
        self.assertEqual(esquema, "ACCESO_OWNER")

    def test_u_punto_no_puede_leer_tablas(self):
        conn = db.get_connection("punto")
        try:
            with conn.cursor() as cur:
                with self.assertRaises(oracledb.DatabaseError) as ctx:
                    cur.execute("select count(*) from accesos")
        finally:
            conn.close()
        self.assertIn("ORA-00942", str(ctx.exception))

    def test_sin_clave_se_avisa_con_un_error_claro(self):
        with mock.patch.object(config, "credenciales", return_value=("u_punto", None)):
            with self.assertRaises(db.ConfiguracionError):
                db.get_connection("punto")

    def test_clave_incorrecta_por_parametro(self):
        with self.assertRaises(oracledb.DatabaseError) as ctx:
            db.get_connection("punto", password="clave-equivocada")
        self.assertIn("ORA-01017", str(ctx.exception))


@requiere_db
class TestRepositorio(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.conn = db.get_connection("punto")

    @classmethod
    def tearDownClass(cls):
        cls.conn.close()

    def test_verificar_persona_existente(self):
        persona = repositorio.verificar_persona(self.conn, "25200001")
        self.assertEqual(persona, repositorio.Persona("Ana Torres Quispe", "estudiante", "activo"))

    def test_verificar_persona_inexistente(self):
        self.assertIsNone(repositorio.verificar_persona(self.conn, _codigo_aleatorio("7")))

    def test_umbral_lbph_viene_de_la_tabla_parametros(self):
        umbral = repositorio.obtener_umbral_lbph(self.conn)
        self.assertEqual(umbral, float(repositorio.obtener_parametro(self.conn, "UMBRAL_LBPH")))
        self.assertGreater(umbral, 0)

    def test_parametro_inexistente_da_error_controlado(self):
        with self.assertRaises(db.ErrorAplicacion) as ctx:
            repositorio.obtener_parametro(self.conn, "NO_EXISTE")
        self.assertEqual(ctx.exception.codigo, 20004)

    def test_registrar_acceso_permitido_y_denegado_no_es_error(self):
        permitido = repositorio.registrar_acceso(self.conn, "90000001", 1, True, 20.5, "simulado")
        self.assertEqual((permitido.resultado, permitido.motivo), ("permitido", None))
        self.assertGreater(permitido.id_acceso, 0)

        denegado = repositorio.registrar_acceso(self.conn, "90000001", 1, False, 70, "simulado")
        self.assertEqual((denegado.resultado, denegado.motivo), ("denegado", "rostro_no_coincide"))

    def test_punto_inexistente_es_error_controlado(self):
        with self.assertRaises(db.ErrorAplicacion) as ctx:
            repositorio.registrar_acceso(self.conn, "25200001", 999, True, 20, "simulado")
        self.assertEqual(ctx.exception.codigo, 20002)

    def test_u_punto_no_puede_usar_procedimientos_de_otro_rol(self):
        with self.assertRaises(oracledb.DatabaseError) as ctx:
            repositorio.listar_personas(self.conn)
        self.assertIn("PLS-00201", str(ctx.exception))

    def test_nombre_de_procedimiento_se_valida(self):
        with self.assertRaises(ValueError):
            repositorio.consultar_cursor(self.conn, "p_x; drop table accesos")


# ---------------------------------------------------------------------
# Flujo del punto de acceso (Oracle real, rostro simulado)
# ---------------------------------------------------------------------
@requiere_db
class TestProcesarLectura(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.conn = db.get_connection("punto")
        cls.umbral = repositorio.obtener_umbral_lbph(cls.conn)

    @classmethod
    def tearDownClass(cls):
        cls.conn.close()

    def _verificador(self, ok, confianza):
        llamadas = []

        def verificar(codigo, umbral):
            llamadas.append((codigo, umbral))
            return acceder_rostro.ResultadoRostro(ok, confianza, "simulado")

        verificar.llamadas = llamadas
        return verificar

    def _procesar(self, codigo, verificador, id_punto=1):
        return punto_acceso.procesar_lectura(
            self.conn, codigo, id_punto, verificador, self.umbral, metodo="simulado")

    def test_codigo_inexistente_no_pide_el_rostro(self):
        verificador = self._verificador(True, 10)
        lectura = self._procesar(_codigo_aleatorio("7"), verificador)
        self.assertIsNone(lectura.persona)
        self.assertEqual(lectura.acceso.motivo, "codigo_inexistente")
        self.assertEqual(verificador.llamadas, [])

    def test_persona_inactiva_no_pide_el_rostro(self):
        verificador = self._verificador(True, 10)
        lectura = self._procesar("25200009", verificador)
        self.assertEqual(lectura.acceso.motivo, "persona_inactiva")
        self.assertEqual(verificador.llamadas, [])

    def test_persona_activa_se_verifica_con_el_umbral_de_la_base(self):
        verificador = self._verificador(True, 21.0)
        lectura = self._procesar("90000001", verificador)
        self.assertEqual(lectura.acceso.resultado, "permitido")
        self.assertEqual(verificador.llamadas, [("90000001", self.umbral)])

    def test_rostro_que_no_coincide(self):
        lectura = self._procesar("25200003", self._verificador(False, 68.5))
        self.assertEqual((lectura.acceso.resultado, lectura.acceso.motivo),
                         ("denegado", "rostro_no_coincide"))

    def test_persona_restringida_llega_a_la_regla_de_restriccion(self):
        lectura = self._procesar("25200010", self._verificador(True, 23.0))
        self.assertEqual(lectura.acceso.motivo, "persona_restringida")

    def test_zona_no_autorizada(self):
        lectura = self._procesar("25200003", self._verificador(True, 22.0), id_punto=7)
        self.assertEqual(lectura.acceso.motivo, "zona_no_autorizada")

    def test_ejecutar_acceso_imprime_el_resultado(self):
        salida = io.StringIO()
        with contextlib.redirect_stdout(salida):
            lectura = punto_acceso.ejecutar_acceso(
                una_vez=True, metodo="simulado",
                lector_qr=lambda: "90000001",
                verificar_rostro=self._verificador(True, 19.0))
        self.assertEqual(lectura.acceso.resultado, "permitido")
        texto = salida.getvalue()
        self.assertIn("ACCESO PERMITIDO", texto)
        self.assertIn("Ricardo Salas Medina", texto)
        self.assertNotIn("Acerque su codigo QR", texto)  # no hay camara en la simulacion

    def test_ejecutar_acceso_sin_qr(self):
        salida = io.StringIO()
        with contextlib.redirect_stdout(salida):
            lectura = punto_acceso.ejecutar_acceso(una_vez=True, lector_qr=lambda: None)
        self.assertIsNone(lectura)
        self.assertIn("No se encontro codigo qr", salida.getvalue())

    def test_ejecutar_acceso_cancelado_con_esc(self):
        def cancelar():
            raise escanear_qr.LecturaCancelada()

        salida = io.StringIO()
        with contextlib.redirect_stdout(salida):
            punto_acceso.ejecutar_acceso(una_vez=True, lector_qr=cancelar)
        self.assertIn("Lectura cancelada", salida.getvalue())

    def test_punto_inexistente_se_informa_sin_romper(self):
        salida = io.StringIO()
        with contextlib.redirect_stdout(salida):
            lectura = punto_acceso.ejecutar_acceso(
                id_punto=999, una_vez=True, metodo="simulado",
                lector_qr=lambda: "90000001",
                verificar_rostro=self._verificador(True, 20))
        self.assertIsNone(lectura)
        self.assertIn("no existe", salida.getvalue())

    def test_linea_de_comandos_con_simulacion(self):
        salida = io.StringIO()
        with contextlib.redirect_stdout(salida):
            codigo_salida = punto_acceso.main(
                ["--simular", "90000001", "--rostro-ok", "1", "--confianza", "20"])
        self.assertEqual(codigo_salida, 0)
        self.assertIn("ACCESO PERMITIDO", salida.getvalue())


# ---------------------------------------------------------------------
# Alta, edicion y baja de personas con el rol admin (Oracle real)
# ---------------------------------------------------------------------
@requiere_db
class TestRegistroPersonas(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.conn = db.get_connection("admin")

    @classmethod
    def tearDownClass(cls):
        cls.conn.close()

    def _datos(self):
        return {
            "codigo": _codigo_aleatorio("86"),
            "nombre": "Prueba Python Automatica",
            "dni": _codigo_aleatorio("85"),
            "tipo": "visitante",
            "correo": "prueba.python@campus.test",
        }

    def _existe(self, codigo):
        return repositorio.buscar_personas(self.conn, texto=codigo)

    def test_ciclo_completo_alta_edicion_busqueda_y_eliminacion(self):
        datos = self._datos()
        id_persona = repositorio.registrar_persona(self.conn, **datos)
        self.assertGreaterEqual(id_persona, 1000)

        repositorio.modificar_persona(self.conn, datos["codigo"], nombre="Nombre Cambiado")
        filas = self._existe(datos["codigo"])
        self.assertEqual(len(filas), 1)
        self.assertEqual(filas[0]["nombre"], "Nombre Cambiado")
        self.assertEqual(filas[0]["tipo"], "visitante")

        self.assertEqual(repositorio.eliminar_persona(self.conn, datos["codigo"]), "eliminada")
        self.assertEqual(self._existe(datos["codigo"]), [])

    def test_estudiante_se_guarda_con_su_subtipo(self):
        datos = self._datos()
        datos.update(tipo="estudiante", id_escuela=1, ciclo=4)
        repositorio.registrar_persona(self.conn, **datos)
        try:
            fila = self._existe(datos["codigo"])[0]
            self.assertEqual(fila["ciclo"], 4)
            self.assertEqual(fila["escuela"], "Ingenieria de Sistemas")
        finally:
            repositorio.eliminar_persona(self.conn, datos["codigo"])

    def test_listado_de_escuelas(self):
        escuelas = repositorio.listar_escuelas(self.conn)
        self.assertEqual([e["id_escuela"] for e in escuelas][:3], [1, 2, 3])

    def test_codigo_duplicado_es_error_controlado(self):
        datos = self._datos()
        repositorio.registrar_persona(self.conn, **datos)
        try:
            with self.assertRaises(db.ErrorAplicacion) as ctx:
                repositorio.registrar_persona(self.conn, **datos)
            self.assertEqual(ctx.exception.codigo, 20005)
        finally:
            repositorio.eliminar_persona(self.conn, datos["codigo"])

    def test_alta_con_biometria_exitosa(self):
        datos = self._datos()
        with _silencio():
            registro.registrar_persona_con_rostro(
                self.conn, datos, enrolar=lambda codigo, via, video: True)
        try:
            self.assertEqual(len(self._existe(datos["codigo"])), 1)
        finally:
            repositorio.eliminar_persona(self.conn, datos["codigo"])

    def test_si_falla_la_biometria_se_deshace_el_alta(self):
        datos = self._datos()
        with _silencio(), self.assertRaises(registro.RegistroError):
            registro.registrar_persona_con_rostro(
                self.conn, datos, enrolar=lambda codigo, via, video: False)
        self.assertEqual(self._existe(datos["codigo"]), [])

    def test_si_la_captura_lanza_una_excepcion_tambien_se_deshace(self):
        datos = self._datos()

        def captura_rota(codigo, via, video):
            raise RuntimeError("la camara se desconecto")

        with _silencio(), self.assertRaises(RuntimeError):
            registro.registrar_persona_con_rostro(self.conn, datos, enrolar=captura_rota)
        self.assertEqual(self._existe(datos["codigo"]), [])

    def test_un_duplicado_no_borra_a_la_persona_original(self):
        datos = self._datos()
        repositorio.registrar_persona(self.conn, **datos)
        try:
            with _silencio(), self.assertRaises(db.ErrorAplicacion):
                registro.registrar_persona_con_rostro(
                    self.conn, datos, enrolar=lambda codigo, via, video: True)
            self.assertEqual(len(self._existe(datos["codigo"])), 1)
        finally:
            repositorio.eliminar_persona(self.conn, datos["codigo"])

    def test_enrolar_persona_que_no_existe(self):
        with self.assertRaises(registro.RegistroError):
            registro.enrolar_persona_existente(
                self.conn, _codigo_aleatorio("7"), enrolar=lambda codigo, via, video: True)

    def test_enrolar_persona_existente_usa_su_codigo(self):
        recibido = []

        def enrolar(codigo, via, video):
            recibido.append((codigo, via))
            return True

        with _silencio():
            ok = registro.enrolar_persona_existente(self.conn, "25200001", "camara", enrolar=enrolar)
        self.assertTrue(ok)
        self.assertEqual(recibido, [("25200001", "camara")])


class TestArchivosBiometricos(unittest.TestCase):
    def test_borrar_archivos_solo_toca_la_carpeta_de_datos(self):
        with tempfile.TemporaryDirectory() as tmp:
            datos = Path(tmp)
            with mock.patch.object(config, "ROSTROS_DIR", datos / "faces"), \
                    mock.patch.object(config, "MODELOS_DIR", datos / "models"), \
                    mock.patch.object(config, "QR_DIR", datos / "qrcodes"):
                (datos / "faces" / "86000001").mkdir(parents=True)
                (datos / "faces" / "86000001" / "86000001_0000.jpg").write_bytes(b"x")
                (datos / "models").mkdir()
                (datos / "models" / "modelo_lbph_86000001.yml").write_text("m")
                (datos / "qrcodes").mkdir()
                (datos / "qrcodes" / "qr_86000001.png").write_bytes(b"q")
                (datos / "faces" / "86000002").mkdir()  # otra persona: no se debe borrar

                borrados = biometria.borrar_archivos("86000001")

                self.assertEqual(len(borrados), 3)
                self.assertFalse((datos / "faces" / "86000001").exists())
                self.assertTrue((datos / "faces" / "86000002").exists())


if __name__ == "__main__":
    unittest.main()
