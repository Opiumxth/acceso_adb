import os

import cv2
import numpy as np
import qrcode

import config


def generar_qr(codigo, directorio=None):
    """Genera la imagen QR del codigo y devuelve su ruta."""
    directorio = config.QR_DIR if directorio is None else directorio
    os.makedirs(directorio, exist_ok=True)

    qr = qrcode.QRCode(
        version=1,
        error_correction=qrcode.constants.ERROR_CORRECT_L,
        box_size=10,
        border=4,
    )
    qr.add_data(codigo)
    qr.make(fit=True)

    img = qr.make_image(fill_color="black", back_color="white")
    ruta = os.path.join(directorio, f"qr_{codigo}.png")
    img.save(ruta)
    print(f"QR code generado y guardado como qr_{codigo}.png en {directorio}")
    return ruta


def cargar_imagenes(folder, image_size=config.TAM_ROSTRO):
    images = []
    labels = []

    for filename in sorted(os.listdir(folder)):
        img_path = os.path.join(folder, filename)
        img = cv2.imread(img_path, cv2.IMREAD_GRAYSCALE)
        if img is not None:
            img = cv2.resize(img, image_size)
            images.append(img)
            # Para LBPH, se usa siempre la misma etiqueta (0) ya que es un modelo por persona
            labels.append(0)

    return images, labels


def entrenar_modelo(codigo):
    """Entrena el modelo LBPH de la persona con sus fotos de datos/faces/<codigo>.

    Devuelve True si el modelo quedo guardado en datos/models/.
    """
    train_folder = config.ruta_rostros(codigo)
    if not train_folder.is_dir():
        print(f"Error: no existe la carpeta de rostros {train_folder}")
        return False

    images, labels = cargar_imagenes(train_folder)
    if not images:
        print(f"Error: No se encontraron imagenes para entrenar en {train_folder}")
        return False

    images = np.array(images)
    labels = np.array(labels)

    # Crear el reconocedor LBPH
    model = cv2.face.LBPHFaceRecognizer_create(
        radius=1,          # radio del patron circular LBP (por defecto 1)
        neighbors=8,       # numero de vecinos a considerar (por defecto 8)
        grid_x=8,          # numero de celdas en horizontal (por defecto 8)
        grid_y=8,          # numero de celdas en vertical (por defecto 8)
        threshold=100.0    # umbral para la prediccion (por defecto +inf)
    )
    model.train(images, labels)

    os.makedirs(config.MODELOS_DIR, exist_ok=True)
    model.save(str(config.ruta_modelo(codigo)))

    print(f"Modelo LBPH para {codigo} entrenado y guardado correctamente.")
    return True
