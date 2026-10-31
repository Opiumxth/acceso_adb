# Sistema de Control de Acceso, Asistencia y Seguridad Universitaria

Proyecto del curso de Administración de Base de Datos (Ingeniería de Sistemas, UNMSM).

Una persona pasa por un punto de control (puerta, aula o laboratorio) con QR y reconocimiento facial. Oracle decide en **una sola transacción** si se autoriza el ingreso, si cuenta como asistencia a una sesión de clase y si debe generarse una incidencia.
La lógica vive en PL/SQL (18 procedimientos `p_*`, 16 reportes `r_*` con `REF CURSOR`, 2 triggers de auditoría), con 4 roles que solo ejecutan procedimientos y 3 tablespaces. Python (punto de acceso y menú) y un panel web Flask solo llaman a esos procedimientos.

## Requisitos
- Python 3.12
- Docker con Oracle XE 21c (imagen `gvenzl/oracle-xe:21-slim`), contenedor `oracle-xe`, puerto 1521, servicio `XEPDB1`

## Instalación

**1. Contenedor** (si no existe, crearlo; la clave de SYSTEM de las instrucciones es `admin123`):
```
docker run -d --name oracle-xe -p 1521:1521 -e ORACLE_PASSWORD=admin123 gvenzl/oracle-xe:21-slim
docker start oracle-xe            # si ya existía
docker logs -f oracle-xe          # esperar "DATABASE IS READY TO USE!" y salir con Ctrl+C
```

**2. Base de datos** (desde la raíz del repositorio). El script 00 se ejecuta como SYSTEM y los 01 a 06 como `acceso_owner`:
```
docker cp sql/00_admin.sql oracle-xe:/tmp/00_admin.sql
docker exec -i oracle-xe sqlplus -s 'system/"admin123"@XEPDB1' @/tmp/00_admin.sql

for n in 01_esquema 02_datos 03_procedimientos 04_reportes 05_triggers 06_permisos; do
  docker cp sql/$n.sql oracle-xe:/tmp/$n.sql
  docker exec -i oracle-xe sqlplus -s 'acceso_owner/"Owner#2026"@XEPDB1' @/tmp/$n.sql < /dev/null
done
```
Para empezar de nuevo: `sql/99_reset.sql` (como `acceso_owner`) y luego 01 a 06 otra vez.

**3. Python:**
```
python3 -m venv venv
./venv/bin/pip install -r requirements.txt
cp .env.example .env
```
`.env.example` trae las claves de demostración (usuarios `u_punto`, `u_vigilante`, `u_docente`, `u_admin` con las claves que crea `sql/00_admin.sql`, y las claves del panel). `.env` no se sube al repositorio.

## Uso
```
./venv/bin/python src/punto_acceso.py --simular 25200001 --rostro-ok 1 --confianza 24.5   # un acceso sin cámara
./venv/bin/python src/punto_acceso.py                                                     # punto de acceso con cámara
./venv/bin/python src/main.py                                                             # menú de consola (acceder, registrar, administrar)
./venv/bin/python src/app.py                                                              # panel web: http://127.0.0.1:5000
```
Roles del panel (clave en `.env`): Administrador (`PanelAdmin#2026`), Vigilante (`PanelVigil#2026`) y Docente (`PanelDocente#2026`). Cada uno se conecta a Oracle con su propio usuario.

## Cómo evaluarlo
Con el contenedor encendido y la base cargada (pasos 1 y 2):

1. **Pruebas SQL.** Cada una explica en su cabecera si necesita datos recién cargados.
   ```
   for t in test_03 test_04 test_05_06; do docker cp sql/$t.sql oracle-xe:/tmp/$t.sql; docker exec -i oracle-xe sqlplus -s 'acceso_owner/"Owner#2026"@XEPDB1' @/tmp/$t.sql < /dev/null > /tmp/$t.txt; done
   grep -c '^ORA-' /tmp/test_03.txt                                  # 0: ningún error inesperado
   grep -c '^ORA-00942:' /tmp/test_05_06.txt; grep -c '^PLS-00201:' /tmp/test_05_06.txt   # 7 y 9 (esperados, ver abajo)
   ```
   Resultado esperado: `test_03` muestra cada motivo de denegación, asistencia sin duplicar, `intentos_reiterados` y `p_cerrar_sesion`; `test_04` imprime los reportes; `test_05_06` demuestra los permisos. La salida de referencia está en `docs/evidencia/`.
2. **113 pruebas de Python** (Oracle real, cámara simulada):
   `./venv/bin/python -m unittest discover -s tests` termina con `Ran 113 tests ... OK`.
3. **Acceso permitido:** `./venv/bin/python src/punto_acceso.py --simular 90000001 --rostro-ok 1 --confianza 21.5` imprime `ACCESO PERMITIDO` (el vigilante en la puerta).
4. **Acceso denegado:** `./venv/bin/python src/punto_acceso.py --simular 25200001 --rostro-ok 0 --confianza 68.5` imprime `ACCESO DENEGADO` con el motivo `rostro_no_coincide`. Con `--simular 00000000` el motivo es `codigo_inexistente`.
5. **Acceso con asistencia.** Poner la sesión 900 en curso "ahora", pasar al estudiante por el aula A-101 (punto 4) y ver la asistencia:
   ```
   docker exec -i oracle-xe sqlplus -s 'acceso_owner/"Owner#2026"@XEPDB1' <<'SQL'
   update sesiones set hora_inicio = systimestamp - interval '5' minute, hora_fin = systimestamp + interval '85' minute, estado = 'en_curso' where id_sesion = 900;
   commit;
   SQL
   ./venv/bin/python src/punto_acceso.py --simular 25200001 --rostro-ok 1 --confianza 24.5 --punto 4
   ```
   Resultado esperado: `ACCESO PERMITIDO`. En el panel (rol Administrador): Asistencia, sección SIS301, sesión 900, donde Ana Torres Quispe figura `presente`. (El estudiante solo puede entrar al aula entre 07:00 y 22:00, hora de Lima.)
6. **Panel con cada rol.** Iniciar `src/app.py` e ingresar con cada rol: el Administrador ve todo el menú; el Vigilante ve bitácora, incidencias, pases, restricciones y personas (solo búsqueda); el Docente ve solo Dashboard, Asistencia y Reportes. Entrar con un rol a una pantalla que no le corresponde (por ejemplo `/personas/nueva` como Vigilante) devuelve `403`.
7. **Reporte CSV.** Como Administrador o Vigilante: Reportes, Accesos denegados, Ejecutar, Descargar CSV. El archivo empieza con `motivo,zona,total,...` y termina con la fila `TOTAL GENERAL`.
8. **Permisos de Oracle.** `u_punto` no puede leer tablas pero sí registrar accesos (sección 1 de `test_05_06.sql`).

### Qué significan los errores esperados de `test_05_06`
- `ORA-00942: table or view does not exist`: el rol **no tiene privilegios sobre las tablas** (para ese usuario la tabla no existe). Debe aparecer: ningún rol lee ni escribe tablas.
- `PLS-00201: identifier ... must be declared`: el rol **no tiene `EXECUTE` sobre ese procedimiento**. Debe aparecer cuando se llama a un procedimiento que no le corresponde.

Si estos errores no aparecieran, los permisos estarían mal.

## Estructura
| Carpeta | Contenido |
|---|---|
| `sql/` | Scripts de Oracle `00` a `06`, `99_reset` y las pruebas `test_*.sql` |
| `src/` | Python: `punto_acceso.py`, `main.py` (menú), `app.py` (panel) y sus módulos |
| `tests/` | Pruebas automáticas de Python |
| `docs/` | `RESUMEN.md` (resumen con diagrama ER), `AVANCE.md` (decisiones por etapa) y `evidencia/` (salida real de las pruebas y capturas del panel) |

## Notas
- Las marcas de tiempo se guardan en hora del servidor (UTC en el contenedor). Los reportes y el panel usan la hora local del parámetro `ZONA_HORARIA` (`America/Lima`).
- Los rostros, modelos y QR van en `datos/`, que no se versiona. Las personas de prueba no tienen rostro registrado: para usar la cámara con una, menú de consola, opción 2.3.
- `src/static/vendor/` contiene SB Admin, Bootstrap y Font Awesome con sus licencias (ver el README de esa carpeta).
- La webcam real y el panel en un navegador de escritorio no se probaron durante el desarrollo; ver `docs/AVANCE.md`.
