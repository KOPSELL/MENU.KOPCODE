# MENU.KOPCODE

Plataforma de cardápio digital e pedidos para restaurantes, com painel administrativo responsivo e página pública por restaurante.

## Recursos implementados

- Cadastro do responsável e criação automática do restaurante.
- Login por e-mail e senha via Supabase Auth.
- Painel do restaurante: visão geral, pedidos, produtos, categorias, identidade visual e planos.
- Cadastro/edição/exclusão de produtos, preços, descrições, disponibilidade e imagens.
- Logotipo, capa, descrição, WhatsApp, endereço e cor de destaque do restaurante.
- Página pública em `/m/slug-do-restaurante`, com busca, categorias, sacola e checkout mobile-first.
- Plano Essencial: prepara o pedido e abre o WhatsApp do restaurante com a mensagem preenchida.
- Plano Pedidos Pro e Gestão Completa: grava pedidos no banco, painel com atualização em tempo real e impressão manual de comanda.
- Três planos permanecem gratuitos durante a fase inicial.
- Isolamento multi-restaurante com políticas RLS e mídia por pasta de restaurante.

## Configuração Supabase

1. Crie um projeto Supabase.
2. Abra SQL Editor e execute todo o conteúdo de `supabase/schema.sql`.
3. Em Authentication > Providers > Email, habilite e-mail/senha e desative **Confirm email** para este fluxo inicial. O cadastro provisiona o restaurante logo após o Supabase criar a sessão; com confirmação de e-mail ativa, o provisionamento ainda precisa ser adaptado para acontecer após a confirmação.
4. Copie `.env.example` para `.env.local` e preencha:
   - `VITE_SUPABASE_URL`
   - `VITE_SUPABASE_ANON_KEY` (ou `VITE_SUPABASE_PUBLISHABLE_KEY`)
5. Instale dependências e execute `npm install`, depois `npm run dev`.

## Deploy Vercel

Importe este repositório na Vercel, configure as mesmas variáveis de ambiente e publique. O `vercel.json` já contém rewrite para rotas SPA.

## Observações de produção

- Nunca coloque a `service_role` key no frontend.
- O plano Básico encaminha o carrinho ao WhatsApp e não grava pedido no painel.
- O plano Pro/Completo grava pedidos e notifica o painel aberto via Supabase Realtime. A permissão de notificações do navegador é solicitada pelo botão de sino.
- A impressão é iniciada pelo navegador com a função imprimir comanda; impressão térmica automática em segundo plano exige um agente local/serviço de impressão e configuração específica da impressora.
- Integração push mesmo com navegador fechado exige configurar OneSignal (App ID, SDK, service worker e credenciais). O campo `VITE_ONESIGNAL_APP_ID` está reservado; não é habilitado sem credenciais.
- Nesta fase, todos os planos são gratuitos. Não há cobrança ou gateway de pagamento ligado.

## Stack

React, TypeScript, Vite, Supabase Auth/Database/Storage/Realtime, Lucide.
