"""Operaciones del panel de administracion por consola.

Todas reciben una conexion abierta con el rol admin (u_admin) y trabajan con
procedimientos de Oracle; ya no hay archivo alumnos.csv.
"""
import biometria
import repositorio


def mostrar_personas(conn, filas=None):
    """Lista las personas (todas, o las filas ya filtradas que se pasen)."""
    if filas is None:
        filas = repositorio.listar_personas(conn)
    if not filas:
        print("No hay personas para mostrar.")
        return
    print(f"{'Codigo':<10}{'Nombre':<32}{'Tipo':<16}{'Estado':<12}{'DNI':<10}")
    print("-" * 80)
    for fila in filas:
        print(f"{fila['codigo']:<10}{fila['nombre']:<32}{fila['tipo']:<16}"
              f"{fila['estado']:<12}{fila['dni']:<10}")
    print(f"Total: {len(filas)}")


def buscar_personas(conn, texto=None, tipo=None, estado=None):
    mostrar_personas(conn, repositorio.buscar_personas(conn, texto, tipo, estado))


def borrar_persona(conn, codigo):
    """Elimina a la persona (o la da de baja si tiene historial).

    Los archivos biometricos solo se borran si la persona se elimino de verdad;
    con baja logica se conservan por si se reactiva.
    """
    accion = repositorio.eliminar_persona(conn, codigo)
    if accion == "eliminada":
        print(f"Persona {codigo} eliminada de la base de datos.")
        borrados = biometria.borrar_archivos(codigo)
        for item in borrados:
            print(f"Se elimino {item}")
        if not borrados:
            print("No habia archivos biometricos que borrar.")
    else:
        print(f"La persona {codigo} tiene historial: se dio de baja (estado inactivo). "
              "Sus archivos biometricos se conservan.")
    return accion


def editar_persona(conn, codigo, nombre=None, dni=None, correo=None, estado=None):
    """Modifica los datos indicados; los None no se tocan."""
    repositorio.modificar_persona(conn, codigo, nombre=nombre, dni=dni,
                                  correo=correo, estado=estado)
    print(f"Persona {codigo} actualizada.")
