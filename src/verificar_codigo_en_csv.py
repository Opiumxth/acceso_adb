import csv

def verificar_codigo_csv(codigo, ruta_csv = "face_recognition_app/alumnos.csv"):
        with open(ruta_csv, mode = 'r', newline = '', encoding = 'utf-8') as archivo:
                lector = csv.DictReader(archivo)
                for fila in lector:
                        if fila['codigo'] == codigo:
                                return fila
        return None