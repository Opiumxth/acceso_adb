import qrcode
import os
import csv
import cv2
import numpy as np

def guardar_datos(csv_file, codigo, nombre, carrera):

    file_exists = os.path.isfile(csv_file)
    file_is_empty = not file_exists or os.path.getsize(csv_file) == 0

    with open(csv_file, mode='a', newline='', encoding='utf-8') as file:
        campos = ["codigo", "nombre", "carrera"]
        escritor = csv.DictWriter(file, fieldnames=campos)

        if file_is_empty:
            escritor.writeheader()

        escritor.writerow({
            "codigo": codigo,
            "nombre": nombre,
            "carrera": carrera,
        })
        print("Datos del estudiante guardados.")

def generar_qr(qr_file, codigo):
    # Crear el directorio si no existe
    os.makedirs(qr_file, exist_ok=True)
    
    qr = qrcode.QRCode(
        version=1,
        error_correction=qrcode.constants.ERROR_CORRECT_L,
        box_size=10,
        border=4,
    )

    qr.add_data(codigo)
    qr.make(fit=True)

    img = qr.make_image(fill_color="black", back_color="white")
    img.save(f"{qr_file}/qr_{codigo}.png")
    print(f"QR code generado y guardado como qr_{codigo}.png en {qr_file}")


def cargar_imagenes(folder, image_size=(200, 200)):
    images = []
    labels = []

    for filename in os.listdir(folder):
        img_path = os.path.join(folder, filename)
        img = cv2.imread(img_path, cv2.IMREAD_GRAYSCALE)
        if img is not None:
            img = cv2.resize(img, image_size)
            images.append(img)
            # Para LBPH, podemos usar siempre la misma etiqueta (0) ya que es un modelo por persona
            labels.append(0)  # Todos las imágenes son de la misma persona
    
    return images, labels
         
def entrenar_modelo(codigo):
    train_folder = f"face_recognition_app/faces/{codigo}"

    images, labels = cargar_imagenes(train_folder)

    if not images:
        print(f"Error: No se encontraron imágenes para entrenar en {train_folder}")
        return

    images = np.array(images)
    labels = np.array(labels)

    # Crear el reconocedor LBPH
    model = cv2.face.LBPHFaceRecognizer_create(
        radius=1,          # radio del patrón circular LBP (por defecto 1)
        neighbors=8,       # número de vecinos a considerar (por defecto 8)
        grid_x=8,          # número de celdas en horizontal (por defecto 8)
        grid_y=8,          # número de celdas en vertical (por defecto 8)
        threshold=100.0    # umbral para la predicción (por defecto +inf)
    )
    model.train(images, labels)

    if not os.path.exists("face_recognition_app/models"):
        os.makedirs("face_recognition_app/models")
        
    model.save(f"face_recognition_app/models/modelo_lbph_{codigo}.yml")

    print(f"Modelo LBPH para el alumno {codigo} entrenado y guardado correctamente.")


def agregar_alumno(codigo,nombre,carrera):
    qr_file = "qrcodes"
    csv_file = "face_recognition_app/alumnos.csv"

    guardar_datos(csv_file, codigo, nombre, carrera)
    generar_qr(qr_file, codigo)   
    entrenar_modelo(codigo) 
    
def verificar_codigo(codigo):
    csv_file = "face_recognition_app/alumnos.csv"
    if not os.path.exists(csv_file):
        return False

    with open(csv_file, mode='r', encoding='utf-8') as file:
        reader = csv.DictReader(file)
        for row in reader:
            if row['codigo'] == codigo:
                return True
    return False