import math
import time
from pathlib import Path
from typing import NamedTuple, Optional

import cv2

import camara
import config

# Tope de la columna accesos.confianza (number(6,2)). OpenCV devuelve un valor
# enorme (DBL_MAX) cuando ninguna distancia pasa el umbral interno del modelo.
CONFIANZA_MAXIMA = 9999.99


class ResultadoRostro(NamedTuple):
    ok: bool                      # True si el rostro coincide con el modelo
    confianza: Optional[float]    # mejor (menor) distancia LBPH observada; None si no hubo rostro
    detalle: str                  # coincide, no_coincide, sin_rostro, sin_modelo, camara, cancelado


def _acotar(confianza):
    """Deja la confianza en un rango que cabe en la base de datos."""
    confianza = float(confianza)
    if not math.isfinite(confianza) or confianza > CONFIANZA_MAXIMA:
        return CONFIANZA_MAXIMA
    return confianza


def verificar_rostro(codigo, umbral, timeout=None, indice_camara=None,
                     mostrar_ventana=True, captura=None, ruta_modelo=None):
    """Compara el rostro frente a la camara con el modelo LBPH del codigo.

    umbral: confianza LBPH maxima aceptada (parametro UMBRAL_LBPH de la base).
        En LBPH un valor MENOR es un rostro MAS parecido.
    timeout: segundos de espera (por defecto config.ROSTRO_TIMEOUT).
    captura / ruta_modelo: solo para pruebas; por defecto se usa la camara
        real y el modelo de datos/models/.

    Devuelve ResultadoRostro(ok, confianza, detalle).
    """
    ruta = Path(ruta_modelo) if ruta_modelo else config.ruta_modelo(codigo)
    if not ruta.is_file():
        return ResultadoRostro(False, None, "sin_modelo")

    modelo = cv2.face.LBPHFaceRecognizer_create()
    try:
        modelo.read(str(ruta))
    except cv2.error:
        # archivo danado o que no es un modelo LBPH
        return ResultadoRostro(False, None, "sin_modelo")
    detector = camara.detector_de_rostros()

    timeout = config.ROSTRO_TIMEOUT if timeout is None else timeout
    propia = captura is None
    if propia:
        try:
            captura = camara.abrir(indice_camara)
        except camara.CamaraError:
            return ResultadoRostro(False, None, "camara")

    mejor = None
    detalle = "sin_rostro"
    inicio = time.monotonic()
    try:
        while time.monotonic() - inicio < timeout:
            ret, frame = captura.read()
            if not ret:
                detalle = "camara"
                break

            gris = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
            rostros = detector.detectMultiScale(
                gris, scaleFactor=1.1, minNeighbors=5, minSize=config.MIN_ROSTRO)

            for (x, y, w, h) in rostros:
                # mismo tamano que durante el entrenamiento
                roi = cv2.resize(gris[y:y + h, x:x + w], config.TAM_ROSTRO)
                _, distancia = modelo.predict(roi)
                distancia = _acotar(distancia)
                if mejor is None or distancia < mejor:
                    mejor = distancia

                coincide = distancia < umbral
                if mostrar_ventana:
                    color = (0, 255, 0) if coincide else (0, 0, 255)
                    texto = (f"Rostro verificado Conf: {distancia:.2f}" if coincide
                             else "No reconocido")
                    cv2.rectangle(frame, (x, y), (x + w, y + h), color, 2)
                    cv2.putText(frame, texto, (x, y - 10),
                                cv2.FONT_HERSHEY_SIMPLEX, 0.9, color, 2)
                if coincide:
                    return ResultadoRostro(True, distancia, "coincide")
                detalle = "no_coincide"

            if mostrar_ventana:
                cv2.imshow("Reconocimiento Facial", frame)
                if cv2.waitKey(1) & 0xFF == ord("q"):
                    detalle = "cancelado"
                    break

        return ResultadoRostro(False, mejor, detalle)
    finally:
        if propia:
            captura.release()
        if mostrar_ventana:
            cv2.destroyAllWindows()
