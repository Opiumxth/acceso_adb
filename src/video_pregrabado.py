import os

import cv2

import camara


def extraer_caras(video_path, output_folder, codigo):
    """Extrae rostros de un video y los guarda en output_folder.

    Devuelve la cantidad de rostros guardados (0 si el video no existe o no
    se pudo abrir).
    """
    # Verifica si el video existe
    if not os.path.exists(video_path):
        print(f"Error: El archivo de video {video_path} no existe.")
        return 0

    # Cargar el clasificador de Haar para la deteccion de rostros
    face_cascade = camara.detector_de_rostros()

    # Abre el video
    cap = cv2.VideoCapture(str(video_path))
    if not cap.isOpened():
        print("Error: No se pudo abrir el video.")
        return 0

    # Crea la carpeta de salida si no existe
    os.makedirs(output_folder, exist_ok=True)

    face_count = 0
    try:
        while True:
            ret, frame = cap.read()
            if not ret:
                break

            # Convierte el frame a escala de grises y detecta los rostros
            gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
            faces = face_cascade.detectMultiScale(gray, scaleFactor=1.1, minNeighbors=5, minSize=(30, 30))

            for (x, y, w, h) in faces:
                face = frame[y:y + h, x:x + w]
                face_filename = os.path.join(output_folder, f"{codigo}_{face_count:04d}.jpg")
                cv2.imwrite(face_filename, face)
                face_count += 1
    finally:
        cap.release()

    print(f"Se han extraido {face_count} rostros y guardado en la carpeta {output_folder}.")
    return face_count
