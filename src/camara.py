"""Apertura de la camara, compartida por la lectura de QR, la verificacion
del rostro y la captura de rostros."""
from pathlib import Path

import cv2

import config


class CamaraError(RuntimeError):
    """No se pudo abrir o leer la camara."""


def abrir(indice=None):
    """Abre la camara (por defecto la de config.CAMERA_INDEX)."""
    indice = config.CAMERA_INDEX if indice is None else indice
    captura = cv2.VideoCapture(indice)
    if not captura.isOpened():
        captura.release()
        raise CamaraError(
            f"No se pudo abrir la camara {indice}. Revise la conexion o CAMERA_INDEX en .env."
        )
    return captura


# Carpetas de sistema donde suele estar el clasificador cuando OpenCV no viene de pip
_CARPETAS_HAAR = (
    "/usr/share/opencv4/haarcascades",
    "/usr/share/opencv/haarcascades",
    "/usr/local/share/opencv4/haarcascades",
)


def ruta_haarcascade(nombre="haarcascade_frontalface_default.xml"):
    """Ubica el clasificador Haar de deteccion de rostros.

    Primero busca en cv2.data (paquetes de pip) y luego en carpetas del sistema.
    """
    carpetas = []
    datos = getattr(cv2, "data", None)
    if datos is not None:
        carpetas.append(Path(datos.haarcascades))
    carpetas.extend(Path(carpeta) for carpeta in _CARPETAS_HAAR)
    for carpeta in carpetas:
        ruta = carpeta / nombre
        if ruta.is_file():
            return str(ruta)
    raise CamaraError(
        f"No se encontro {nombre}. Instale las dependencias con "
        "'pip install -r requirements.txt' (opencv-contrib-python 4.x; "
        "la rama 5.x no incluye los clasificadores Haar)."
    )


def detector_de_rostros():
    """Devuelve el detector de rostros Haar listo para usar."""
    detector = cv2.CascadeClassifier(ruta_haarcascade())
    vacio = getattr(detector, "empty", None)
    if callable(vacio) and vacio():
        raise CamaraError("No se pudo cargar el clasificador de rostros de OpenCV.")
    return detector
