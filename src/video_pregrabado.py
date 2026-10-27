import cv2
import os

def extraer_caras(video_path, output_folder, codigo):
    # Verifica si el video existe
    if not os.path.exists(video_path):
        print(f"Error: El archivo de video {video_path} no existe.")
        return

    # Crea la carpeta de salida si no existe
    if not os.path.exists(output_folder):
        os.makedirs(output_folder)

    # Cargar el clasificador de Haar para la detección de rostros
    face_cascade = cv2.CascadeClassifier(cv2.data.haarcascades + 'haarcascade_frontalface_default.xml')

    # Abre el video
    cap = cv2.VideoCapture(video_path)

    if not cap.isOpened():
        print("Error: No se pudo abrir el video.")
        return

    frame_count = 0
    face_count = 0

    while True:
        ret, frame = cap.read()

        if not ret:
            break

        # Convierte el frame a escala de grises
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)

        # Detecta los rostros
        faces = face_cascade.detectMultiScale(gray, scaleFactor=1.1, minNeighbors=5, minSize=(30, 30))

        for (x, y, w, h) in faces:
            # Extrae el rostro del frame
            face = frame[y:y+h, x:x+w]

            # Nombre del archivo de salida
            face_filename = os.path.join(output_folder, f"{codigo}_{face_count:04d}.jpg")

            # Guarda el rostro
            cv2.imwrite(face_filename, face)
            face_count += 1

        frame_count += 1

    cap.release()
    print(f"Se han extraído {face_count} rostros y guardado en la carpeta {output_folder}.")