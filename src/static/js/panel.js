// Confirmacion antes de enviar los formularios marcados con data-confirmar
document.addEventListener('submit', function (evento) {
    var formulario = evento.target;
    var mensaje = formulario.getAttribute && formulario.getAttribute('data-confirmar');
    if (mensaje && !window.confirm(mensaje)) {
        evento.preventDefault();
    }
});

// En el formulario de personas se muestran solo los campos del tipo elegido
(function () {
    var tipo = document.getElementById('tipo');
    if (!tipo) { return; }
    function actualizar() {
        document.querySelectorAll('[data-tipo-grupo]').forEach(function (grupo) {
            grupo.classList.toggle('d-none', grupo.getAttribute('data-tipo-grupo') !== tipo.value);
        });
    }
    tipo.addEventListener('change', actualizar);
    actualizar();
})();
