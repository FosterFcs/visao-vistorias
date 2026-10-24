# Visão Mudanças Vistorias

Sistema de vistoria, inventário com QR code e rastreio de mudanças para a **Visão Mudanças** (demonstração).
PWA em arquivo único (HTML + Supabase), funciona offline no campo.

Desenvolvido por **Foster Tech Soluções** — Wilson Foster · (24) 99209-6103 · comercial@fosterconstrucoes.com.br

## Arquivos

| Arquivo | O que é |
|---|---|
| `index.html` | O sistema inteiro |
| `schema.sql` | Banco de dados Supabase: tabelas, segurança (RLS), portal do cliente, bucket de fotos |
| `sw.js` | Service worker (cache para uso offline) |
| `manifest.webmanifest`, `icon*.png`, `icon.svg` | Instalação como app no celular |

## Testar agora (sem servidor)

Abra o `index.html` publicado e toque em **Entrar em modo demonstração**. Já vem com 4 mudanças de exemplo
(concluída, em carregamento, orçamento e internacional) e um contrato de guarda-móveis. Os dados ficam só no aparelho.

## Colocar em produção

1. **Supabase**: crie um projeto (ex.: `mymoving-vistorias`). Em *SQL Editor*, cole todo o `schema.sql` e rode.
2. **Auth**: em *Authentication > URL Configuration*, coloque a URL do GitHub Pages em *Site URL* e *Redirect URLs*.
   Se preferir sem confirmação por e-mail, desligue *Confirm email* em *Providers > Email*.
3. **Chaves**: em *Project Settings > API*, copie a URL e a chave pública (anon/publishable). Cole em
   `CONEXAO_PADRAO` no início de `src/core.js` e rode `./build.sh` — ou configure pela tela de login em
   “Conectar ao servidor” (fica salvo no aparelho).
4. **GitHub Pages**: crie o repositório (ex.: `FosterFcs/mymoving-vistorias`), suba `index.html`, `sw.js`,
   `manifest.webmanifest` e os ícones, e ative *Settings > Pages* na branch `main`.
5. **Primeiro acesso**: a primeira conta criada vira **administrador**. As demais ficam “aguardando” até o admin
   liberar em *Cadastros > Equipe e parceiros* e definir o papel.

## Papéis

- **Administrador** — tudo, inclusive usuários.
- **Coordenador** — operação, valores, relatórios e configurações.
- **Equipe de campo** — orçamento, inventário, vistoria, carga/entrega e ocorrências, sem ver valores.
- **Parceiro (frete)** — só as mudanças atribuídas a ele.

## Como funciona offline

Tudo é gravado primeiro no aparelho (IndexedDB) e entra numa fila. Quando há internet, o app envia as fotos ao
Storage, envia as alterações e baixa o que mudou no servidor (a cada 60 s e ao reconectar). O selo no topo mostra
“Sincronizado”, “N pendentes” ou “Offline”.

**Cuidado:** para evitar números de volume repetidos, etiquete cada mudança em um único aparelho.

## Observações técnicas

- Fotos: reduzidas para 1600 px, JPEG ~78%, com carimbo de código, data/hora e GPS quando disponível.
- Bucket `fotos` é de leitura pública por URL (caminhos com UUID impossíveis de adivinhar) para o portal do
  cliente funcionar sem login. Upload só com usuário ativo.
- Portal do cliente: `index.html?portal=<token>` — usa as funções `portal_mudanca` e `portal_avaliar`.
- Bibliotecas: supabase-js 2.45.4, qrcode-generator 1.4.4, html5-qrcode 2.3.8 (CDN, em cache pelo service worker).
- A câmera para leitura do QR exige HTTPS (o GitHub Pages já é).
- Logo: recriação vetorial aproximada a partir da foto. Trocar pelo vetor oficial quando o cliente enviar
  (constante `LOGO` em `src/core.js` e `icon.svg`).
