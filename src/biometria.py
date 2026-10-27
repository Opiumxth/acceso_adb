"""Datos biometricos en disco (carpeta datos/, fuera del repositorio).

Aqui viven los rostros capturados, el modelo LBPH de cada persona y la
imagen de su QR. La base de datos solo guarda a la persona; estos archivos
se identifican por el codigo de 8 digitos.
"""
import re
import shutil

import config
import generar_qr
import grabar_modelo
import video_pregrabado

_CODIGO = re.compile(r"^\d{8}$")


def validar_codigo(codigo):
    """El codigo es el contenido del QR: 8 digitos. Tambien protege las rutas de disco."""
    if not isinstance(codigo, str) or not _CODIGO.match(codigo):
        raise ValueError("El codigo debe ser un numero de 8 digitos.")
    return codigo


def capturar_rostros(codigo, via="camara", video=None):
    """Guarda fotos del rostro en datos/faces/<codigo>. Devuelve cuantas se guardaron."""
    validar_codigo(codigo)
    carpeta = str(config.ruta_rostros(codigo))
    if via == "camara":
        print("Mantenga 'p' para empezar a capturar rostros y 'q' para salir de la ventana de video")
        return grabar_modelo.grabar_modelo(carpeta, codigo)
    if via == "video":
        return video_pregrabado.extraer_caras(video, carpeta, codigo)
    raise ValueError(f"Via de captura no valida: {via!r}")


def enrolar(codigo, via="camara", video=None):
    """Captura los rostros, entrena el modelo LBPH y genera el QR.

    Devuelve True si quedo todo listo; False si no se capturo ningun rostro o
    el entrenamiento fallo.
    """
    validar_codigo(codigo)
    if capturar_rostros(codigo, via, video) == 0:
        print("No se capturo ningun rostro.")
        return False
    if not generar_qr.entrenar_modelo(codigo):
        return False
    generar_qr.generar_qr(codigo)
    return True


def borrar_archivos(codigo):
    """Elimina rostros, modelo y QR de la persona. Devuelve lo que se borro."""
    validar_codigo(codigo)
    borrados = []
    carpeta = config.ruta_rostros(codigo)
    if carpeta.is_dir():
        shutil.rmtree(carpeta)
        borrados.append(f"rostros ({carpeta})")
    for ruta, etiqueta in ((config.ruta_modelo(codigo), "modelo"),
                           (config.ruta_qr(codigo), "QR")):
        if ruta.is_file():
            ruta.unlink()
            borrados.append(f"{etiqueta} ({ruta})")
    return borrados
