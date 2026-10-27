import cv2
import numpy as np

def verificar_rostro(codigo):
    #Aqui se carga el modelo entrenado
    model = cv2.face.LBPHFaceRecognizer_create()

    try:
        model.read(f"face_recognition_app/models/modelo_lbph_{codigo}.yml")
    except:
        print("No se encontro modelo para ese codigo")
        return None

    #Inicia a capturar video desde la camara
    cap = cv2.VideoCapture(0)

    #Usa el Haar Cascade para detectar rostros
    face_cascade = cv2.CascadeClassifier(cv2.data.haarcascades + 'haarcascade_frontalface_default.xml')

    while True:
        #Lee los fotogramas de la camara
        ret, frame = cap.read()
        if not ret:
            break

        #Convertir en escala de grises el fotograma
        gray = cv2. cvtColor(frame, cv2.COLOR_BGR2GRAY)

        #Detecta los rostros ya con cada frame en escala de grises
        faces = face_cascade.detectMultiScale(gray, scaleFactor = 1.1, minNeighbors = 5, minSize = (100, 100))

        for (x, y, w, h) in faces:
            #Extraer la region de interes (osea el rostro)
            roi_gray = gray[y:y+h, x:x+w]
            roi_gray = cv2.resize(roi_gray, (200, 200)) #Mismo tamaño que durante el entrenamiento

            #Predecir usando el modelo LBPH
            label, confidence = model.predict(roi_gray)

            #Dibujar un rectangulo alrededor del rostro detectado
            cv2.rectangle(frame, (x, y), (x+w, y+h), (255, 0, 0), 2)

            #Umbral de confianza
            #En LPBH, los valores mientras mas bajo mas parecido es, o mas confianza se tiene
            if confidence < 40:
                cv2.putText(frame, f'Rostro verificado Conf: {confidence:.2f}', (x, y-10),
                            cv2.FONT_HERSHEY_SIMPLEX, 0.9, (0, 255, 0), 2)
                cap.release()
                cv2.destroyAllWindows()
                return True

            else:
                cv2.putText(frame, 'No reconocido', (x, y-10),
                            cv2.FONT_HERSHEY_SIMPLEX, 0.9, (0, 0, 255), 2)

        cv2.imshow('Reconocimiento Facial', frame)

        if cv2.waitKey(1) & 0xFF == ord('q'):
            break

    cap.release()
    cv2.destroyAllWindows()
    return False