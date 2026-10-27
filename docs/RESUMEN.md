# Sistema de Control de Acceso, Asistencia y Seguridad Universitaria

Curso: Administración de Base de Datos, Ingeniería de Sistemas, UNMSM. Estudiante: Mathias.
Base de datos: Oracle XE 21c (Docker, servicio `XEPDB1`), esquema `acceso_owner`.
Aplicación: punto de acceso en Python (QR + reconocimiento facial) y panel web en Flask; ambos solo llaman a procedimientos de Oracle.

## 1. El sistema en una frase

Una persona pasa por un punto de control (puerta, aula o laboratorio) con **QR + reconocimiento facial**, y Oracle decide **en una sola transacción** si se autoriza el ingreso, si cuenta como asistencia a una sesión de clase y si debe generarse una incidencia.

## 2. Modelo de datos (18 tablas, 24 claves foráneas)

```mermaid
erDiagram
    ESCUELAS ||--o{ ESTUDIANTES : "pertenece"
    ESCUELAS ||--o{ CURSOS : "dicta"
    PERSONAS ||--o| ESTUDIANTES : "es"
    PERSONAS ||--o| DOCENTES : "es"
    DOCENTES ||--o{ SECCIONES : "dicta"
    CURSOS ||--o{ SECCIONES : "se divide en"
    ZONAS ||--o{ SECCIONES : "aula de"
    SECCIONES ||--o{ INSCRIPCIONES : "tiene"
    ESTUDIANTES ||--o{ INSCRIPCIONES : "se inscribe"
    SECCIONES ||--o{ SESIONES : "programa"
    SESIONES ||--o{ ASISTENCIAS : "registra"
    ESTUDIANTES ||--o{ ASISTENCIAS : "tiene"
    ACCESOS |o--o{ ASISTENCIAS : "origina"
    ZONAS ||--o{ PUNTOS_CONTROL : "contiene"
    PUNTOS_CONTROL ||--o{ ACCESOS : "lee"
    PERSONAS |o--o{ ACCESOS : "realiza"
    ZONAS ||--o{ PERMISOS_ZONA : "autoriza"
    PERSONAS ||--o{ RESTRICCIONES : "recibe"
    PERSONAS ||--o{ PASES : "visitante"
    PERSONAS ||--o{ PASES : "anfitrion"
    ZONAS ||--o{ PASES : "destino"
    ZONAS ||--o{ INCIDENCIAS : "ocurre en"
    PERSONAS |o--o{ INCIDENCIAS : "involucra"
    ACCESOS |o--o{ INCIDENCIAS : "dispara"

    ESCUELAS {
        number id_escuela PK
        varchar nombre UK
        varchar facultad
    }
    PERSONAS {
        number id_persona PK
        char codigo UK "contenido del QR"
        varchar nombre
        char dni UK
        varchar tipo
        varchar estado
    }
    ESTUDIANTES {
        number id_estudiante PK, FK
        number id_escuela FK
        number ciclo
    }
    DOCENTES {
        number id_docente PK, FK
        varchar especialidad
    }
    ZONAS {
        number id_zona PK
        varchar nombre UK
        varchar tipo
        number aforo
    }
    PUNTOS_CONTROL {
        number id_punto PK
        number id_zona FK
        varchar sentido
        varchar estado
    }
    ACCESOS {
        number id_acceso PK
        number id_persona FK "nulo si el codigo no existe"
        varchar codigo_leido
        number id_punto FK
        timestamp fecha_hora
        varchar resultado
        varchar motivo
        number confianza
    }
    CURSOS {
        number id_curso PK
        varchar codigo UK
        number id_escuela FK
        number creditos
    }
    SECCIONES {
        number id_seccion PK
        number id_curso FK
        number id_docente FK
        number id_aula FK "zona donde se dicta"
        varchar periodo
        varchar grupo
    }
    INSCRIPCIONES {
        number id_seccion PK, FK
        number id_estudiante PK, FK
        number faltas
        varchar estado
    }
    SESIONES {
        number id_sesion PK
        number id_seccion FK
        timestamp hora_inicio
        timestamp hora_fin
        varchar estado
    }
    ASISTENCIAS {
        number id_sesion PK, FK
        number id_estudiante PK, FK
        varchar estado
        timestamp hora_registro
        number id_acceso FK
    }
    PERMISOS_ZONA {
        number id_permiso PK
        varchar tipo_persona
        number id_zona FK
        varchar hora_desde
        varchar hora_hasta
    }
    RESTRICCIONES {
        number id_restriccion PK
        number id_persona FK
        varchar motivo
        date fecha_fin
        varchar estado
    }
    PASES {
        number id_pase PK
        number id_visitante FK
        number id_anfitrion FK
        number id_zona_destino FK
        timestamp vigente_desde
        timestamp vigente_hasta
        varchar estado
    }
    INCIDENCIAS {
        number id_incidencia PK
        number id_zona FK
        number id_persona FK
        number id_acceso FK
        varchar tipo
        varchar gravedad
        varchar estado
        varchar origen
    }
    PARAMETROS {
        varchar nombre PK
        varchar valor
    }
    AUDITORIA {
        number id_auditoria PK
        varchar tabla
        varchar operacion
        varchar usuario
        timestamp fecha
    }
```

Integridad: 18 claves primarias, 24 foráneas, 7 únicas, 29 checks con nombre y 8 índices secundarios. `parametros` guarda los umbrales (faltas máximas, minutos de tardanza, intentos, umbral LBPH, zona horaria) y `auditoria` recibe los triggers.

## 3. Procedimientos PL/SQL y reglas

Todos son procedimientos sueltos del esquema dueño. Un acceso denegado **no es un error**: se registra y se devuelve por parámetros `OUT`. Los errores reales usan `raise_application_error` (`-20001` entrada inválida, `-20002` inexistente, `-20003` estado inválido, `-20004` parámetro faltante, `-20005` duplicado, `-20099` inesperado) y hacen `rollback`.

| Procedimiento | Función |
|---|---|
| `p_verificar_persona` | Busca el código del QR (reemplaza al CSV): nombre, tipo, estado y si existe |
| `p_registrar_acceso` | Decide y registra el acceso, la asistencia y las incidencias en una transacción |
| `p_cerrar_sesion` | Cierra la sesión, marca las faltas e inhabilita al superar el límite |
| `p_emitir_pase`, `p_revocar_pase` | Pases de visitantes |
| `p_registrar_restriccion`, `p_levantar_restriccion` | Restricciones de ingreso |
| `p_registrar_incidencia`, `p_resolver_incidencia` | Incidencias del vigilante |
| `p_registrar_persona`, `p_modificar_persona`, `p_eliminar_persona` | CRUD de personas (alta con subtipo en una transacción, baja lógica si hay historial) |
| `p_listar_personas`, `p_buscar_personas` | Consultas con `SYS_REFCURSOR` |
| `p_obtener_parametro` | Lee un parámetro (el punto de acceso lee `UMBRAL_LBPH`) |
| `p_crear_sesion`, `p_cancelar_sesion` | Programa una sesión de clase y cancela una programada que aún no tiene asistencias |
| `p_obtener_desfase` | Minutos entre la hora del servidor y la hora local, para convertir las fechas que envían los clientes |

**Reglas de `p_registrar_acceso`, en este orden:**

1. Código inexistente: `codigo_inexistente` (`id_persona` nulo).
2. Persona con estado distinto de activo: `persona_inactiva`.
3. Rostro que no coincide: `rostro_no_coincide`.
4. Restricción vigente: `persona_restringida` y se crea una incidencia de gravedad **alta**.
5. Autorización por zona. Visitante: necesita un pase activo y vigente (en la puerta basta cualquiera; en otra zona, uno de esa zona) o `sin_pase_vigente`. Los demás: fila en `permisos_zona` (`zona_no_autorizada`) y hora local dentro de la ventana (`fuera_de_horario`).
6. Si se permite en un aula o laboratorio: el estudiante inscrito con una sesión entre 10 minutos antes del inicio y `MIN_MAX_TARDANZA` después recibe `presente` (hasta `MIN_TARDANZA` minutos) o `tardanza`, sin duplicar ni degradar; el docente solo hace pasar la sesión a `en_curso`.
7. Si se deniega: al llegar a `INTENTOS_PARA_INCIDENCIA` denegados en `MIN_VENTANA_INTENTOS` minutos (misma zona y misma persona o código) se crea una incidencia `intentos_reiterados` de gravedad **media**, salvo que ya haya una abierta equivalente.

Los umbrales se leen de la tabla `parametros`; no están escritos en el código.

**Reportes (`SYS_REFCURSOR`):** `r_asistencia_seccion`, `r_asistencia_sesion`, `r_alumnos_en_riesgo`, `r_ranking_tardanzas`, `r_accesos_denegados` (con `ROLLUP`), `r_incidencias`, `r_pases_vigentes`, `r_uso_aulas_vs_sesiones` y `r_flujo_por_hora`. Para el panel hay además `r_resumen_hoy`, `r_accesos_bitacora` (con filtros), `r_zonas`, `r_escuelas`, `r_secciones`, `r_sesiones` y `r_restricciones`.

**Hora local:** las marcas de tiempo se guardan en hora del servidor (UTC en el contenedor). Los reportes interpretan las fechas como días de la hora local y muestran las horas en `America/Lima` (parámetro `ZONA_HORARIA`, funciones `f_desfase` y `f_hoy_local`).

Total en la base: 18 procedimientos `p_*`, 16 `r_*`, 4 funciones y 2 triggers, todos válidos.

## 4. Roles, permisos y tablespaces

Los roles **solo tienen `EXECUTE` sobre procedimientos; ninguno tiene privilegios sobre tablas** (comprobado: 0 privilegios sobre tablas). Los procedimientos usan los derechos de su propietario.

| Usuario | Rol | Puede ejecutar |
|---|---|---|
| `u_punto` | `rol_punto_control` | `p_verificar_persona`, `p_registrar_acceso`, `p_obtener_parametro` |
| `u_vigilante` | `rol_vigilante` | Lo anterior, pases, restricciones, incidencias, `p_buscar_personas`, reportes de seguridad y consultas del panel (resumen del día, bitácora, zonas, restricciones vigentes) |
| `u_docente` | `rol_docente` | Reportes de asistencia y la lista de secciones y sesiones |
| `u_admin` | `rol_admin` | Todos los procedimientos y funciones |

Total de `EXECUTE`: punto de control 3, docente 6, vigilante 19 y administrador 38. El punto de acceso y el panel web se conectan con estos mismos usuarios.

| Tablespace | Tamaño inicial / máximo | Contenido |
|---|---|---|
| `ts_acceso_datos` | 50 MB / 500 MB | Tablas maestras, académicas y de seguridad, con sus claves |
| `ts_acceso_log` | 50 MB / 500 MB | Tablas de alto volumen: `accesos`, `asistencias`, `auditoria` |
| `ts_acceso_idx` | 30 MB / 200 MB | Los 8 índices secundarios |

Los tres tienen `autoextend`. Auditoría: los triggers `trg_aud_personas` y `trg_aud_restricciones` guardan operación, usuario real de la sesión y el detalle de lo que cambió.

## 5. Evidencia de las pruebas

Salida real de cada ejecución en `docs/evidencia/` (detalle por etapa en `docs/AVANCE.md`).

| Archivo | Qué demuestra |
|---|---|
| `etapa1_*.txt` | Carga desde cero: 18 tablas, 17 personas, 505 accesos, índices y tablespaces |
| `test_03.txt` | Todos los motivos de denegación, visitantes y pases, asistencia `presente` y `tardanza` sin duplicar, `intentos_reiterados`, `p_cerrar_sesion` con inhabilitación, CRUD y errores controlados |
| `reportes.txt` | Los 9 reportes y las consultas del panel impresos con `VARIABLE` y `PRINT`, en hora local, y sus errores controlados |
| `permisos.txt` | `u_punto` no puede hacer `SELECT` sobre `accesos` (`ORA-00942`) pero sí ejecutar `p_registrar_acceso`; matriz por rol; bitácora de auditoría (16 filas) |
| `etapa6_python.txt` | 49 pruebas de Python (QR y rostro con cámara simulada, flujo del punto de acceso, alta de personas), el modo `--simular`, el menú de consola y el error de cámara |
| `etapa7_panel.txt` | 64 pruebas del panel (login, CSRF, permisos por rol y flujos completos), suite completa de 113 pruebas y matriz de pantallas por rol |
| `panel/*.png` | Capturas del panel: dashboard, bitácora, asistencia y pases |

## 6. Punto de acceso y panel web

- **Punto de acceso** (`src/punto_acceso.py`, usuario `u_punto`): lee el QR, llama a `p_verificar_persona`, compara el rostro con OpenCV (LBPH; el umbral sale de `parametros`) y llama a `p_registrar_acceso`. La decisión la toma Oracle; el programa solo informa. Incluye modo `--simular` para probar sin cámara.
- **Panel web** (`src/app.py`, Flask + plantilla SB Admin): login por rol; cada rol usa su usuario de Oracle y solo ve sus pantallas. Dashboard, personas, bitácora de accesos con filtros, asistencia (programar, cancelar y cerrar sesiones), incidencias, pases, restricciones y reportes con descarga CSV.
- **Pruebas**: 113 automáticas (Oracle real y cámara simulada), todas OK.

## 7. Cómo reproducir

```
# Base de datos (contenedor oracle-xe encendido)
00_admin.sql (SYSTEM) -> 01_esquema.sql -> 02_datos.sql -> 03_procedimientos.sql
-> 04_reportes.sql -> 05_triggers.sql -> 06_permisos.sql   (los seis últimos como acceso_owner)
Pruebas SQL: test_03.sql, test_04.sql, test_05_06.sql      Reinicio: 99_reset.sql

# Aplicación
python3 -m venv venv && ./venv/bin/pip install -r requirements.txt
cp .env.example .env                     # completar las claves
./venv/bin/python src/main.py            # menú de consola: punto de acceso y administración
./venv/bin/python src/app.py             # panel web en http://127.0.0.1:5000
./venv/bin/python -m unittest discover -s tests
```

## 8. Pendientes y límites conocidos

- Las marcas de tiempo se guardan en hora del servidor (UTC en este contenedor); las ventanas horarias de `permisos_zona`, los reportes y el panel usan la hora local `America/Lima`. El desfase se calcula con la hora actual, así que no serviría para una zona con cambio de horario (Lima no lo tiene).
- Un docente solo puede ver reportes; cerrar sesiones es del administrador. Todos los docentes comparten el usuario `u_docente`, así que cada uno ve todas las secciones; separarlos requeriría un usuario por docente.
- `p_registrar_acceso` no distingue el sentido del punto: un visitante con el pase vencido tampoco puede salir por la puerta de salida.
- La auditoría cubre `personas` y `restricciones`, no pases ni incidencias.
- Las sesiones se programan y cancelan desde el panel, pero no hay procedimientos para crear secciones ni inscripciones (se cargan por script).
- El rostro no se registra desde la web: se hace en el punto de acceso (opción 2.3 del menú de consola).
- La cámara real y el panel en un navegador de escritorio no se probaron: se verificaron con cámara simulada, el cliente de pruebas de Flask y capturas de Firefox sin interfaz.
- Los rostros y modelos LBPH siguen en disco (`datos/`, fuera del repositorio), no en la base.
- Las claves de los usuarios de la base están en `00_admin.sql` por ser un proyecto de curso.
