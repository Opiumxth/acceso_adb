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
