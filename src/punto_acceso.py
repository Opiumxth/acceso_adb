"""Punto de acceso: escanea el QR, verifica a la persona en Oracle, comprueba
el rostro y registra el acceso. Se conecta con el usuario u_punto.

Flujo de cada lectura:
    1. leer el codigo del QR con la camara
    2. p_verificar_persona        -> existe, nombre, tipo y estado
    3. verificacion del rostro    -> LBPH contra datos/models (umbral = parametro UMBRAL_LBPH)
    4. p_registrar_acceso         -> la base decide: acceso, asistencia e incidencias

La decision NO se toma aqui: el programa solo informa lo que devuelve la base.

Uso:
    python src/punto_acceso.py                    # modo continuo en el punto de config.ID_PUNTO
    python src/punto_acceso.py --una-vez          # una sola lectura
    python src/punto_acceso.py --punto 4          # otro punto de control
    python src/punto_acceso.py --simular 25200001 --rostro-ok 1 --confianza 24.5
                                                  # sin camara; el metodo queda como 'simulado'
"""
import argparse
import sys
import time
from dataclasses import dataclass
from typing import Optional

import oracledb

import acceder_rostro
import camara
import config
import db
import escanear_qr
import repositorio

# Texto para el operador segun el motivo de la denegacion (ver p_registrar_acceso)
MENSAJES_MOTIVO = {
    "codigo_inexistente": "El codigo no esta registrado.",
    "persona_inactiva": "La persona esta inactiva o suspendida.",
    "rostro_no_coincide": "El rostro no coincide con el del QR.",
    "persona_restringida": "Persona con restriccion vigente. Se genero una incidencia.",
    "sin_pase_vigente": "No tiene un pase vigente para esta zona.",
    "zona_no_autorizada": "No esta autorizado para esta zona.",
    "fuera_de_horario": "Fuera del horario permitido para esta zona.",
}

# Aviso al operador cuando no se pudo comparar el rostro
AVISOS_ROSTRO = {
    "sin_modelo": "No hay modelo facial para este codigo: registre el rostro primero.",
    "sin_rostro": "No se detecto ningun rostro frente a la camara.",
    "camara": "No se pudo usar la camara.",
    "cancelado": "Verificacion de rostro cancelada.",
}

@dataclass
class LecturaProcesada:
    codigo: str
    persona: Optional[repositorio.Persona]            # None si el codigo no existe
    rostro: Optional[acceder_rostro.ResultadoRostro]  # None si no se llego a verificar
    acceso: repositorio.ResultadoAcceso

def procesar_lectura(conn, codigo, id_punto, verificar_rostro, umbral, metodo="qr_rostro"):
    """Procesa un codigo ya leido y devuelve LecturaProcesada.

    verificar_rostro: funcion (codigo, umbral) -> ResultadoRostro. Se pasa como
    parametro para poder probar el flujo sin camara.
    """
    persona = repositorio.verificar_persona(conn, codigo)

    rostro = None
    if persona is not None and persona.estado == "activo":
        rostro = verificar_rostro(codigo, umbral)
        rostro_ok, confianza = rostro.ok, rostro.confianza
    else:
        # codigo inexistente o persona no activa: la base lo deniega antes de
        # mirar el rostro (reglas a y b), no hace falta encender la camara
        rostro_ok, confianza = False, None

    acceso = repositorio.registrar_acceso(conn, codigo, id_punto, rostro_ok, confianza, metodo)
    return LecturaProcesada(codigo, persona, rostro, acceso)


def mostrar_resultado(lectura, id_punto):
    """Imprime el resultado de una lectura para el operador."""
    acceso = lectura.acceso
    linea = "=" * 56
    print(linea)
    if acceso.resultado == "permitido":
        print("  ACCESO PERMITIDO")
    else:
        print("  ACCESO DENEGADO")
    if lectura.persona is not None:
        print(f"  Persona   : {lectura.persona.nombre} ({lectura.persona.tipo})")
    else:
        print(f"  Codigo    : {lectura.codigo} (no registrado)")
    print(f"  Punto     : {id_punto}")
    if lectura.rostro is not None and lectura.rostro.confianza is not None:
        print(f"  Confianza : {lectura.rostro.confianza:.2f} (menor es mejor)")
    if acceso.resultado == "denegado":
        explicacion = MENSAJES_MOTIVO.get(acceso.motivo, "")
        print(f"  Motivo    : {acceso.motivo}" + (f" - {explicacion}" if explicacion else ""))
        if lectura.rostro is not None and lectura.rostro.detalle in AVISOS_ROSTRO:
            print(f"  Aviso     : {AVISOS_ROSTRO[lectura.rostro.detalle]}")
    print(f"  Registro  : #{acceso.id_acceso}")
    print(linea)


def ejecutar_acceso(id_punto=None, una_vez=True, pausa=2.0, metodo="qr_rostro",
                    lector_qr=None, verificar_rostro=None, conn=None):
    """Ciclo del punto de acceso. Devuelve la ultima LecturaProcesada (o None).

    una_vez=True procesa una sola lectura (menu de consola); False repite hasta
    que se pulse ESC en la ventana del QR o Ctrl+C (modo kiosco).
    lector_qr / verificar_rostro / conn: reemplazos para pruebas; por defecto
    se usan la camara real y una conexion nueva con u_punto.
    """
    id_punto = config.ID_PUNTO if id_punto is None else id_punto
    usa_camara = lector_qr is None
    lector_qr = lector_qr or escanear_qr.leer_qr_camara
    verificar_rostro = verificar_rostro or acceder_rostro.verificar_rostro

    propia = conn is None
    ultima = None
    try:
        if propia:
            conn = db.get_connection("punto")
        umbral = repositorio.obtener_umbral_lbph(conn)
        print(f"Punto de control {id_punto} | umbral LBPH {umbral:g} | usuario Oracle u_punto")

        while True:
            if usa_camara:
                print("\nAcerque su codigo QR a la camara (ESC para salir)...")
            try:
                codigo = lector_qr()
            except escanear_qr.LecturaCancelada:
                print("Lectura cancelada.")
                return ultima
            if not codigo:
                if una_vez:
                    print("No se encontro codigo qr")
                    return ultima
                continue  # modo kiosco: vencio la espera, se vuelve a escuchar

            try:
                ultima = procesar_lectura(conn, codigo, id_punto, verificar_rostro, umbral, metodo)
            except db.ErrorAplicacion as exc:
                # error controlado de la base (por ejemplo punto de control inactivo)
                print(f"No se pudo registrar el acceso: {exc.mensaje}")
                if una_vez:
                    return ultima
                time.sleep(pausa)
                continue

            mostrar_resultado(ultima, id_punto)
            if una_vez:
                return ultima
            time.sleep(pausa)
    except KeyboardInterrupt:
        print("\nPunto de acceso detenido.")
        return ultima
    finally:
        if propia and conn is not None:
            conn.close()


def main(argv=None):
    parser = argparse.ArgumentParser(description="Punto de acceso con QR y reconocimiento facial")
    parser.add_argument("--punto", type=int, default=None,
                        help="id del punto de control (por defecto ID_PUNTO de .env)")
    parser.add_argument("--una-vez", action="store_true", help="procesar una sola lectura y terminar")
    parser.add_argument("--simular", metavar="CODIGO",
                        help="usar este codigo sin camara (metodo 'simulado')")
    parser.add_argument("--rostro-ok", type=int, choices=(0, 1), default=1,
                        help="con --simular: 1 el rostro coincide, 0 no coincide")
    parser.add_argument("--confianza", type=float, default=None,
                        help="con --simular: confianza LBPH a registrar")
    args = parser.parse_args(argv)

    try:
        if args.simular:
            resultado_rostro = acceder_rostro.ResultadoRostro(
                bool(args.rostro_ok), args.confianza, "simulado")
            ejecutar_acceso(
                id_punto=args.punto, una_vez=True, metodo="simulado",
                lector_qr=lambda: args.simular,
                verificar_rostro=lambda codigo, umbral: resultado_rostro)
        else:
            ejecutar_acceso(id_punto=args.punto, una_vez=args.una_vez)
    except db.ConfiguracionError as exc:
        print(f"Configuracion incompleta: {exc}")
        return 2
    except camara.CamaraError as exc:
        print(f"Error de camara: {exc}")
        return 3
    except db.ErrorAplicacion as exc:
        print(f"Error: {exc.mensaje}")
        return 4
    except oracledb.Error as exc:
        print(f"No se pudo usar la base de datos: {exc}")
        return 5
    return 0

if __name__ == "__main__":
    sys.exit(main())
