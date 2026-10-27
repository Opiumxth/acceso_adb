import os

import cv2

import camara


def grabar_modelo(output_folder, codigo, captura=None):
    """Captura rostros con la camara y los guarda en output_folder.

    Mantener presionada la tecla 'p' para capturar y 'q' para terminar.
    Devuelve la cantidad de rostros guardados.
    """
    propia = captura is None
    if propia:
        captura = camara.abrir()
    face_cascade = camara.detector_de_rostros()
    os.makedirs(output_folder, exist_ok=True)
    face_count = 0

    try:
        while True:
            ret, frame = captura.read()
            if not ret:
                break

            cv2.imshow('Video', frame)
            gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)

            # una sola lectura de teclado por vuelta (con dos se perdian pulsaciones)
            tecla = cv2.waitKey(1) & 0xFF
            if tecla == ord('q'):
                break

            # Manten presionada la tecla 'p' para ir capturando rostros
            if tecla == ord('p'):
                faces = face_cascade.detectMultiScale(gray, scaleFactor=1.1, minNeighbors=5, minSize=(30, 30))
                for (x, y, w, h) in faces:
                    # Extrae el rostro del frame
                    face = frame[y:y + h, x:x + w]
                    face_filename = os.path.join(output_folder, f"{codigo}_{face_count:04d}.jpg")
                    cv2.imwrite(face_filename, face)
                    face_count += 1
    finally:
        if propia:
            captura.release()
        cv2.destroyAllWindows()

    print(f"Se han extraido {face_count} rostros y guardado en la carpeta {output_folder}.")
    return face_count
