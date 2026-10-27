# Archivos de terceros del panel web

Se incluyen localmente para que el panel funcione sin internet. No se modificaron.

| Carpeta | Contenido | Versión | Licencia | Origen |
|---|---|---|---|---|
| `sb-admin/` | `css/styles.css`, `js/scripts.js` | SB Admin 7.0.7 (incluye Bootstrap 5.2.3 compilado) | MIT (`LICENSE`) | https://github.com/StartBootstrap/startbootstrap-sb-admin (carpeta `dist/`) |
| `bootstrap/` | `js/bootstrap.bundle.min.js` | Bootstrap 5.2.3 | MIT (`LICENSE`) | paquete npm `bootstrap@5.2.3` |
| `fontawesome/` | `css/all.min.css`, `webfonts/fa-solid-900.woff2`, `webfonts/fa-regular-400.woff2` | Font Awesome Free 6.7.2 | Íconos CC BY 4.0, fuentes SIL OFL 1.1, código MIT (`LICENSE.txt`) | paquete npm `@fortawesome/fontawesome-free@6.7.2` |

Los paquetes de npm se descargaron con `npm pack` y se verificó su integridad (SHA-512) contra la
del registro. Del template SB Admin se copió solo lo necesario (CSS, JS y licencia); las páginas de
demostración, los gráficos y las demás dependencias no se usan.

Font Awesome: `all.min.css` también declara las fuentes `brands` y `v4compatibility`, que no se
incluyen porque el panel no usa esos íconos.
