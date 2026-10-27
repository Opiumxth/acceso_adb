import time

import cv2
import zxingcpp

import camara
import config


class LecturaCancelada(Exception):
    """El operador pulso ESC en la ventana de la camara."""


def leer_qr_camara(timeout=None, indice_camara=None, mostrar_ventana=True, captura=None):
    """Lee un codigo QR con la camara y devuelve su texto.

    Devuelve None si vence el tiempo (timeout, en segundos; por defecto
    config.QR_TIMEOUT). Lanza LecturaCancelada si se pulsa ESC y
    camara.CamaraError si la camara no se puede abrir.

    captura: objeto con read() y release(); solo se usa para pruebas sin
    camara. Si es None se abre la camara real.
    """
    timeout = config.QR_TIMEOUT if timeout is None else timeout
    propia = captura is None
    if propia:
        captura = camara.abrir(indice_camara)

    inicio = time.monotonic()
    try:
        while time.monotonic() - inicio < timeout:
            ret, frame = captura.read()
            if not ret:
                break

            resultados = zxingcpp.read_barcodes(frame)
            if resultados:
                texto = resultados[0].text.strip()
                if texto:
                    return texto

            if mostrar_ventana:
                cv2.imshow("Escanea tu codigo QR", frame)
                if cv2.waitKey(1) == 27:  # ESC para salir
                    raise LecturaCancelada()
        return None
    finally:
        if propia:
            captura.release()
        if mostrar_ventana:
            cv2.destroyAllWindows()
