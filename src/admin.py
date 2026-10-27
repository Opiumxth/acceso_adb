import csv
import os
import shutil

ALUMNOS_FILE = os.path.join(os.path.dirname(__file__), "..", "alumnos.csv")

def mostrar_alumnos():
    with open(ALUMNOS_FILE, mode='r', newline='', encoding='utf-8') as file:
        reader = csv.DictReader(file)
        print("Alumnos registrados:")
        for row in reader:
            print(f"Código: {row['codigo']} | Nombre: {row['nombre']} | Carrera: {row['carrera']}")

def borrar_alumno(codigo):
    encontrado = False
    rows = []
    with open(ALUMNOS_FILE, mode='r', newline='', encoding='utf-8') as file:
        reader = csv.DictReader(file)
        for row in reader:
            if row['codigo'] == codigo:
                encontrado = True
            else:
                rows.append(row)

    if not encontrado:
        print("Alumno no encontrado.")
        return
    
    with open(ALUMNOS_FILE, mode='w', newline='', encoding='utf-8') as file:
        fieldnames = ['codigo', 'nombre', 'carrera']
        writer = csv.DictWriter(file, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)
        CARPETAS_ALUMNOS = os.path.join(os.path.dirname(__file__), "..", "faces")
        carpeta_alumno = os.path.join(CARPETAS_ALUMNOS, codigo)
        if os.path.exists(carpeta_alumno):
            shutil.rmtree(carpeta_alumno)
            print(f"Carpeta del alumno {codigo} eliminada.")
        else:
            print(f"No se encontró carpeta para el alumno {codigo}.")

        project_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # Goes up to 'face_recognition_app'
        qrcodes_dir = os.path.join(os.path.dirname(project_dir), "qrcodes")  # Goes up one more level
        archivo_qr = os.path.join(qrcodes_dir, f"qr_{codigo}.png")

        if os.path.exists(archivo_qr):
            os.remove(archivo_qr)
            print(f"QR borrado: {archivo_qr}")
        else:
            print(f"QR no encontrado en: {archivo_qr}")
        models_dir = os.path.join(project_dir,"models")
        archivo_model=os.path.join(models_dir, f"modelo_lbph_{codigo}.yml")
        if os.path.exists(archivo_model):
            os.remove(archivo_model)
            print(f"Modelo borrado: {archivo_model}")
        else:
            print(f"Modelo no encontrado en: {archivo_model}")
    print(f"Alumno con código {codigo} eliminado.")

def editar_informacion(codigo, nuevo_nombre=None, nueva_carrera=None):
    actualizado = False
    rows = []
    with open(ALUMNOS_FILE, mode='r', newline='', encoding='utf-8') as file:
        reader = csv.DictReader(file)
        for row in reader:
            if row['codigo'] == codigo:
                if nuevo_nombre:
                    row['nombre'] = nuevo_nombre
                if nueva_carrera:
                    row['carrera'] = nueva_carrera
                actualizado = True
            rows.append(row)

    if actualizado:
        with open(ALUMNOS_FILE, mode='w', newline='', encoding='utf-8') as file:
            fieldnames = ['codigo', 'nombre', 'carrera']
            writer = csv.DictWriter(file, fieldnames=fieldnames)
            writer.writeheader()
            writer.writerows(rows)
        print(f"Alumno con código {codigo} actualizado.")
    else:
        print("Código no encontrado.")