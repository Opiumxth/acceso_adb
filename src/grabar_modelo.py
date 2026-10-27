import cv2
import os

def grabar_modelo (output_folder, codigo):
    cap = cv2.VideoCapture(0)
    face_cascade = cv2.CascadeClassifier(cv2.data.haarcascades + 'haarcascade_frontalface_default.xml')
    face_count = 0
    while True:
        ret, frame = cap.read()
        if not ret:
            break

        if not os.path.exists(output_folder):
            os.makedirs(output_folder)

        cv2.imshow('Video', frame)
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)

        # Manten presionado la tecla 'p' para empezar a capturar rostros
        if cv2.waitKey(1) == ord("p"):
            faces = face_cascade.detectMultiScale(gray, scaleFactor=1.1, minNeighbors=5, minSize=(30, 30))

            for (x, y, w, h) in faces:
                # Extrae el rostro del frame
                face = frame[y:y+h, x:x+w]

                # Nombre del archivo de salida
                face_filename = os.path.join(output_folder, f"{codigo}_{face_count:04d}.jpg")

                # Guarda el rostro
                cv2.imwrite(face_filename, face)
                face_count += 1
        if cv2.waitKey(1) == ord('q'):
            break

    cap.release()
    cv2.destroyAllWindows()
    print(f"Se han extraído {face_count} rostros y guardado en la carpeta {output_folder}.")