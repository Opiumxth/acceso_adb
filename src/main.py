from acceder import ejecutar_acceso
from grabar_modelo import grabar_modelo
from generar_qr import agregar_alumno, verificar_codigo
from video_pregrabado import extraer_caras
from admin import mostrar_alumnos, borrar_alumno, editar_informacion

def menu_opciones():
    print("\n+~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~+")
    print("\tMENU PRINCIPAL")
    print("\t1. Acceder")
    print("\t2. Registrar Alumno")
    print("\t3. Panel de Administracion")
    print("\t0. Salir")
    print("+~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~+")
    return input("\nSeleccione una opcion: ")

def menu():
    while True:
        opcion = menu_opciones()
        match opcion: #switch
            case "1":
                ejecutar_acceso()

            case "2":
                agregar_alumno_menu()

            case "3":
                panel_administracion()

            case "0":
                print("Saliendo del programa ...")
                break

            case _:
                print("Opcion Invalida!")

def agregar_alumno_menu():
    while True:
        print("\n+~~~ AGREGAR ALUMNO ~~~+")
        print("2.1 Generar qr y capturar rostros con la cámara")
        print("2.2 Generar qr y capturar rostros desde un video pregrabado")
        print("0. Volver al menú principal\n")
        opcion = input("Selecciona una opción: ")

        match opcion:
            case "2.1":
                codigo = input("Ingrese el código del estudiante: ")
                if not codigo.isdigit() or len(codigo) != 8:
                    print("El código debe ser un número de 8 dígitos.")
                    break
                if verificar_codigo(codigo):
                    print("El código ya está registrado. Intente con otro código.")
                    break
                nombre = input("Ingrese el nombre del estudiante: ")
                carrera = input("Ingrese la carrera del estudiante: ")
                print("Mantenga 'p' para empezar a capturar rostros y 'q' para salir de la ventana de video")
                grabar_modelo(f"face_recognition_app/faces/{codigo}", codigo)
                agregar_alumno(codigo, nombre, carrera)

            case "2.2":
                codigo = input("Ingrese el código del estudiante: ")
                if not codigo.isdigit() or len(codigo) != 8:
                    print("El código debe ser un número de 8 dígitos.")
                    break
                if verificar_codigo(codigo):
                    print("El código ya está registrado. Intente con otro código.")
                    break
                nombre = input("Ingrese el nombre del estudiante: ")
                carrera = input("Ingrese la carrera del estudiante: ")
                video_path = input("Ingrese la ruta del video: ")
                extraer_caras(video_path, f"face_recognition_app/faces/{codigo}", codigo)
                agregar_alumno(codigo, nombre, carrera)

            case "0":
                print("Redireccionando ...")
                return

            case _:
                print("Opción invalida. Intenta de nuevo.")
                
def autenticar_admin():
    intentos = 3
    while intentos > 0:
        usuario = input("Usuario admin: ")
        contraseña = input("Contraseña: ")
        if usuario == "admin" and contraseña == "oingablinko":  # En producción usar hash
            return True
        intentos -= 1
        print(f"Credenciales incorrectas. {intentos} intentos restantes.")
    return False


def panel_administracion():
    if not autenticar_admin():
        print("Acceso denegado.")
        return
    while True:
        print("\n+~~~ PANEL DE ADMINISTRACIÓN ~~~+")
        print("3.1 Ver información de alumnos")
        print("3.2 Borrar alumno")
        print("3.3 Editar información")
        print("0. Volver al menú principal\n")

        opcion = input("Selecciona una opción: ")

        match opcion:
            case "3.1":
                mostrar_alumnos()

            case "3.2":
                codigo = input("Ingrese el código del alumno a eliminar: ")
                borrar_alumno(codigo)

            case "3.3":
                codigo = input("Ingrese el código del alumno a editar: ")
                nuevo_nombre = input("Nuevo nombre (dejar vacío si no desea cambiar): ")
                nueva_carrera = input("Nueva carrera (dejar vacío si no desea cambiar): ")
                editar_informacion(codigo, nuevo_nombre or None, nueva_carrera or None)

            case "0":
                print("Redireccionando ...")
                return

            case _:
                print("Opción no válida. Intenta de nuevo.")

if __name__ == "__main__":
    menu()