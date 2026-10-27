import getpass
import os

import oracledb

import admin
import camara
import config
import db
import registro
from punto_acceso import ejecutar_acceso


def menu_opciones():
    print("\n+~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~+")
    print("\tMENU PRINCIPAL")
    print("\t1. Acceder")
    print("\t2. Registrar Persona")
    print("\t3. Panel de Administracion")
    print("\t0. Salir")
    print("+~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~+")
    return input("\nSeleccione una opcion: ")


def _con_manejo_de_errores(accion):
    """Ejecuta una accion del menu mostrando los errores conocidos sin cerrar el programa."""
    try:
        return accion()
    except db.ConfiguracionError as exc:
        print(f"Configuracion incompleta: {exc}")
    except db.ErrorAplicacion as exc:
        print(f"Error: {exc.mensaje}")
    except registro.RegistroError as exc:
        print(f"Error: {exc}")
    except camara.CamaraError as exc:
        print(f"Error de camara: {exc}")
    except ValueError as exc:
        print(f"Dato no valido: {exc}")
    except oracledb.Error as exc:
        print(f"No se pudo usar la base de datos: {exc}")


def conexion_admin():
    """Abre la conexion con u_admin.

    Si DB_PASSWORD_ADMIN esta en .env se usa; si no, se pide la clave por
    consola (tres intentos). Devuelve None si no se pudo autenticar.
    """
    usuario, clave = config.credenciales("admin")
    if clave:
        return db.get_connection("admin")
    for restantes in (2, 1, 0):
        clave = getpass.getpass(f"Clave de {usuario}: ")
        try:
            return db.get_connection("admin", password=clave)
        except oracledb.DatabaseError as exc:
            if "ORA-01017" not in str(exc):
                raise
            print(f"Credenciales incorrectas. {restantes} intentos restantes.")
    return None


def _registrar(conn, via):
    video = None
    if via == "video":
        video = input("Ingrese la ruta del video: ").strip()
        if not os.path.isfile(video):
            print(f"El archivo de video {video} no existe.")
            return
    datos = registro.pedir_datos_persona(conn)
    registro.registrar_persona_con_rostro(conn, datos, via, video)
    print(f"Persona {datos['codigo']} registrada: datos en Oracle; rostro, modelo y QR en datos/.")


def _enrolar_existente(conn):
    codigo = input("Codigo de la persona (ya registrada en la base): ").strip()
    via = input("Capturar con (1) camara o (2) video pregrabado: ").strip()
    video = None
    if via == "2":
        video = input("Ingrese la ruta del video: ").strip()
        if not os.path.isfile(video):
            print(f"El archivo de video {video} no existe.")
            return
    if registro.enrolar_persona_existente(conn, codigo, "video" if via == "2" else "camara", video):
        print(f"Rostro, modelo y QR de {codigo} guardados en datos/.")
    else:
        print("No se pudo completar el registro del rostro.")


def registrar_persona_menu():
    conn = _con_manejo_de_errores(conexion_admin)
    if conn is None:
        print("Acceso denegado.")
        return
    try:
        while True:
            print("\n+~~~ REGISTRAR PERSONA ~~~+")
            print("2.1 Registrar persona y capturar rostros con la camara")
            print("2.2 Registrar persona y capturar rostros desde un video pregrabado")
            print("2.3 Registrar solo el rostro de una persona que ya existe en la base")
            print("0. Volver al menu principal\n")
            opcion = input("Selecciona una opcion: ")

            match opcion:
                case "2.1":
                    _con_manejo_de_errores(lambda: _registrar(conn, "camara"))

                case "2.2":
                    _con_manejo_de_errores(lambda: _registrar(conn, "video"))

                case "2.3":
                    _con_manejo_de_errores(lambda: _enrolar_existente(conn))

                case "0":
                    print("Redireccionando ...")
                    return

                case _:
                    print("Opcion invalida. Intenta de nuevo.")
    finally:
        conn.close()


def panel_administracion():
    conn = _con_manejo_de_errores(conexion_admin)
    if conn is None:
        print("Acceso denegado.")
        return
    try:
        while True:
            print("\n+~~~ PANEL DE ADMINISTRACION ~~~+")
            print("3.1 Ver personas")
            print("3.2 Buscar personas")
            print("3.3 Dar de baja o eliminar una persona")
            print("3.4 Editar informacion")
            print("0. Volver al menu principal\n")

            opcion = input("Selecciona una opcion: ")

            match opcion:
                case "3.1":
                    _con_manejo_de_errores(lambda: admin.mostrar_personas(conn))

                case "3.2":
                    texto = input("Texto a buscar (codigo, nombre o DNI; vacio = todos): ").strip()
                    tipo = input("Tipo (vacio = todos): ").strip()
                    estado = input("Estado (vacio = todos): ").strip()
                    _con_manejo_de_errores(lambda: admin.buscar_personas(
                        conn, texto or None, tipo or None, estado or None))

                case "3.3":
                    codigo = input("Ingrese el codigo de la persona: ").strip()
                    _con_manejo_de_errores(lambda: admin.borrar_persona(conn, codigo))

                case "3.4":
                    codigo = input("Ingrese el codigo de la persona a editar: ").strip()
                    nombre = input("Nuevo nombre (dejar vacio si no desea cambiar): ").strip()
                    dni = input("Nuevo DNI (dejar vacio si no desea cambiar): ").strip()
                    correo = input("Nuevo correo (dejar vacio si no desea cambiar): ").strip()
                    estado = input("Nuevo estado: activo, inactivo o suspendido (vacio = sin cambio): ").strip()
                    _con_manejo_de_errores(lambda: admin.editar_persona(
                        conn, codigo, nombre or None, dni or None, correo or None, estado or None))

                case "0":
                    print("Redireccionando ...")
                    return

                case _:
                    print("Opcion no valida. Intenta de nuevo.")
    finally:
        conn.close()


def menu():
    while True:
        opcion = menu_opciones()
        match opcion:  # switch
            case "1":
                _con_manejo_de_errores(ejecutar_acceso)

            case "2":
                registrar_persona_menu()

            case "3":
                panel_administracion()

            case "0":
                print("Saliendo del programa ...")
                break

            case _:
                print("Opcion Invalida!")


if __name__ == "__main__":
    menu()
