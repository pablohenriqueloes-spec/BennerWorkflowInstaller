# Manifesto do modulo Workflow para o menu do HUB Benner.
# Para criar um modulo novo: copie esta pasta, troque os valores e implemente
# a funcao de tela (View/Factory). Detalhes em docs/HUB.md.
@{
    Id           = 'Workflow'
    Name         = 'Workflow'
    Description  = 'Descobre, configura (.exe.config), instala, desbloqueia e gerencia os serviços Benner Workflow.'
    Subtitle     = 'Instalação em lote de Windows Services do Benner Workflow'
    Order        = 10
    Glyph        = 'E713'
    View         = 'Workflow.View.psm1'
    Factory      = 'New-WorkflowView'
    BusyFunction = 'Test-WorkflowViewBusy'
}
