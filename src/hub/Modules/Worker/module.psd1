# Manifesto do modulo Worker para o menu do HUB Benner.
@{
    Id           = 'Worker'
    Name         = 'Worker'
    Description  = 'Instala em lote o Benner Worker (23 ou 25) nas pastas escolhidas, com servidor, fila, providers e usuario por linha.'
    Subtitle     = 'Instalação em lote de Windows Services do Benner Worker'
    Order        = 20
    Glyph        = 'E912'
    View         = 'Worker.View.psm1'
    Factory      = 'New-WorkerView'
    BusyFunction = 'Test-WorkerViewBusy'
}
