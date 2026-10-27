from escanear_qr import leer_qr_camara
from verificar_codigo_en_csv import verificar_codigo_csv
from acceder_rostro import verificar_rostro

def ejecutar_acceso():
        #Leer el codigo QR
        codigo_qr = leer_qr_camara()
        if not codigo_qr:
                print("No se encontro codigo qr")
                return

        #Verificar el codigo QR
        info_alumno = verificar_codigo_csv(codigo_qr)
        if not info_alumno:
                print("Codigo no encontrado en la base de datos")
                return

        #Abrir la camara y con el nivel de confianza verificar que exista, si es asi se retorna un True de verificar_rostro()
        verificado = verificar_rostro(codigo_qr)
        if verificado:
                print("Acceso concedido. Bienvenido, ", info_alumno["nombre"])
        else:
                print("Acceso denegado. El rostro no pudo ser reconocido")