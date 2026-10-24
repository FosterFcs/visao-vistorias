-- =====================================================================
--  My Moving Vistorias — esquema do banco (Supabase / PostgreSQL)
--  Desenvolvido por Foster Tech Soluções — Wilson Foster
--  (24) 99209-6103 · comercial@fosterconstrucoes.com.br
--
--  Como usar: Supabase > SQL Editor > New query > cole tudo > Run.
--  O script é idempotente (pode rodar de novo sem quebrar).
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- Papéis e perfis
-- ---------------------------------------------------------------------
create table if not exists public.perfis (
  id          uuid primary key references auth.users(id) on delete cascade,
  nome        text not null,
  telefone    text,
  papel       text not null default 'equipe'
              check (papel in ('admin','coordenador','equipe','parceiro')),
  empresa_parceira text,               -- só para papel = parceiro
  ativo       boolean not null default true,
  updated_at  timestamptz not null default now(),
  deleted     boolean not null default false
);

-- Papel do usuário logado (security definer evita recursão nas policies)
create or replace function public.meu_papel() returns text
language sql stable security definer set search_path = public as $$
  select papel from public.perfis where id = auth.uid() and ativo and not deleted
$$;

create or replace function public.eh_interno() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.meu_papel() in ('admin','coordenador','equipe'), false)
$$;

create or replace function public.eh_gestor() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(public.meu_papel() in ('admin','coordenador'), false)
$$;

-- Primeiro usuário cadastrado vira admin; os demais entram como equipe (inativos
-- até o admin liberar).
create or replace function public.novo_usuario() returns trigger
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  select count(*) into n from public.perfis;
  insert into public.perfis(id, nome, papel, ativo)
  values (new.id,
          coalesce(new.raw_user_meta_data->>'nome', split_part(new.email,'@',1)),
          case when n = 0 then 'admin' else 'equipe' end,
          n = 0)
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists trg_novo_usuario on auth.users;
create trigger trg_novo_usuario after insert on auth.users
  for each row execute function public.novo_usuario();

-- ---------------------------------------------------------------------
-- Configurações da empresa (linha única)
-- ---------------------------------------------------------------------
create table if not exists public.configuracoes (
  id         uuid primary key default gen_random_uuid(),
  dados      jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  deleted    boolean not null default false
);

-- ---------------------------------------------------------------------
-- Cadastros
-- ---------------------------------------------------------------------
create table if not exists public.clientes (
  id         uuid primary key default gen_random_uuid(),
  nome       text not null,
  documento  text,
  telefone   text,
  email      text,
  observacoes text,
  updated_at timestamptz not null default now(),
  deleted    boolean not null default false
);

create table if not exists public.caminhoes (
  id            uuid primary key default gen_random_uuid(),
  placa         text not null,
  modelo        text,
  capacidade_m3 numeric(6,1),
  ativo         boolean not null default true,
  updated_at    timestamptz not null default now(),
  deleted       boolean not null default false
);

create table if not exists public.materiais (
  id         uuid primary key default gen_random_uuid(),
  nome       text not null,
  unidade    text not null default 'un',
  estoque    numeric(10,2) not null default 0,
  custo_unit numeric(10,2) not null default 0,
  updated_at timestamptz not null default now(),
  deleted    boolean not null default false
);

-- ---------------------------------------------------------------------
-- Mudança (ordem de serviço)
-- ---------------------------------------------------------------------
create table if not exists public.mudancas (
  id               uuid primary key default gen_random_uuid(),
  codigo           text not null unique,
  cliente_id       uuid references public.clientes(id),
  tipo             text not null default 'residencial'
                   check (tipo in ('residencial','comercial','internacional','guarda')),
  status           text not null default 'orcamento'
                   check (status in ('orcamento','aprovada','embalagem','carregamento',
                                     'transito','entrega','concluida','cancelada')),
  origem_endereco  text,
  origem_detalhes  text,               -- andar, elevador, restrições do condomínio
  destino_endereco text,
  destino_detalhes text,
  distancia_km     numeric(8,1),
  data_prevista    date,
  caminhao_id      uuid references public.caminhoes(id),
  equipe           jsonb not null default '[]'::jsonb,   -- [{id, nome}]
  parceiro_id      uuid references public.perfis(id),    -- frete terceirizado
  cubagem_m3       numeric(8,2) default 0,
  valor_orcado     numeric(12,2) default 0,
  valor_aprovado   numeric(12,2),
  seguro_valor_declarado numeric(12,2),
  condicoes_pagamento text,
  observacoes      text,
  token_portal     uuid not null default gen_random_uuid(),
  avaliacao_nota   int check (avaliacao_nota between 1 and 5),
  avaliacao_comentario text,
  criado_por       uuid references public.perfis(id),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  deleted          boolean not null default false
);
alter table public.mudancas add column if not exists condicoes_pagamento text;
create index if not exists idx_mudancas_status on public.mudancas(status);
create index if not exists idx_mudancas_data   on public.mudancas(data_prevista);

-- Itens levantados na vistoria de orçamento (cubagem)
create table if not exists public.orcamento_itens (
  id          uuid primary key default gen_random_uuid(),
  mudanca_id  uuid not null references public.mudancas(id) on delete cascade,
  comodo      text,
  item        text not null,
  quantidade  int not null default 1,
  m3_unit     numeric(6,2) not null default 0,
  especial    boolean not null default false,  -- piano, vidro, obra de arte...
  observacao  text,
  updated_at  timestamptz not null default now(),
  deleted     boolean not null default false
);

-- Volumes etiquetados (caixa ou móvel) — o coração do inventário
create table if not exists public.volumes (
  id              uuid primary key default gen_random_uuid(),
  mudanca_id      uuid not null references public.mudancas(id) on delete cascade,
  numero          int not null,
  tipo            text not null default 'caixa'
                  check (tipo in ('caixa','movel','eletro','fragil','especial')),
  descricao       text,
  comodo_origem   text,
  comodo_destino  text,
  valor_declarado numeric(12,2),
  avarias_previas jsonb not null default '[]'::jsonb,  -- [{tipo, local, obs}]
  status          text not null default 'etiquetado'
                  check (status in ('etiquetado','carregado','entregue','armazenado','extraviado')),
  carregado_em    timestamptz,
  entregue_em     timestamptz,
  posicao_deposito text,
  updated_at      timestamptz not null default now(),
  deleted         boolean not null default false,
  unique (mudanca_id, numero)
);
create index if not exists idx_volumes_mudanca on public.volumes(mudanca_id);

-- Fotos (arquivo no Storage, bucket "fotos")
create table if not exists public.fotos (
  id          uuid primary key default gen_random_uuid(),
  mudanca_id  uuid not null references public.mudancas(id) on delete cascade,
  ref_tipo    text not null check (ref_tipo in ('volume','vistoria','ocorrencia','orcamento')),
  ref_id      uuid not null,
  caminho     text not null,          -- caminho dentro do bucket
  legenda     text,
  tirada_em   timestamptz not null default now(),
  lat         double precision,
  lng         double precision,
  updated_at  timestamptz not null default now(),
  deleted     boolean not null default false
);
create index if not exists idx_fotos_ref on public.fotos(ref_tipo, ref_id);

-- Vistoria do imóvel (áreas comuns e cômodos, antes/depois)
create table if not exists public.vistorias_imovel (
  id          uuid primary key default gen_random_uuid(),
  mudanca_id  uuid not null references public.mudancas(id) on delete cascade,
  local       text not null check (local in ('origem','destino')),
  momento     text not null check (momento in ('antes','depois')),
  area        text not null,           -- elevador, hall, corredor, escada...
  condicao    text not null default 'ok' check (condicao in ('ok','dano_previo','dano_novo')),
  observacao  text,
  updated_at  timestamptz not null default now(),
  deleted     boolean not null default false
);

-- Ocorrências (avaria, extravio, atraso, dano ao imóvel)
create table if not exists public.ocorrencias (
  id          uuid primary key default gen_random_uuid(),
  mudanca_id  uuid not null references public.mudancas(id) on delete cascade,
  volume_id   uuid references public.volumes(id),
  tipo        text not null check (tipo in ('avaria','extravio','atraso','imovel','outro')),
  descricao   text not null,
  status      text not null default 'aberta' check (status in ('aberta','em_analise','resolvida')),
  responsavel text check (responsavel in ('empresa','cliente','terceiro','preexistente')),
  valor_indenizacao numeric(12,2),
  resolucao   text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  deleted     boolean not null default false
);

-- Assinaturas digitais do cliente
create table if not exists public.assinaturas (
  id          uuid primary key default gen_random_uuid(),
  mudanca_id  uuid not null references public.mudancas(id) on delete cascade,
  etapa       text not null check (etapa in ('orcamento','inventario','vistoria_origem',
                                             'entrega','vistoria_destino')),
  nome        text not null,
  documento   text,
  imagem      text not null,          -- PNG em data URL
  lat         double precision,
  lng         double precision,
  assinado_em timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  deleted     boolean not null default false
);

-- Consumo de materiais por mudança
create table if not exists public.consumo_materiais (
  id          uuid primary key default gen_random_uuid(),
  mudanca_id  uuid not null references public.mudancas(id) on delete cascade,
  material_id uuid not null references public.materiais(id),
  quantidade  numeric(10,2) not null,
  updated_at  timestamptz not null default now(),
  deleted     boolean not null default false
);

-- ---------------------------------------------------------------------
-- Guarda-móveis
-- ---------------------------------------------------------------------
create table if not exists public.guarda_contratos (
  id             uuid primary key default gen_random_uuid(),
  mudanca_id     uuid references public.mudancas(id),
  cliente_id     uuid not null references public.clientes(id),
  inicio         date not null,
  fim            date,
  valor_mensal   numeric(10,2) not null default 0,
  dia_vencimento int default 10,
  m3_ocupado     numeric(8,2),
  status         text not null default 'ativo' check (status in ('ativo','encerrado')),
  observacoes    text,
  updated_at     timestamptz not null default now(),
  deleted        boolean not null default false
);

create table if not exists public.guarda_movimentos (
  id          uuid primary key default gen_random_uuid(),
  contrato_id uuid not null references public.guarda_contratos(id) on delete cascade,
  volume_id   uuid references public.volumes(id),
  tipo        text not null check (tipo in ('entrada','saida')),
  data        timestamptz not null default now(),
  observacao  text,
  updated_at  timestamptz not null default now(),
  deleted     boolean not null default false
);

-- ---------------------------------------------------------------------
-- Linha do tempo (auditoria visível ao cliente)
-- ---------------------------------------------------------------------
create table if not exists public.eventos (
  id          uuid primary key default gen_random_uuid(),
  mudanca_id  uuid not null references public.mudancas(id) on delete cascade,
  tipo        text not null,
  descricao   text not null,
  publico     boolean not null default true,   -- aparece no portal do cliente
  autor       text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  deleted     boolean not null default false
);
create index if not exists idx_eventos_mudanca on public.eventos(mudanca_id);

-- ---------------------------------------------------------------------
-- updated_at automático (base da sincronização offline)
-- ---------------------------------------------------------------------
create or replace function public.toca_updated_at() returns trigger
language plpgsql as $$
begin new.updated_at := now(); return new; end $$;

do $$
declare t text;
begin
  foreach t in array array['perfis','configuracoes','clientes','caminhoes','materiais',
    'mudancas','orcamento_itens','volumes','fotos','vistorias_imovel','ocorrencias',
    'assinaturas','consumo_materiais','guarda_contratos','guarda_movimentos','eventos']
  loop
    execute format('drop trigger if exists trg_upd on public.%I', t);
    execute format('create trigger trg_upd before insert or update on public.%I
                    for each row execute function public.toca_updated_at()', t);
    execute format('create index if not exists idx_%s_upd on public.%I(updated_at)', t, t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- RLS (segurança por linha)
-- ---------------------------------------------------------------------
alter table public.perfis            enable row level security;
alter table public.configuracoes     enable row level security;
alter table public.clientes          enable row level security;
alter table public.caminhoes         enable row level security;
alter table public.materiais         enable row level security;
alter table public.mudancas          enable row level security;
alter table public.orcamento_itens   enable row level security;
alter table public.volumes           enable row level security;
alter table public.fotos             enable row level security;
alter table public.vistorias_imovel  enable row level security;
alter table public.ocorrencias       enable row level security;
alter table public.assinaturas       enable row level security;
alter table public.consumo_materiais enable row level security;
alter table public.guarda_contratos  enable row level security;
alter table public.guarda_movimentos enable row level security;
alter table public.eventos           enable row level security;

-- Parceiro só enxerga mudanças atribuídas a ele
create or replace function public.pode_mudanca(m uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.eh_interno()
      or exists (select 1 from public.mudancas x
                 where x.id = m and x.parceiro_id = auth.uid()
                   and public.meu_papel() = 'parceiro')
$$;

-- perfis
drop policy if exists p_perfis_sel on public.perfis;
create policy p_perfis_sel on public.perfis for select to authenticated
  using (id = auth.uid() or public.eh_interno());
drop policy if exists p_perfis_adm on public.perfis;
create policy p_perfis_adm on public.perfis for update to authenticated
  using (public.meu_papel() = 'admin') with check (public.meu_papel() = 'admin');
drop policy if exists p_perfis_ins on public.perfis;
create policy p_perfis_ins on public.perfis for insert to authenticated
  with check (public.meu_papel() = 'admin');

-- configurações: todos internos leem, só gestor grava
drop policy if exists p_cfg_sel on public.configuracoes;
create policy p_cfg_sel on public.configuracoes for select to authenticated
  using (public.meu_papel() is not null);
drop policy if exists p_cfg_ins on public.configuracoes;
create policy p_cfg_ins on public.configuracoes for insert to authenticated
  with check (public.eh_gestor());
drop policy if exists p_cfg_upd on public.configuracoes;
create policy p_cfg_upd on public.configuracoes for update to authenticated
  using (public.eh_gestor()) with check (public.eh_gestor());

-- cadastros: equipe interna lê e grava
do $$
declare t text;
begin
  foreach t in array array['clientes','caminhoes','materiais','guarda_contratos']
  loop
    execute format('drop policy if exists p_%s_all on public.%I', t, t);
    execute format('create policy p_%s_all on public.%I for all to authenticated
                    using (public.eh_interno()) with check (public.eh_interno())', t, t);
  end loop;
end $$;

-- parceiro precisa ver o nome do cliente das mudanças dele
drop policy if exists p_clientes_parc on public.clientes;
create policy p_clientes_parc on public.clientes for select to authenticated
  using (exists (select 1 from public.mudancas m
                 where m.cliente_id = clientes.id and m.parceiro_id = auth.uid()));

-- mudanças
drop policy if exists p_mud_sel on public.mudancas;
create policy p_mud_sel on public.mudancas for select to authenticated
  using (public.pode_mudanca(id));
drop policy if exists p_mud_ins on public.mudancas;
-- (upsert do app = INSERT ... ON CONFLICT: parceiro precisa passar aqui para atualizar)
create policy p_mud_ins on public.mudancas for insert to authenticated
  with check (public.eh_interno() or public.pode_mudanca(id));
drop policy if exists p_mud_upd on public.mudancas;
create policy p_mud_upd on public.mudancas for update to authenticated
  using (public.pode_mudanca(id)) with check (public.pode_mudanca(id));

-- tabelas filhas da mudança
do $$
declare t text;
begin
  foreach t in array array['orcamento_itens','volumes','fotos','vistorias_imovel',
                           'ocorrencias','assinaturas','consumo_materiais','eventos']
  loop
    execute format('drop policy if exists p_%s_all on public.%I', t, t);
    execute format('create policy p_%s_all on public.%I for all to authenticated
                    using (public.pode_mudanca(mudanca_id))
                    with check (public.pode_mudanca(mudanca_id))', t, t);
  end loop;
end $$;

drop policy if exists p_gmov_all on public.guarda_movimentos;
create policy p_gmov_all on public.guarda_movimentos for all to authenticated
  using (public.eh_interno()) with check (public.eh_interno());

-- ---------------------------------------------------------------------
-- Portal do cliente (acesso por link com token, sem login)
-- ---------------------------------------------------------------------
create or replace function public.portal_mudanca(p_token uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare m public.mudancas; r jsonb; cfg jsonb;
begin
  select * into m from public.mudancas where token_portal = p_token and not deleted;
  if not found then return null; end if;
  select dados into cfg from public.configuracoes where not deleted order by updated_at desc limit 1;

  select jsonb_build_object(
    'empresa', coalesce(cfg, '{}'::jsonb) - 'valor_m3' - 'valor_km' - 'valor_ajudante',
    'mudanca', jsonb_build_object(
       'codigo', m.codigo, 'tipo', m.tipo, 'status', m.status,
       'origem_endereco', m.origem_endereco, 'destino_endereco', m.destino_endereco,
       'data_prevista', m.data_prevista, 'cubagem_m3', m.cubagem_m3,
       'valor_aprovado', m.valor_aprovado, 'avaliacao_nota', m.avaliacao_nota,
       'avaliacao_comentario', m.avaliacao_comentario, 'updated_at', m.updated_at),
    'cliente', (select jsonb_build_object('nome', c.nome) from public.clientes c where c.id = m.cliente_id),
    'volumes', coalesce((select jsonb_agg(jsonb_build_object(
        'id', v.id, 'numero', v.numero, 'tipo', v.tipo, 'descricao', v.descricao,
        'comodo_origem', v.comodo_origem, 'comodo_destino', v.comodo_destino,
        'avarias_previas', v.avarias_previas, 'status', v.status,
        'carregado_em', v.carregado_em, 'entregue_em', v.entregue_em) order by v.numero)
        from public.volumes v where v.mudanca_id = m.id and not v.deleted), '[]'::jsonb),
    'vistorias', coalesce((select jsonb_agg(to_jsonb(x) - 'deleted') from public.vistorias_imovel x
        where x.mudanca_id = m.id and not x.deleted), '[]'::jsonb),
    'ocorrencias', coalesce((select jsonb_agg(jsonb_build_object(
        'id', o.id, 'volume_id', o.volume_id, 'tipo', o.tipo, 'descricao', o.descricao,
        'status', o.status, 'resolucao', o.resolucao, 'created_at', o.created_at))
        from public.ocorrencias o where o.mudanca_id = m.id and not o.deleted), '[]'::jsonb),
    'fotos', coalesce((select jsonb_agg(jsonb_build_object(
        'ref_tipo', f.ref_tipo, 'ref_id', f.ref_id, 'caminho', f.caminho, 'legenda', f.legenda,
        'tirada_em', f.tirada_em))
        from public.fotos f where f.mudanca_id = m.id and not f.deleted), '[]'::jsonb),
    'assinaturas', coalesce((select jsonb_agg(jsonb_build_object(
        'etapa', a.etapa, 'nome', a.nome, 'imagem', a.imagem, 'assinado_em', a.assinado_em))
        from public.assinaturas a where a.mudanca_id = m.id and not a.deleted), '[]'::jsonb),
    'eventos', coalesce((select jsonb_agg(jsonb_build_object(
        'tipo', e.tipo, 'descricao', e.descricao, 'created_at', e.created_at) order by e.created_at)
        from public.eventos e where e.mudanca_id = m.id and e.publico and not e.deleted), '[]'::jsonb)
  ) into r;
  return r;
end $$;

create or replace function public.portal_avaliar(p_token uuid, p_nota int, p_comentario text)
returns boolean language plpgsql security definer set search_path = public as $$
declare mid uuid;
begin
  if p_nota < 1 or p_nota > 5 then return false; end if;
  update public.mudancas
     set avaliacao_nota = p_nota, avaliacao_comentario = left(p_comentario, 1000)
   where token_portal = p_token and status = 'concluida' and not deleted
  returning id into mid;
  if mid is null then return false; end if;
  insert into public.eventos(mudanca_id, tipo, descricao, publico, autor)
  values (mid, 'avaliacao', 'Cliente avaliou o serviço com nota ' || p_nota, true, 'Cliente');
  return true;
end $$;

revoke all on function public.portal_mudanca(uuid) from public;
revoke all on function public.portal_avaliar(uuid,int,text) from public;
grant execute on function public.portal_mudanca(uuid) to anon, authenticated;
grant execute on function public.portal_avaliar(uuid,int,text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- Storage: bucket de fotos
--   Leitura pública por URL (os caminhos usam UUID aleatório, impossíveis de
--   adivinhar) para o portal do cliente funcionar sem login.
--   Upload só por usuário autenticado ativo.
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('fotos', 'fotos', true)
on conflict (id) do nothing;

drop policy if exists "fotos_upload" on storage.objects;
create policy "fotos_upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'fotos' and public.meu_papel() is not null);

drop policy if exists "fotos_update" on storage.objects;
create policy "fotos_update" on storage.objects for update to authenticated
  using (bucket_id = 'fotos' and public.meu_papel() is not null);
