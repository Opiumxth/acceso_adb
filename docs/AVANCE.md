# Avance del proyecto

Sistema de Control de Acceso, Asistencia y Seguridad Universitaria.
Rama de trabajo: `feature/base-de-datos`. Un commit local por etapa (sin push).

Todos los scripts SQL son ASCII puro y empiezan con `set sqlblanklines on`.
La salida real de cada prueba está en `docs/evidencia/`.

Para ejecutar un script (ejemplo con el esquema dueño):

```
docker cp sql/01_esquema.sql oracle-xe:/tmp/01_esquema.sql
docker exec -i oracle-xe sqlplus -s 'acceso_owner/"Owner#2026"@XEPDB1' @/tmp/01_esquema.sql
```

---

## Etapa 1 - Base de datos (completada)

### Qué se hizo

| Archivo | Se ejecuta como | Contenido |
|---|---|---|
| `sql/00_admin.sql` | SYSTEM | 3 tablespaces con autoextend (datafiles en el mismo directorio que los de XEPDB1, leído de `v$datafile`), usuario dueño `acceso_owner`, 4 roles y 4 usuarios de aplicación. Se puede repetir sin error. |
| `sql/01_esquema.sql` | acceso_owner | 18 tablas con constraints con nombre (`pk_`, `fk_`, `uq_`, `ck_`) y 8 índices secundarios en `ts_acceso_idx`. `accesos`, `asistencias` y `auditoria` van en `ts_acceso_log`. |
| `sql/02_datos.sql` | acceso_owner | Datos ficticios con fechas relativas a `sysdate`: 17 personas, 6 zonas, 7 puntos, 19 permisos, 4 secciones, 19 inscripciones, 24 sesiones cerradas + la sesión 900 en curso, 114 asistencias simuladas, 494 accesos, 8 denegados, 2 pases, 1 restricción y 5 incidencias. |
| `sql/99_reset.sql` | acceso_owner | Borra todas las tablas del esquema (bloque PL/SQL). |

### Resultado de la verificación

- 18 tablas (`user_tables`).
- 17 personas: 3 docentes, 1 vigilante, 1 administrativo, 10 estudiantes, 2 visitantes.
- Asistencias simuladas: 86 presente, 20 tardanza, 8 falta.
- Inscripciones: el estudiante 25200004 queda `inhabilitado` (3 faltas de 6) y 25200005 queda en riesgo en la sección 1 (1 falta).
- Los 8 denegados de ejemplo cubren los 6 motivos pedidos (3 son `codigo_inexistente`).

### Decisiones y diferencias respecto a la especificación

1. **`maxsize` del autoextend**: 500m para datos y log, 200m para índices, para que un descuido no llene el disco del contenedor.
2. **Parámetro extra `ZONA_HORARIA = America/Lima`** en `parametros`. El contenedor Oracle corre en UTC (5 horas por delante de Lima), así que las ventanas `HH24:MI` de `permisos_zona` se evaluarán en esa zona. El resto de las marcas de tiempo se guardan en hora del servidor, como indica la especificación (`sysdate`, `systimestamp`).
3. **Constraints adicionales** (más estrictos, sin cambiar los datos pedidos): `not null` en columnas de estado con default; formato `HH24:MI` y `hora_desde <= hora_hasta` en `permisos_zona`; `fecha_fin >= fecha_inicio` en `restricciones`.
4. **Simulación de asistencias**: reparto aleatorio con semilla fija (78 % / 12 % / 10 % esperado) más ajustes dirigidos para que las pruebas y los reportes no dependan del azar: los estudiantes 10 y 11 (usados en `test_03`) no tienen faltas, el 13 queda inhabilitado y el 14 en riesgo. Por eso el reparto final es 75 % / 17 % / 7 %.
5. Cada asistencia simulada presente o tardanza tiene su acceso al aula (`id_acceso`), y cada sesión tiene el ingreso del docente.

### Errores encontrados y corregidos

- `ORA-01873` en `02_datos.sql`: `interval '120' day` necesita precisión de 3 dígitos. Se cambió a `interval '120' day(3)`.
- `PLS-00231` en `02_datos.sql`: una función local de PL/SQL no puede usarse dentro de un `INSERT`. Se calcula la hora en una variable antes de insertar.

### Evidencia

- `docs/evidencia/etapa1_00_admin.txt`
- `docs/evidencia/etapa1_01_esquema.txt`
- `docs/evidencia/etapa1_02_datos.txt`
- `docs/evidencia/etapa1_verificacion.txt`

Las cuatro salidas corresponden a una corrida desde cero (se eliminaron antes los usuarios, roles y tablespaces del proyecto).

---

## Etapa 2 - Procedimientos PL/SQL (completada)

### Qué se hizo

`sql/03_procedimientos.sql` (propietario `acceso_owner`) crea 17 objetos, todos `VALID` y sin errores de compilación:

| Grupo | Objetos |
|---|---|
| Parámetros | `f_parametro`, `f_parametro_num` (funciones auxiliares), `p_obtener_parametro` (para clientes sin acceso a la tabla, por ejemplo el punto de acceso) |
| Acceso | `p_verificar_persona`, `p_registrar_acceso` |
| Asistencia | `p_cerrar_sesion` |
| Seguridad | `p_emitir_pase`, `p_revocar_pase`, `p_registrar_restriccion`, `p_levantar_restriccion`, `p_registrar_incidencia`, `p_resolver_incidencia` |
| Personas | `p_registrar_persona`, `p_modificar_persona`, `p_eliminar_persona`, `p_listar_personas`, `p_buscar_personas` (los dos últimos devuelven `sys_refcursor`) |

Códigos de error (`raise_application_error`): `-20001` entrada inválida, `-20002` registro inexistente, `-20003` estado que no permite la operación, `-20004` parámetro del sistema faltante, `-20005` duplicado, `-20099` error inesperado. Todo procedimiento que modifica datos hace `commit` al final y `rollback` ante cualquier error.

### Cómo decide `p_registrar_acceso` (una sola transacción)

1. Valida las entradas y que el punto exista y esté activo (si no, error, no denegación).
2. Aplica las reglas en el orden pedido: `codigo_inexistente`, `persona_inactiva`, `rostro_no_coincide`, `persona_restringida` (con incidencia alta), y la autorización por zona (`sin_pase_vigente`, `zona_no_autorizada`, `fuera_de_horario`).
3. Inserta siempre la fila en `accesos`, permitida o denegada.
4. Si fue permitido en un aula o laboratorio: el estudiante con inscripción activa y una sesión en la ventana `[inicio - 10 min, inicio + MIN_MAX_TARDANZA]` recibe `presente` o `tardanza` (según `MIN_TARDANZA`); la asistencia existente no se duplica ni se degrada; una sesión `programada` pasa a `en_curso`. El docente solo hace pasar la sesión a `en_curso`.
5. Si fue denegado: cuenta los denegados de la misma zona y de la misma persona o código en los últimos `MIN_VENTANA_INTENTOS` minutos y, al llegar a `INTENTOS_PARA_INCIDENCIA`, crea una incidencia `intentos_reiterados` (media) salvo que ya exista una abierta equivalente.
6. Devuelve `o_resultado`, `o_motivo` y `o_id_acceso`. Los umbrales salen de la tabla `parametros`.

### Decisiones tomadas

1. `accesos.motivo` queda en `NULL` cuando el acceso es permitido (el motivo describe solo la denegación).
2. La apertura de 10 minutos antes del inicio es una constante dentro del procedimiento (no estaba en la lista de parámetros). Las sesiones `cerradas` no reciben asistencias.
3. La ventana `HH24:MI` de `permisos_zona` se evalúa en la zona horaria del parámetro `ZONA_HORARIA`; el resto de las marcas de tiempo usa la hora del servidor.
4. `p_cerrar_sesion` suma la falta con la misma condición que el `INSERT ... SELECT` (inscripción activa sin asistencia), y evalúa la inhabilitación sobre todas las inscripciones activas de la sección. Con 6 sesiones cerradas nadie puede cruzar el 30 % por una sola falta más, por eso `test_03` cierra además una sesión extra (901) para demostrar la inhabilitación.
5. `p_eliminar_persona` hace baja lógica si la persona tiene cualquier historial (accesos, inscripciones, asistencias, restricciones, pases, incidencias o secciones), no solo accesos, porque las claves foráneas impedirían borrarla. Devuelve `baja_logica` o `eliminada`.
6. Solo puede haber una restricción vigente por persona (`-20005`).
7. Cada denegación `persona_restringida` genera su propia incidencia alta, como indica la regla d.
8. Las personas se identifican por su `codigo` (el contenido del QR) en `p_modificar_persona` y `p_eliminar_persona`.

### Errores encontrados durante las pruebas y corregidos

- `ORA-00907` en `p_registrar_acceso`: dentro de un `SELECT`, `at time zone <variable>` no es válido (con una función o una asignación directa sí). Se cambió a una asignación PL/SQL directa. La primera corrida de `test_03` falló por esto en todos los casos de acceso.
- Validación de cadenas vacías: `length(trim(x)) = 0` nunca se cumple en Oracle (la cadena vacía es `NULL`). Se cambió a `trim(x) is null` en todos los procedimientos. La prueba 8.3 (código en blanco) lo detectó.

### Resultado de `sql/test_03.sql` (datos recién cargados)

| Caso | Resultado obtenido |
|---|---|
| `00000000` en la puerta | denegado, `codigo_inexistente`, `id_persona` nulo |
| `25200009` | denegado, `persona_inactiva` |
| `25200003` con `rostro_ok = 0` | denegado, `rostro_no_coincide` |
| `25200010` | denegado, `persona_restringida` + incidencia `alta` |
| `25200001` en Administración | denegado, `zona_no_autorizada` |
| ventana horaria que excluye la hora actual | denegado, `fuera_de_horario` |
| `99000001`: puerta / aula A-101 / biblioteca | permitido / `sin_pase_vigente` / permitido |
| `99000002` en la puerta | denegado, `sin_pase_vigente` (pase vencido) |
| docente `10000001` con la sesión 900 `programada` | permitido; la sesión pasa a `en_curso` |
| `25200001`, sesión 900 con 5 min | permitido; asistencia `presente`; al repetir sigue 1 sola fila |
| `25200002`, sesión 900 con 20 min | permitido; asistencia `tardanza` |
| `25200001` otra vez, con 20 min | permitido; sigue `presente` (no se degrada) |
| `25200007` (no inscrito en S1) | permitido, sin asistencia |
| `12345678` tres veces seguidas | la tercera crea `intentos_reiterados` (media); la cuarta no la duplica |
| `p_cerrar_sesion(900)` | 3 faltas, 0 inhabilitados |
| `p_cerrar_sesion(901)` (sesión extra) | 5 faltas, 1 inhabilitado (25200005, 3 de 8 = 37.5 %) |
| punto inexistente, `rostro_ok` inválido, código en blanco, método inválido, restricción inexistente | `ORA-20002`, `ORA-20001`, `ORA-20001`, `ORA-20001`, `ORA-20002`; el conteo de `accesos` no cambia (519 antes y después) |

También se probaron el CRUD de personas (alta con subtipo, duplicado `ORA-20005`, modificación, búsqueda, listado de 18 filas, baja lógica y eliminación física), restricciones (registrar, denegar con incidencia alta, levantar y volver a permitir), pases (emitir, entrar, revocar y volver a denegar) e incidencias del vigilante (registrar, `en_revision`, `resuelta`).

`test_03.sql` abre las ventanas horarias de estudiantes y docentes al inicio y las restaura al final, para que el resultado no dependa de la hora de ejecución. Modifica datos: para repetirlo hay que recargar con `99_reset.sql`, `01` y `02`.

### Evidencia

- `docs/evidencia/test_03.txt`
