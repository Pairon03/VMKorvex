-- Painel interno da Korvex (vmkorvex.vercel.app/painel).
-- Rodar depois do briefing.sql: SQL Editor → New query → colar tudo → Run.
-- Pode rodar de novo quantas vezes precisar; nada é apagado.
--
-- Antes de rodar, crie os logins em Authentication → Users → Add user → Create new user
-- (marque "Auto Confirm User"). Todo usuário que existir no Auth na hora em que este
-- arquivo roda entra na equipe. Quem for criado depois só entra rodando de novo.

-- Equipe -------------------------------------------------------------------
-- Só quem está nesta tabela vê alguma coisa no painel. Um login qualquer, sem
-- estar aqui, não lê nem muda nada.
create table if not exists public.equipe (
  user_id   uuid primary key references auth.users (id) on delete cascade,
  nome      text not null,                       -- dá para trocar no painel (menu do topo)
  visto_em  timestamptz not null default now()   -- para o aviso de briefing novo
);

insert into public.equipe (user_id, nome)
select id, initcap(trim(regexp_replace(split_part(email, '@', 1), '[._0-9-]+', ' ', 'g'))) from auth.users
on conflict (user_id) do nothing;

create or replace function public.is_equipe()
returns boolean
language sql stable security definer set search_path = public
as $$ select exists (select 1 from public.equipe where user_id = auth.uid()) $$;

revoke all on function public.is_equipe() from public, anon;
grant execute on function public.is_equipe() to authenticated;

alter table public.equipe enable row level security;
revoke all on public.equipe from anon, authenticated;
grant select on public.equipe to authenticated;
grant update (nome, visto_em) on public.equipe to authenticated;

drop policy if exists "equipe se ve" on public.equipe;
create policy "equipe se ve" on public.equipe
  for select to authenticated using (public.is_equipe());

drop policy if exists "cada um atualiza o seu" on public.equipe;
create policy "cada um atualiza o seu" on public.equipe
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Briefings: campos do painel ------------------------------------------------
alter table public.briefings
  add column if not exists origem        text not null default 'briefing',  -- 'briefing' ou 'manual'
  add column if not exists notas         text not null default '',
  add column if not exists prazo         date,
  add column if not exists atualizado_em timestamptz not null default now();

-- projetos cadastrados à mão não têm respostas do formulário
alter table public.briefings alter column resumo    set default '[]'::jsonb;
alter table public.briefings alter column respostas set default '{}'::jsonb;

create or replace function public.marca_atualizacao()
returns trigger language plpgsql as $$
begin new.atualizado_em := now(); return new; end $$;

drop trigger if exists briefings_atualizado on public.briefings;
create trigger briefings_atualizado before update on public.briefings
  for each row execute function public.marca_atualizacao();

-- Status, valores e datas do dashboard ----------------------------------------
-- novo → proposta → esboco → producao → entregue; parado e recusado a qualquer momento.
-- "Aceitou" = passou para esboço, produção, parado ou entregue.
alter table public.briefings drop constraint if exists briefings_status_check;
alter table public.briefings add constraint briefings_status_check
  check (status in ('novo', 'proposta', 'esboco', 'producao', 'parado', 'entregue', 'recusado'));

alter table public.briefings
  add column if not exists valor        numeric(12,2),            -- preço cobrado do cliente
  add column if not exists custo        numeric(12,2),            -- gastos do projeto (domínio, anúncios, terceiros)
  add column if not exists recebido     numeric(12,2) not null default 0,
  add column if not exists aceito_em    timestamptz,              -- quando o cliente fechou
  add column if not exists concluido_em timestamptz,              -- quando foi entregue
  add column if not exists recusado_em  timestamptz;

create or replace function public.marca_status()
returns trigger language plpgsql as $$
begin
  if new.status in ('esboco', 'producao', 'parado', 'entregue') then
    new.aceito_em := coalesce(new.aceito_em, now());
  elsif new.status in ('novo', 'proposta', 'recusado') then
    new.aceito_em := null;
  end if;
  new.concluido_em := case when new.status = 'entregue' then coalesce(new.concluido_em, now()) end;
  new.recusado_em  := case when new.status = 'recusado' then coalesce(new.recusado_em, now()) end;
  return new;
end $$;

drop trigger if exists briefings_status on public.briefings;
create trigger briefings_status before insert or update of status on public.briefings
  for each row execute function public.marca_status();

-- projetos que já estavam andando antes do dashboard
update public.briefings set aceito_em = atualizado_em
  where aceito_em is null and status in ('esboco', 'producao', 'parado', 'entregue');
update public.briefings set concluido_em = atualizado_em
  where concluido_em is null and status = 'entregue';

-- Acesso da equipe (substitui o acesso aberto a qualquer login do briefing.sql)
revoke all on public.briefings from authenticated;
grant select, insert, update, delete on public.briefings to authenticated;

drop policy if exists "equipe le briefings" on public.briefings;
drop policy if exists "equipe atualiza briefings" on public.briefings;
drop policy if exists "equipe cuida dos briefings" on public.briefings;
create policy "equipe cuida dos briefings" on public.briefings
  for all to authenticated using (public.is_equipe()) with check (public.is_equipe());

-- Tarefas --------------------------------------------------------------------
create table if not exists public.tarefas (
  id          uuid primary key default gen_random_uuid(),
  briefing_id uuid not null references public.briefings (id) on delete cascade,
  titulo      text not null,
  feita       boolean not null default false,
  ordem       integer not null default 0,
  criada_em   timestamptz not null default now()
);
create index if not exists tarefas_briefing on public.tarefas (briefing_id, ordem);

alter table public.tarefas enable row level security;
revoke all on public.tarefas from anon, authenticated;
grant select, insert, update, delete on public.tarefas to authenticated;

drop policy if exists "equipe cuida das tarefas" on public.tarefas;
create policy "equipe cuida das tarefas" on public.tarefas
  for all to authenticated using (public.is_equipe()) with check (public.is_equipe());

-- Fotos ----------------------------------------------------------------------
drop policy if exists "equipe ve fotos" on storage.objects;
create policy "equipe ve fotos" on storage.objects
  for select to authenticated
  using (bucket_id = 'briefings' and public.is_equipe());

drop policy if exists "equipe apaga fotos" on storage.objects;
create policy "equipe apaga fotos" on storage.objects
  for delete to authenticated
  using (bucket_id = 'briefings' and public.is_equipe());

-- Observações ----------------------------------------------------------------
-- Histórico do pedido: cada observação guarda quem escreveu e quando.
create table if not exists public.observacoes (
  id          uuid primary key default gen_random_uuid(),
  briefing_id uuid not null references public.briefings (id) on delete cascade,
  autor       uuid default auth.uid() references public.equipe (user_id) on delete set null,
  texto       text not null,
  criada_em   timestamptz not null default now()
);
create index if not exists observacoes_briefing on public.observacoes (briefing_id, criada_em);

alter table public.observacoes enable row level security;
revoke all on public.observacoes from anon, authenticated;
grant select, insert, update, delete on public.observacoes to authenticated;

drop policy if exists "equipe cuida das observacoes" on public.observacoes;
create policy "equipe cuida das observacoes" on public.observacoes
  for all to authenticated using (public.is_equipe()) with check (public.is_equipe());

-- Tabela de preços -------------------------------------------------------------
-- Preço de referência de cada serviço; o painel usa para sugerir o valor do pedido.
create table if not exists public.precos (
  servico   text primary key,
  valor     numeric(12,2) not null default 0,
  descricao text not null default '',
  ordem     integer not null default 0
);

insert into public.precos (servico, ordem) values
  ('Landing page', 0), ('Site', 1), ('Instagram', 2), ('Marca e logo', 3)
on conflict (servico) do nothing;

alter table public.precos enable row level security;
revoke all on public.precos from anon, authenticated;
grant select, insert, update, delete on public.precos to authenticated;

drop policy if exists "equipe cuida dos precos" on public.precos;
create policy "equipe cuida dos precos" on public.precos
  for all to authenticated using (public.is_equipe()) with check (public.is_equipe());

-- Prospecção -------------------------------------------------------------------
-- Negócios sem site ou com Instagram fraco que a equipe vai procurar.
-- a_contatar → contatado → respondeu → interessado → cliente; sem_interesse a qualquer momento.
create table if not exists public.leads (
  id           uuid primary key default gen_random_uuid(),
  nome         text not null,
  nicho        text not null default '',
  bairro       text not null default '',
  regiao       text not null default '',            -- agrupa bairros (ex.: Ouro Verde)
  telefone     text not null default '',
  whatsapp     text not null default '',
  instagram    text not null default '',
  site         text not null default '',             -- o que existe hoje (vazio = nenhum)
  motivo       text not null default '',
  fonte        text not null default '',
  status       text not null default 'a_contatar'
               check (status in ('a_contatar', 'contatado', 'respondeu', 'interessado', 'cliente', 'sem_interesse')),
  notas        text not null default '',
  contatado_em timestamptz,
  criado_por   uuid default auth.uid() references public.equipe (user_id) on delete set null,
  criado_em    timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
create unique index if not exists leads_nome_bairro on public.leads (lower(nome), lower(bairro));

create or replace function public.marca_lead()
returns trigger language plpgsql as $$
begin
  new.atualizado_em := now();
  if new.status = 'a_contatar' then new.contatado_em := null;
  else new.contatado_em := coalesce(new.contatado_em, now()); end if;
  return new;
end $$;

drop trigger if exists leads_marca on public.leads;
create trigger leads_marca before insert or update on public.leads
  for each row execute function public.marca_lead();

alter table public.leads enable row level security;
revoke all on public.leads from anon, authenticated;
grant select, insert, update, delete on public.leads to authenticated;

drop policy if exists "equipe cuida dos leads" on public.leads;
create policy "equipe cuida dos leads" on public.leads
  for all to authenticated using (public.is_equipe()) with check (public.is_equipe());

-- Primeira lista (03/11/2026), tirada de guias públicos. Rodar de novo não duplica.
insert into public.leads (nome, nicho, bairro, regiao, telefone, whatsapp, site, motivo, fonte) values
  ('Mecânica Senna', 'Oficina mecânica', 'Vila Aeroporto', 'Ouro Verde', '(19) 99878-5984', '(19) 99878-5984', '', 'Oficina sem site; só WhatsApp', 'benditoguia.com.br/empresa/mecanica-senna-jardim-ouro-verde-campinas-sp'),
  ('Sttudio Life', 'Salão de beleza', 'Jardim Alvorada (São Pedro de Viracopos)', 'Ouro Verde', '(19) 98427-6477', '(19) 98427-6477', '', 'Salão sem site; só WhatsApp', 'benditoguia.com.br/empresa/sttudio-life-jardim-sao-pedro-de-viracopos-campinas-sp'),
  ('Neiry Alves Barboza (barbearia)', 'Barbearia', 'Vida Nova', 'Ouro Verde', '(19) 3226-7682', '', '', 'Barbearia sem site nem WhatsApp listado', 'barbeariaspertodemim.com/e/neiry-alves-barboza-aoowrw/'),
  ('Camarim Estética', 'Estética', 'Ouro Verde', 'Ouro Verde', '', '', '', 'Estética no Ouro Verde; telefone não saiu no guia, achar no Google Maps', 'solutudo.com.br (Camarim Estetica Ouro Verde)'),
  ('Estética Lourdes Sena', 'Estética', 'Cambuí', 'Centro', '(19) 98321-2568', '(19) 98321-2568', '', 'Estética no Cambuí sem site', 'benditoguia.com.br/empresa/estetica-lourdes-sena-centro-campinas-sp'),
  ('Sofisticatto Cabelos', 'Salão de beleza', 'Cambuí', 'Centro', '(19) 99261-8740', '(19) 99261-8740', '', 'Salão no Cambuí só com WhatsApp', 'benditoguia.com.br/empresa/sofisticatto-cabelos-cambui-campinas-sp'),
  ('Estética Suzane Sousa', 'Estética', 'Taquaral', 'Taquaral', '(19) 99593-6688', '(19) 99593-6688', '', 'Estética sem site', 'benditoguia.com.br/empresa/estetica-suzane-sousa-campinas-vila-costa-e-silva-sp'),
  ('Gabi Gonçalves Designer de Sobrancelhas', 'Sobrancelhas', 'Taquaral', 'Taquaral', '(19) 98715-7108', '(19) 98715-7108', '', 'Autônoma; landing simples + Instagram com antes/depois', 'benditoguia.com.br/empresa/gabi-goncalves-designer-de-sobrancelhas-campinas-sp-taquaral'),
  ('Studio Viviane Mendes', 'Salão de beleza', 'Parque Jambeiro', 'Sul', '(19) 99228-6295', '(19) 99228-6295', 'negocio.site, fora do ar', 'Site grátis do Google saiu do ar em 2024; link quebrado', 'benditoguia.com.br/empresa/studio-viviane-mendes-parque-jambeiro-campinas-sp'),
  ('Studio Parrado Centro de Beleza', 'Salão de beleza', 'Parque Industrial', 'Sul', '(19) 98191-8057', '(19) 98191-8057', '', 'Centro de beleza sem site', 'benditoguia.com.br/empresa/studio-parrado-centro-de-beleza-parque-industrial-campinas'),
  ('Harmony Beauty', 'Salão de beleza', 'Jardim Monte Cristo', 'Sudoeste', '(19) 99558-3042', '(19) 99558-3042', '', 'Salão sem site', 'benditoguia.com.br/empresa/harmony-beauty-jardim-monte-cristo-campinas'),
  ('RN Cabelos', 'Salão de beleza', 'Jardim Santa Eudóxia', 'Sul', '(19) 98713-0366', '(19) 98713-0366', '', 'Salão sem site', 'benditoguia.com.br/empresa/rn-cabelos-jardim-santa-eudoxia-campinas-sp'),
  ('Ateliê da Beleza', 'Manicure', 'Santa Genebra', 'Barão Geraldo', '(19) 98283-5476', '(19) 98283-5476', '', 'Manicure sem site', 'benditoguia.com.br/empresa/atelie-da-beleza-jardim-santa-genebra-campinas-sp'),
  ('Casa das Rações São Vicente', 'Pet shop', 'Jardim São Vicente', 'Leste', '(19) 99304-2111', '(19) 99304-2111', '', 'Pet shop de bairro; catálogo + pedido por WhatsApp', 'benditoguia.com.br/empresa/casa-das-racoes-sao-vicente-jardim-campinas-sp'),
  ('Pet Boy Shop Banho e Tosa', 'Pet shop', 'Jardim do Lago', 'Sudoeste', '(19) 3518-0333', '', '', 'Banho e tosa sem site', 'benditoguia.com.br/empresa/pet-boy-shop-banho-e-tosa-jardim-do-lago-campinas-sp'),
  ('Dogs and Cats', 'Pet shop', 'Jardim Proença', 'Leste', '(19) 3251-8780', '', '', 'Pet shop sem site', 'benditoguia.com.br/empresa/dogs-and-cats-vila-lemos-campinas-sp'),
  ('Mecânica Classe A', 'Oficina mecânica', 'Botafogo', 'Centro', '(19) 99324-3414', '(19) 99324-3414', '', 'Oficina sem site; landing com orçamento no WhatsApp', 'benditoguia.com.br/empresa/mecanica-classe-a-botafogo-campinas'),
  ('Ziner Moto Peças e Oficina', 'Oficina de motos', 'Sousas', 'Sousas', '(19) 3258-3577', '', '', 'Oficina de moto sem site', 'benditoguia.com.br/empresa/ziner-moto-pecas-e-oficina-sousas-campinas-sp'),
  ('StopMar Auto Center', 'Oficina mecânica', 'Cidade Satélite Íris', 'Noroeste', '(19) 3229-3215', '', 'só página de diretório', 'O "site" é página de diretório, não próprio', 'benditoguia.com.br/empresa/stopmar-auto-center-cidade-satelite-iris-campinas-sp')
on conflict do nothing;
