"""Alta de personas: los datos van a Oracle (p_registrar_persona, rol admin)
y el rostro, el modelo y el QR se guardan en datos/ (ver biometria.py).

Orden del alta:
    1. p_registrar_persona  -> valida y falla ya si el codigo o el DNI existen,
                               antes de gastar tiempo con la camara
    2. captura de rostros, entrenamiento del modelo y QR
    3. si el paso 2 falla, se deshace el paso 1 (p_eliminar_persona: la persona
       aun no tiene historial, asi que se borra de verdad) y se limpia el disco
"""
import biometria
import repositorio

TIPOS = ("estudiante", "docente", "visitante", "vigilante", "administrativo")


class RegistroError(RuntimeError):
    """No se pudo completar el alta de la persona."""


def registrar_persona_con_rostro(conn, datos, via="camara", video=None, enrolar=None):
    """Da de alta a la persona y registra su biometria.

    datos: diccionario con los argumentos de repositorio.registrar_persona
        (codigo, nombre, dni, tipo y, segun el tipo, correo, id_escuela,
        ciclo, especialidad).
    enrolar: funcion (codigo, via, video) -> bool; por defecto biometria.enrolar.
        Se puede reemplazar en las pruebas.
    Devuelve el id_persona.
    """
    enrolar = enrolar or biometria.enrolar
    codigo = datos["codigo"]
    biometria.validar_codigo(codigo)

    id_persona = repositorio.registrar_persona(conn, **datos)
    print(f"Persona registrada en la base de datos (id {id_persona}).")
    try:
        if not enrolar(codigo, via, video):
            raise RegistroError("No se pudo registrar el rostro de la persona.")
    except BaseException:
        _deshacer(conn, codigo)
        raise
    return id_persona


def enrolar_persona_existente(conn, codigo, via="camara", video=None, enrolar=None):
    """Registra solo el rostro, el modelo y el QR de una persona que ya esta en la base."""
    enrolar = enrolar or biometria.enrolar
    biometria.validar_codigo(codigo)
    persona = repositorio.verificar_persona(conn, codigo)
    if persona is None:
        raise RegistroError(f"El codigo {codigo} no esta registrado en la base de datos.")
    print(f"Registrando el rostro de {persona.nombre} ({persona.tipo}).")
    return enrolar(codigo, via, video)


def _deshacer(conn, codigo):
    """Compensacion: quita a la persona recien creada y sus archivos."""
    try:
        accion = repositorio.eliminar_persona(conn, codigo)
        print(f"Se deshizo el alta de {codigo} ({accion}).")
    except Exception as exc:  # no tapar el error original con uno de limpieza
        print(f"Aviso: no se pudo deshacer el alta de {codigo} en la base: {exc}")
    for item in biometria.borrar_archivos(codigo):
        print(f"Se elimino {item}")


# ---------------------------------------------------------------------
# Entrada por consola
# ---------------------------------------------------------------------
def _pedir(texto, obligatorio=True):
    while True:
        valor = input(texto).strip()
        if valor or not obligatorio:
            return valor or None
        print("Este dato es obligatorio.")


def pedir_datos_persona(conn):
    """Pregunta los datos de una persona nueva. Devuelve el diccionario para el alta."""
    print("Tipos: " + ", ".join(f"{i}. {t}" for i, t in enumerate(TIPOS, start=1)))
    while True:
        eleccion = input("Tipo de persona (numero): ").strip()
        if eleccion.isdigit() and 1 <= int(eleccion) <= len(TIPOS):
            tipo = TIPOS[int(eleccion) - 1]
            break
        print("Opcion no valida.")

    while True:
        codigo = input("Codigo (8 digitos, es el contenido del QR): ").strip()
        try:
            biometria.validar_codigo(codigo)
            break
        except ValueError as exc:
            print(exc)

    datos = {
        "codigo": codigo,
        "tipo": tipo,
        "nombre": _pedir("Nombre completo: "),
        "dni": _pedir("DNI (8 digitos): "),
        "correo": _pedir("Correo (opcional): ", obligatorio=False),
    }

    if tipo == "estudiante":
        escuelas = repositorio.listar_escuelas(conn)
        for escuela in escuelas:
            print(f"  {escuela['id_escuela']}. {escuela['nombre']}")
        datos["id_escuela"] = int(_pedir("Escuela (numero): "))
        datos["ciclo"] = int(_pedir("Ciclo (1 a 12): "))
    elif tipo == "docente":
        datos["especialidad"] = _pedir("Especialidad (opcional): ", obligatorio=False)
    return datos
