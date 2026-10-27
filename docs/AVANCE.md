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

---

## Etapa 3 - Reportes con REF CURSOR (completada)

### Qué se hizo

`sql/04_reportes.sql` crea 9 procedimientos `r_*` (todos `VALID`, sin errores de compilación). Cada uno devuelve un `SYS_REFCURSOR` en el último parámetro (`o_cursor`); el cliente lo abre, recorre y cierra.

| Procedimiento | Parámetros | Contenido |
|---|---|---|
| `r_asistencia_seccion` | sección | Por estudiante: presentes, tardanzas, faltas, sesiones cerradas, % de asistencia y estado de la inscripción |
| `r_asistencia_sesion` (extra) | sesión | Un registro por inscrito de una sesión (`sin_registro` si no hay fila). Lo usará el panel web |
| `r_alumnos_en_riesgo` | sección (nulo = todas) | Inhabilitados y estudiantes a una falta de serlo (`(faltas + 1) * 100 / sesiones cerradas >= LIMITE_FALTAS_PCT`) |
| `r_ranking_tardanzas` | desde, hasta | Ranking con `RANK()` de tardanzas, asistencias y % de tardanza |
| `r_accesos_denegados` | desde, hasta | Denegados agrupados por motivo y zona con `GROUP BY ROLLUP` (subtotal por motivo y total general) |
| `r_incidencias` | estado, gravedad | Filtros opcionales; las más graves primero |
| `r_pases_vigentes` | ninguno | Pases activos dentro de su vigencia ahora, con horas restantes |
| `r_uso_aulas_vs_sesiones` | fecha | Por aula y laboratorio: sesiones y alumnos esperados frente a accesos, personas distintas, asistentes y ocupación sobre el aforo, con una observación (`normal`, `sesion sin accesos`, `uso sin sesion programada`, `sin actividad`) |
| `r_flujo_por_hora` | fecha, zona (nulo = todas) | Las 24 horas del día con permitidos, denegados, entradas, salidas y personas distintas |

Reglas comunes: las fechas desde/hasta son inclusivas y un valor nulo significa "sin límite"; las entradas inválidas dan `ORA-20001` y los registros inexistentes `ORA-20002`.

### Decisiones tomadas

1. Los reportes de asistencia cuentan solo sesiones **cerradas**, así el porcentaje no se distorsiona con una sesión en curso.
2. "En riesgo" se definió como "una falta más lo inhabilita". Con pocas sesiones cerradas una sola falta basta para entrar en ese nivel: con 1 falta en 6 sesiones, `(1 + 1) * 100 / 6 = 33.3 %` supera el 30 %, por eso aparecen varios estudiantes. El cálculo usa el total actual de sesiones cerradas (criterio conservador).
3. `r_asistencia_sesion` se agregó aunque no estaba en la lista, porque la pantalla de asistencia por sesión de la Etapa 7 la necesita.
4. Las horas de `r_flujo_por_hora` están en hora del servidor (UTC en este contenedor), igual que las marcas guardadas en `accesos`.

### Resultado de `sql/test_04.sql`

Se ejecutó sobre el estado que dejó `test_03` (sesiones 900 y 901 cerradas, accesos y denegaciones de hoy). Cada reporte se imprimió con `VARIABLE` y `PRINT`:

- `r_asistencia_seccion(1)`: 6 estudiantes con 8 sesiones cerradas; 25200004 y 25200005 inhabilitados (3 faltas = 37.5 %).
- `r_asistencia_sesion(900)`: 25200001 `presente`, 25200002 `tardanza`, tres `falta` y 25200004 `sin_registro` (estaba inhabilitado).
- `r_alumnos_en_riesgo(NULL)`: 8 filas, 2 `inhabilitado` y 6 `en_riesgo`.
- `r_ranking_tardanzas`: 10 estudiantes, empate en el puesto 1 con 3 tardanzas (25200003, 25200004, 25200006).
- `r_accesos_denegados(NULL, NULL)`: 23 denegados en 7 motivos, con subtotales y total general.
- `r_incidencias(NULL, NULL)` y `('abierta', 'alta')`: 9 incidencias en total; 3 abiertas de gravedad alta.
- `r_pases_vigentes`: solo el pase del visitante 99000001 (el 1002 fue revocado y el de 99000002 está vencido).
- `r_uso_aulas_vs_sesiones`: hoy, A-101 con 2 sesiones, 7 accesos y 2 asistentes; hace 7 días, 3 aulas con actividad `normal`.
- `r_flujo_por_hora`: 24 filas por consulta (ayer en la puerta: entradas de 07:00 a 09:00 y salidas de 12:00 a 19:00).
- Errores esperados: sección inexistente, estado no válido, rango de fechas al revés y zona inexistente (`ORA-20002`, `ORA-20001`, `ORA-20001`, `ORA-20002`).

### Evidencia

- `docs/evidencia/reportes.txt`

---

## Etapa 4 - Triggers de auditoría y permisos por rol (completada)

### Qué se hizo

| Archivo | Contenido |
|---|---|
| `sql/05_triggers.sql` | `trg_aud_personas` y `trg_aud_restricciones`: cada `INSERT`, `UPDATE` o `DELETE` deja una fila en `auditoria` (tabla, operación, usuario, fecha, detalle). En los `UPDATE` el detalle lista solo los campos que cambiaron (`campo: [antes] -> [después]`) y no se registra nada si no cambió ningún campo auditado. |
| `sql/06_permisos.sql` | Revoca todo lo otorgado antes a los cuatro roles y vuelve a otorgar solo `EXECUTE` sobre procedimientos. Imprime la matriz de permisos y comprueba que los roles tienen 0 privilegios sobre tablas y ninguno distinto de `EXECUTE`. |
| `sql/test_05_06.sql` | Abre una sesión por cada usuario de aplicación (`u_punto`, `u_docente`, `u_vigilante`, `u_admin`) y por último `acceso_owner` para leer la bitácora. |

### Matriz de permisos (EXECUTE)

| Objeto | punto_control | vigilante | docente | admin |
|---|:-:|:-:|:-:|:-:|
| `p_verificar_persona`, `p_registrar_acceso`, `p_obtener_parametro` | X | X | | X |
| `p_buscar_personas` | | X | | X |
| `p_emitir_pase`, `p_revocar_pase` | | X | | X |
| `p_registrar_restriccion`, `p_levantar_restriccion` | | X | | X |
| `p_registrar_incidencia`, `p_resolver_incidencia` | | X | | X |
| `r_accesos_denegados`, `r_incidencias`, `r_pases_vigentes`, `r_flujo_por_hora` | | X | | X |
| `r_asistencia_seccion`, `r_asistencia_sesion`, `r_alumnos_en_riesgo`, `r_ranking_tardanzas` | | | X | X |
| `p_registrar_persona`, `p_modificar_persona`, `p_eliminar_persona`, `p_listar_personas`, `p_cerrar_sesion`, `r_uso_aulas_vs_sesiones`, `f_parametro`, `f_parametro_num` | | | | X |

### Decisiones tomadas

1. **`p_obtener_parametro` para el punto de control**: el punto de acceso debe leer `UMBRAL_LBPH` de la tabla `parametros` sin tener acceso a la tabla, así que se le dio ese procedimiento además de los dos pedidos.
2. **`p_buscar_personas` para el vigilante**: necesita encontrar al visitante y al anfitrión para emitir un pase. Es solo lectura.
3. **Cerrar sesiones queda solo para el administrador.** La especificación da al docente únicamente reportes. Para que el docente cierre sus sesiones habría que validar que la sesión sea de una sección suya dentro del procedimiento (queda como pendiente).
4. El trigger registra `SESSION_USER`, es decir, la persona que inició sesión (`U_ADMIN`, `U_VIGILANTE`...) aunque el cambio lo haga un procedimiento del esquema dueño. La fila de auditoría va en la misma transacción que el cambio: si el procedimiento hace `rollback`, la auditoría también se deshace.
5. Los triggers se eliminan junto con sus tablas, así que después de `99_reset.sql` + `01` + `02` hay que volver a ejecutar `05_triggers.sql`. Orden completo de carga: `00, 01, 02, 03, 04, 05, 06`.
6. `test_03` y `test_04` se ejecutaron antes de crear los triggers, por eso la bitácora solo contiene lo que hizo `test_05_06`.

### Resultado de `sql/test_05_06.sql`

| Usuario | Prueba | Resultado |
|---|---|---|
| `u_punto` | `select` e `insert` directos sobre `accesos`; `select` sobre `personas` y `parametros` | `ORA-00942` (4 casos) |
| `u_punto` | `p_verificar_persona('90000001')`, `p_registrar_acceso`, `p_obtener_parametro('UMBRAL_LBPH')` | funcionan: Ricardo Salas Medina existe, acceso `permitido`, umbral `40` |
| `u_punto` | `p_cerrar_sesion`, `p_registrar_persona`, `r_incidencias` | `PLS-00201` (no tiene permiso) |
| `u_docente` | `r_asistencia_seccion(1)`, `r_alumnos_en_riesgo(2)` | funcionan |
| `u_docente` | `p_registrar_acceso`, `r_accesos_denegados`; `select` sobre `inscripciones` | `PLS-00201`, `PLS-00201`, `ORA-00942` |
| `u_vigilante` | `p_registrar_acceso`, emitir y revocar un pase, registrar y resolver una incidencia, registrar y levantar una restricción, `r_accesos_denegados` | funcionan |
| `u_vigilante` | `p_registrar_persona`, `r_asistencia_seccion`; `select` sobre `pases` | `PLS-00201`, `PLS-00201`, `ORA-00942` |
| `u_admin` | alta, modificación, restricción y baja lógica de la persona 88000001; alta y eliminación física de la 88000002; `p_buscar_personas`, `r_pases_vigentes` | funcionan (`baja_logica` y `eliminada`) |
| `u_admin` | `select` directo sobre `auditoria` | `ORA-00942`: ni el administrador toca las tablas |

Bitácora generada por los triggers (9 filas): `U_ADMIN` hizo 2 `INSERT`, 2 `UPDATE` y 1 `DELETE` sobre `PERSONAS` y 1 `INSERT` y 1 `UPDATE` sobre `RESTRICCIONES`; `U_VIGILANTE` hizo 1 `INSERT` y 1 `UPDATE` sobre `RESTRICCIONES`. En total aparecen 7 errores `ORA-00942` y 7 `PLS-00201`, todos esperados.

### Evidencia

- `docs/evidencia/permisos.txt`

---

## Etapa 5 - Resumen para el profesor (completada)

### Qué se hizo

`docs/RESUMEN.md`: descripción del sistema en una frase, diagrama ER, procedimientos y reglas, reportes, roles, permisos y tablespaces, evidencia de las pruebas, cómo reproducir y pendientes.

### Cómo se verificó

- El diagrama `erDiagram` incluye las 18 tablas y 24 relaciones. Las relaciones se sacaron de las claves foráneas reales de la base (`user_constraints`), no de memoria: 24 claves foráneas, 18 primarias, 7 únicas, 29 checks con nombre y 8 índices secundarios.
- La sintaxis mermaid se validó con el parser oficial (`mermaid` 11.4.1 con `jsdom`, instalado en un directorio temporal fuera del repositorio): el bloque se reconoce como diagrama `er`. Un control negativo con un diagrama roto a propósito sí falla, así que la validación no es vacía.
- Las cifras de tablespaces (50/500, 50/500 y 30/200 MB) y de objetos (15 procedimientos `p_*`, 9 reportes `r_*`, 2 funciones, 2 triggers) salen de consultas al diccionario de datos.

### Estado

El resumen describe lo hecho hasta la Etapa 4 y lista los límites conocidos. Se actualizará al terminar las Etapas 6 y 7 (Python y panel web).

---

## Etapa 6 - Python del punto de acceso (completada, falta probar con la webcam real)

### Qué se hizo

| Archivo | Función |
|---|---|
| `src/config.py`, `.env.example` | Configuración central: DSN `localhost:1521/XEPDB1`, usuario y clave por rol (las claves salen de `.env`, que no se versiona), rutas de `datos/`, cámara y tiempos de espera |
| `src/db.py` | `get_connection(rol)`: conecta con el usuario Oracle del rol y ejecuta `alter session set current_schema = ACCESO_OWNER`. Convierte los `ORA-200xx` en `ErrorAplicacion` |
| `src/repositorio.py` | Única capa que habla con Oracle, solo con procedimientos: `verificar_persona`, `registrar_acceso`, `obtener_umbral_lbph`, `registrar/modificar/eliminar/listar/buscar_personas`, `consultar_cursor` para REF CURSOR |
| `src/punto_acceso.py` | Flujo del punto: QR, `p_verificar_persona`, rostro, `p_registrar_acceso`, resultado en pantalla. Conecta con `u_punto`. Modo kiosco, `--una-vez`, `--punto N` y `--simular` |
| `src/camara.py` | Apertura de cámara y localización del clasificador Haar |
| `src/escanear_qr.py`, `src/acceder_rostro.py` | Lectura de QR y verificación LBPH, ahora con tiempo máximo, confianza devuelta y cámara inyectable para pruebas |
| `src/biometria.py`, `src/registro.py` | Rostros, modelo y QR en `datos/`; alta de personas con `p_registrar_persona` (rol admin) |
| `src/admin.py`, `src/main.py` | Menú de consola y panel de administración sobre Oracle (ya no hay `alumnos.csv`) |
| `src/generar_qr.py`, `grabar_modelo.py`, `video_pregrabado.py` | Se conservan, con rutas centralizadas y sin código de CSV |
| `tests/test_etapa6.py` | 49 pruebas automáticas |
| `requirements.txt` | Dependencias del proyecto |
| `sql/04_reportes.sql` | Se agregó `r_escuelas` (catálogo para elegir la escuela al registrar un estudiante, porque el rol admin no lee tablas) |

Se retiraron `acceder.py` y `verificar_codigo_en_csv.py`: los reemplazan `punto_acceso.py` y Oracle.

### Cómo ejecutarlo

```
python3 -m venv venv && ./venv/bin/pip install -r requirements.txt
cp .env.example .env        # completar las claves (están en sql/00_admin.sql)

./venv/bin/python src/main.py                     # menú de consola
./venv/bin/python src/punto_acceso.py             # punto de acceso (modo kiosco)
./venv/bin/python src/punto_acceso.py --simular 25200001 --rostro-ok 1 --confianza 24.5   # sin cámara
./venv/bin/python -m unittest discover -s tests -v
```

### Decisiones tomadas

1. **La decisión la toma la base.** El programa solo lee el QR, mide el rostro e informa lo que devuelve `p_registrar_acceso`. Si el código no existe o la persona no está activa, no se enciende la cámara para el rostro: la base lo deniega antes (reglas a y b).
2. **El umbral LBPH sale de la tabla `parametros`** (`UMBRAL_LBPH`, 40) mediante `p_obtener_parametro`, no está escrito en el código. Se lee una vez al iniciar el punto.
3. **Tiempos de espera**: el QR espera 30 s y el rostro 20 s (cambiables en `.env`). Antes el bucle de rostro no tenía límite. ESC cancela la lectura del QR.
4. **Rutas centralizadas** en `config.py`, siempre dentro de `datos/`: `datos/faces/<codigo>/`, `datos/models/modelo_lbph_<codigo>.yml` y `datos/qrcodes/qr_<codigo>.png`. Antes había tres convenciones distintas (`face_recognition_app/...`, `../faces`, `qrcodes`). Si ya tienes modelos del proyecto anterior, hay que copiarlos a `datos/models/`.
5. **Alta de personas**: primero `p_registrar_persona` (así un código o DNI repetido falla antes de usar la cámara) y después se capturan rostros, se entrena el modelo y se genera el QR. Si esa segunda parte falla, se deshace el alta con `p_eliminar_persona` y se borran los archivos. Un alta duplicada nunca borra a la persona original.
6. **Clave del administrador**: se eliminó la clave escrita en `main.py`. El menú usa `DB_PASSWORD_ADMIN` de `.env` o, si está vacía, la pide por consola (tres intentos) y la valida contra Oracle.
7. **Las 17 personas de prueba no tienen modelo facial en disco**: para usar la cámara con ellas está la opción 2.3 del menú (registrar solo el rostro de una persona que ya existe en la base).

### Problemas encontrados y corregidos

- **Confianza gigante**: cuando el rostro es muy distinto, OpenCV devuelve `-1` y una confianza de `1.797e308` (con el `threshold=100` del entrenamiento). Ese valor no cabe en `accesos.confianza` (`number(6,2)`) y `p_registrar_acceso` lo rechaza. Se acota a `9999.99`. Una prueba con un modelo sintético lo reprodujo.
- **Clasificador Haar**: el OpenCV instalado por el sistema no trae `cv2.data`, y la rama 5.x de `opencv-contrib-python` ya no incluye los archivos XML. El `requirements.txt` fija `opencv-contrib-python>=4.6,<5` y `camara.py` busca el clasificador también en carpetas del sistema, con un mensaje claro si no lo encuentra.
- `grabar_modelo.py` llamaba a `cv2.waitKey` dos veces por vuelta y podía perder pulsaciones de `p` o `q`; ahora lo hace una vez.

### Pruebas

`tests/test_etapa6.py`: 49 pruebas, todas OK, sobre Oracle real (usuarios `u_punto` y `u_admin`) y con una cámara falsa:

- Conexión: sesión de `U_PUNTO` con esquema `ACCESO_OWNER`; `u_punto` no puede leer tablas (`ORA-00942`) ni usar procedimientos de otro rol (`PLS-00201`); falta de clave y clave incorrecta.
- Flujo del punto con rostro simulado: código inexistente y persona inactiva (sin pedir el rostro), rostro que no coincide, persona restringida, zona no autorizada, punto inexistente, QR no encontrado y lectura cancelada.
- Rostro con un modelo LBPH sintético: coincidencia (confianza 0), no coincidencia (confianza acotada a 9999.99), sin rostro, sin modelo, modelo dañado y cámara sin imagen.
- QR: lectura de un código generado, vencimiento del tiempo y cámara sin imagen.
- Alta de personas: ciclo completo con subtipo, duplicado (`ORA-20005`), compensación cuando falla la biometría o la captura lanza una excepción, y borrado de archivos acotado a la carpeta de datos.

Además se ejecutaron el modo `--simular` (8 casos), el menú de consola (panel de administración con la clave de `.env`, búsqueda, y clave incorrecta tres veces) y el error de cámara con un índice inexistente (código de salida 3, el menú sigue funcionando). Cada ejecución de las pruebas agrega filas de prueba a `accesos` con método `simulado`.

### Lo que NO se probó

La **cámara real**. No encendí la webcam porque capturaría tu imagen; la lectura de QR y la verificación de rostro se probaron con fotogramas generados. Pendiente para ti: `./venv/bin/python src/main.py`, opción 2.3 para registrar tu rostro con un código existente (por ejemplo 25200001) y opción 1 para probar el acceso con el QR en `datos/qrcodes/`.

### Evidencia

- `docs/evidencia/etapa6_python.txt`

---

## Etapa 7 - Panel web Flask (implementada y probada; documentación final pendiente)

### Qué se hizo

- **Panel Flask** (`src/app.py`, `src/panel.py`, `src/templates/`, `src/static/`): dashboard, personas (CRUD), bitácora de accesos con filtros, asistencia (secciones, sesiones, programar, cancelar y cerrar sesión), incidencias, pases, restricciones y reportes que ejecutan los `r_*` (con descarga CSV). Se inicia con `./venv/bin/python src/app.py`.
- **Un usuario Oracle por rol**: el login usa `PANEL_PASSWORD_<ROL>` de `.env` y todas las consultas se hacen con `u_admin`, `u_vigilante` o `u_docente`. Ningún rol lee tablas. Hay protección CSRF, cookie `HttpOnly` y `SameSite=Lax`, bloqueo tras 5 intentos fallidos, destino de login solo interno y escape de datos del usuario.
- **Template (autorizado por el usuario, opción "todo local")**: SB Admin 7.0.7 (MIT), Bootstrap 5.2.3 y Font Awesome Free 6.7.2 en `src/static/vendor/`, con sus licencias y un README de procedencia. Los paquetes npm se verificaron por integridad SHA-512.
- **Hora local**: el servidor Oracle está en UTC, 5 horas por delante de Lima. Las marcas se siguen guardando en hora del servidor, pero los reportes y el panel interpretan fechas y muestran horas en hora local (`ZONA_HORARIA`) con `f_desfase` y `f_hoy_local` (en `01_esquema.sql`). `02_datos.sql` genera las horas de clase e ingresos en hora local y siembra los accesos de hoy ya ocurridos.
- **SQL nuevo**: `p_obtener_desfase`, `p_crear_sesion`, `p_cancelar_sesion`, `r_resumen_hoy`, `r_accesos_bitacora`, `r_zonas`, `r_secciones`, `r_sesiones`, `r_restricciones`; permisos en `06_permisos.sql` (vigilante: resumen, bitácora, zonas y restricciones; docente: secciones y sesiones; admin: todo).

### Pruebas

- `tests/test_panel.py`: 64 pruebas, todas OK (login y seguridad, matriz de permisos por rol, flujos de personas, accesos, asistencia, incidencias, pases, restricciones y reportes, hora local contra el reloj de Lima). Suite completa con la Etapa 6: 113 pruebas OK. Las pruebas limpian lo que crean y cierran las incidencias que disparan.
- Reconstrucción desde cero de `00` a `06`: 0 errores `ORA-` y 0 errores de compilación. Evidencia regenerada.
- Evidencia: `docs/evidencia/etapa7_panel.txt` y capturas en `docs/evidencia/panel/`.

### Pendiente (no se alcanzó a hacer)

1. **Actualizar cifras de las etapas 1 a 4 en este archivo y en `RESUMEN.md`**: tras agregar los accesos de hoy, la carga trae 505 accesos (no 494); `test_05_06` ahora da 7 `ORA-00942` y 9 `PLS-00201`; `reportes.txt` incluye los reportes nuevos y las horas en hora local. Las evidencias (`docs/evidencia/*.txt`) ya están regeneradas y son las que valen.
2. **Actualizar `RESUMEN.md`** (reportes y catálogos nuevos, panel web, hora local) y escribir un `README.md` de arranque rápido.
3. Probar el panel en tu navegador y la webcam real (solo se probó con Firefox headless y cámara simulada).
