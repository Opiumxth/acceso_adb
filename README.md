# Sistema de Control de Acceso, Asistencia y Seguridad Universitaria

Proyecto del curso de Administración de Base de Datos (Ingeniería de Sistemas, UNMSM).

Una persona pasa por un punto de control (puerta, aula o laboratorio) con **QR + reconocimiento facial**. En una sola transacción de Oracle se decide si se autoriza el ingreso, si cuenta como asistencia a una sesión de clase y si debe generarse una incidencia. Lo que se evalúa es la lógica en PL/SQL, los reportes con `REF CURSOR`, los roles y permisos, y la administración (tablespaces).

## Qué hay en el repositorio

| Carpeta | Contenido |
|---|---|
| `sql/` | Scripts de Oracle: `00_admin` a `06_permisos`, `99_reset` y las pruebas `test_*.sql` |
| `src/` | Python: menú de consola (`main.py`), punto de acceso (`punto_acceso.py`) y panel web (`app.py`) |
| `tests/` | 113 pruebas automáticas (Oracle real y cámara simulada) |
| `docs/` | `RESUMEN.md` (para presentar), `AVANCE.md` (decisiones y resultados por etapa) y `evidencia/` (salida real de cada prueba) |
| `latex_document/` | Informe del proyecto anterior (Programación I), solo como referencia |

Los rostros, modelos faciales y QR van en `datos/`, y las claves en `.env`; ninguno de los dos se sube al repositorio.

## Puesta en marcha

**1. Base de datos** (Docker, contenedor `oracle-xe`, servicio `XEPDB1`):

```
docker start oracle-xe
docker cp sql/00_admin.sql oracle-xe:/tmp/00_admin.sql
docker exec -i oracle-xe sqlplus -s 'system/"<clave de SYSTEM>"@XEPDB1' @/tmp/00_admin.sql
```

Los scripts `01` a `06` se ejecutan igual, como `acceso_owner`, en este orden: `01_esquema`, `02_datos`, `03_procedimientos`, `04_reportes`, `05_triggers`, `06_permisos`. El comando exacto y las claves están en la cabecera de cada script. Para empezar de cero: `99_reset.sql`, luego `01` y `02`, y volver a ejecutar `05` (los triggers se borran junto con sus tablas).

**2. Python:**

```
python3 -m venv venv && ./venv/bin/pip install -r requirements.txt
cp .env.example .env        # completar las claves de cada rol y del panel
```

**3. Usar el sistema:**

```
./venv/bin/python src/main.py                    # menú de consola: acceder, registrar personas, administración
./venv/bin/python src/punto_acceso.py            # punto de acceso en modo kiosco (cámara)
./venv/bin/python src/punto_acceso.py --simular 25200001 --rostro-ok 1 --confianza 24.5   # sin cámara
./venv/bin/python src/app.py                     # panel web: http://127.0.0.1:5000
```

Las 17 personas de prueba no tienen rostro registrado: para usar la cámara con una de ellas, menú de consola, opción 2.3.

## Usuarios y roles de Oracle

| Usuario | Rol | Qué puede hacer |
|---|---|---|
| `u_punto` | `rol_punto_control` | Verificar una persona y registrar un acceso |
| `u_vigilante` | `rol_vigilante` | Lo anterior, pases, restricciones, incidencias y reportes de seguridad |
| `u_docente` | `rol_docente` | Reportes de asistencia |
| `u_admin` | `rol_admin` | Todo |

Ningún rol tiene privilegios sobre tablas: solo ejecutan procedimientos. El panel web y el punto de acceso se conectan con estos mismos usuarios.

## Pruebas

```
./venv/bin/python -m unittest discover -s tests      # Python y panel (con el contenedor encendido)
```

Las pruebas SQL (`sql/test_03.sql`, `test_04.sql` y `test_05_06.sql`) se ejecutan sobre datos recién cargados; cada una explica cómo en su cabecera.

## Notas

- Las marcas de tiempo se guardan en hora del servidor (UTC en el contenedor). Los reportes y el panel usan la hora local indicada en el parámetro `ZONA_HORARIA` (`America/Lima`).
- `src/static/vendor/` contiene archivos de terceros (SB Admin, Bootstrap y Font Awesome) con sus licencias; ver el `README.md` de esa carpeta.
- La cámara real no se probó en el desarrollo; ver `docs/AVANCE.md` para lo que falta y los límites conocidos.
