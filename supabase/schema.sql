-- =====================================================================
-- Mon Hub en ligne (Supabase)
--
-- À coller UNE fois : supabase.com → ton projet → SQL Editor → New query
-- → coller tout ce fichier → Run. On peut le relancer sans risque (il ne
-- casse rien de ce qui existe déjà).
--
-- Ce que la base garde :
--   * profiles       : ton nom affiché et ton pseudo (@pseudo) ;
--   * spaces         : les espaces partagés (et les conversations privées) ;
--   * space_members  : qui est dans quel espace ;
--   * tasks          : le tableau de tâches de chaque espace ;
--   * messages       : la discussion de chaque espace (et de Clicky) ;
--   * account_files  : la copie CHIFFRÉE de ton compte Mon Hub (réglages,
--                      modules, connexions…) pour le retrouver sur tous tes
--                      appareils. Elle est chiffrée sur ton appareil avec
--                      ton mot de passe (AES-256-GCM) : la base ne peut pas
--                      la lire.
--
-- Tes données perso (notes, révisions, ce que Clicky voit à l'écran…) ne
-- passent JAMAIS en clair par ici.
--
-- Sécurité : chaque table est protégée (Row Level Security). On ne voit
-- que les espaces dont on est membre, et seulement sa propre copie.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------- Tables

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  name text not null default '' check (char_length(name) <= 60),
  handle text unique check (handle ~ '^[a-z0-9._-]{3,30}$'),
  created_at timestamptz not null default now()
);

create table if not exists public.spaces (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 60),
  kind text not null default 'space' check (kind in ('space', 'dm')),
  color text not null default '#7C5CFF' check (color ~ '^#[0-9A-Fa-f]{6}$'),
  owner uuid not null default auth.uid() references auth.users(id) on delete cascade,
  invite_code text unique default encode(gen_random_bytes(5), 'hex'),
  clicky_chat boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists public.space_members (
  space_id uuid not null references public.spaces(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'member' check (role in ('owner', 'member')),
  joined_at timestamptz not null default now(),
  primary key (space_id, user_id)
);

create table if not exists public.tasks (
  id uuid primary key default gen_random_uuid(),
  space_id uuid not null references public.spaces(id) on delete cascade,
  title text not null check (char_length(title) between 1 and 200),
  notes text not null default '' check (char_length(notes) <= 4000),
  status text not null default 'todo' check (status in ('todo', 'doing', 'review', 'done')),
  tag text not null default '' check (char_length(tag) <= 30),
  assignee uuid references auth.users(id) on delete set null,
  due date,
  position double precision not null default extract(epoch from now()),
  created_by uuid not null default auth.uid() references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists tasks_space_idx on public.tasks(space_id);

create table if not exists public.messages (
  id bigint generated always as identity primary key,
  space_id uuid not null references public.spaces(id) on delete cascade,
  author uuid not null default auth.uid() references auth.users(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 4000),
  from_clicky boolean not null default false,
  depth int not null default 0 check (depth between 0 and 10),
  reply_to bigint references public.messages(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists messages_space_idx on public.messages(space_id, id desc);

create table if not exists public.account_files (
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name text not null check (name ~ '^[A-Za-z0-9._-]{1,80}$'),
  content text not null check (char_length(content) <= 30000000),
  version bigint not null default 1,
  updated_at timestamptz not null default now(),
  primary key (user_id, name)
);

-- ------------------------------------------------------------- Fonctions

-- Suis-je membre de cet espace ? (security definer : évite que les règles
-- se rappellent elles-mêmes en boucle.)
create or replace function public.is_member(s uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from space_members where space_id = s and user_id = auth.uid());
$$;

-- Partage-t-on au moins un espace ? (pour voir le nom de l'autre)
create or replace function public.shares_space(other uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from space_members a join space_members b on a.space_id = b.space_id
    where a.user_id = auth.uid() and b.user_id = other
  );
$$;

create or replace function public.touch_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end $$;

create or replace function public.bump_version() returns trigger
language plpgsql as $$
begin
  new.version = old.version + 1;
  new.updated_at = now();
  return new;
end $$;

drop trigger if exists tasks_touch on public.tasks;
create trigger tasks_touch before update on public.tasks
  for each row execute function public.touch_updated_at();

drop trigger if exists account_files_bump on public.account_files;
create trigger account_files_bump before update on public.account_files
  for each row execute function public.bump_version();

-- Un profil vide est créé pour chaque nouveau compte.
create or replace function public.new_profile() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id, name) values (new.id, coalesce(new.raw_user_meta_data ->> 'name', ''))
  on conflict do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.new_profile();

-- Créer un espace (et en devenir le propriétaire).
create or replace function public.create_space(p_name text, p_color text default '#7C5CFF')
returns public.spaces
language plpgsql security definer set search_path = public as $$
declare s spaces;
begin
  if auth.uid() is null then raise exception 'connexion requise'; end if;
  insert into spaces (name, color, owner) values (trim(p_name), coalesce(p_color, '#7C5CFF'), auth.uid())
  returning * into s;
  insert into space_members (space_id, user_id, role) values (s.id, auth.uid(), 'owner');
  return s;
end $$;

-- Rejoindre un espace avec son code d'invitation.
create or replace function public.join_space(p_code text)
returns public.spaces
language plpgsql security definer set search_path = public as $$
declare s spaces;
begin
  if auth.uid() is null then raise exception 'connexion requise'; end if;
  select * into s from spaces where invite_code = lower(trim(p_code)) and kind = 'space';
  if s.id is null then raise exception 'code inconnu'; end if;
  insert into space_members (space_id, user_id) values (s.id, auth.uid()) on conflict do nothing;
  return s;
end $$;

-- Ouvrir (ou retrouver) une conversation privée avec @pseudo.
create or replace function public.open_dm(p_handle text)
returns public.spaces
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  other uuid;
  s spaces;
begin
  if me is null then raise exception 'connexion requise'; end if;
  select id into other from profiles where handle = lower(trim(both '@ ' from p_handle));
  if other is null then raise exception 'personne introuvable'; end if;
  if other = me then raise exception 'c''est toi'; end if;
  select sp.* into s from spaces sp
  where sp.kind = 'dm'
    and exists (select 1 from space_members m where m.space_id = sp.id and m.user_id = me)
    and exists (select 1 from space_members m where m.space_id = sp.id and m.user_id = other)
  limit 1;
  if s.id is null then
    insert into spaces (name, kind, owner, invite_code) values ('Discussion', 'dm', me, null) returning * into s;
    insert into space_members (space_id, user_id, role) values (s.id, me, 'owner'), (s.id, other, 'member');
  end if;
  return s;
end $$;

-- Nouveau code d'invitation (l'ancien ne marche plus). Propriétaire seulement.
create or replace function public.new_invite_code(p_space uuid)
returns text
language plpgsql security definer set search_path = public as $$
declare c text;
begin
  update spaces set invite_code = encode(gen_random_bytes(5), 'hex')
  where id = p_space and owner = auth.uid() and kind = 'space'
  returning invite_code into c;
  if c is null then raise exception 'seul le propriétaire peut faire ça'; end if;
  return c;
end $$;

revoke execute on function public.create_space(text, text) from public, anon;
revoke execute on function public.join_space(text) from public, anon;
revoke execute on function public.open_dm(text) from public, anon;
revoke execute on function public.new_invite_code(uuid) from public, anon;
grant execute on function public.create_space(text, text) to authenticated;
grant execute on function public.join_space(text) to authenticated;
grant execute on function public.open_dm(text) to authenticated;
grant execute on function public.new_invite_code(uuid) to authenticated;

-- ---------------------------------------------------- Règles d'accès (RLS)

alter table public.profiles enable row level security;
alter table public.spaces enable row level security;
alter table public.space_members enable row level security;
alter table public.tasks enable row level security;
alter table public.messages enable row level security;
alter table public.account_files enable row level security;

drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select
  using (id = auth.uid() or public.shares_space(id));
drop policy if exists profiles_insert on public.profiles;
create policy profiles_insert on public.profiles for insert with check (id = auth.uid());
drop policy if exists profiles_update on public.profiles;
create policy profiles_update on public.profiles for update
  using (id = auth.uid()) with check (id = auth.uid());

-- Espaces : créés par create_space / open_dm (pas d'ajout direct).
drop policy if exists spaces_select on public.spaces;
create policy spaces_select on public.spaces for select using (public.is_member(id));
drop policy if exists spaces_update on public.spaces;
create policy spaces_update on public.spaces for update
  using (owner = auth.uid()) with check (owner = auth.uid());
drop policy if exists spaces_delete on public.spaces;
create policy spaces_delete on public.spaces for delete using (owner = auth.uid());

-- Membres : ajoutés par create_space / join_space / open_dm. On peut
-- quitter un espace ; le propriétaire peut retirer quelqu'un.
drop policy if exists members_select on public.space_members;
create policy members_select on public.space_members for select using (public.is_member(space_id));
drop policy if exists members_delete on public.space_members;
create policy members_delete on public.space_members for delete
  using (
    user_id = auth.uid()
    or exists (select 1 from public.spaces s where s.id = space_id and s.owner = auth.uid())
  );

drop policy if exists tasks_select on public.tasks;
create policy tasks_select on public.tasks for select using (public.is_member(space_id));
drop policy if exists tasks_insert on public.tasks;
create policy tasks_insert on public.tasks for insert
  with check (
    public.is_member(space_id) and created_by = auth.uid()
    and (assignee is null or exists (
      select 1 from public.space_members m where m.space_id = tasks.space_id and m.user_id = tasks.assignee))
  );
drop policy if exists tasks_update on public.tasks;
create policy tasks_update on public.tasks for update
  using (public.is_member(space_id))
  with check (
    public.is_member(space_id)
    and (assignee is null or exists (
      select 1 from public.space_members m where m.space_id = tasks.space_id and m.user_id = tasks.assignee))
  );
drop policy if exists tasks_delete on public.tasks;
create policy tasks_delete on public.tasks for delete using (public.is_member(space_id));

drop policy if exists messages_select on public.messages;
create policy messages_select on public.messages for select using (public.is_member(space_id));
drop policy if exists messages_insert on public.messages;
create policy messages_insert on public.messages for insert
  with check (public.is_member(space_id) and author = auth.uid());
drop policy if exists messages_delete on public.messages;
create policy messages_delete on public.messages for delete using (author = auth.uid());

drop policy if exists account_files_own on public.account_files;
create policy account_files_own on public.account_files for all
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- -------------------------------------------------------------- Temps réel
-- Les messages et les tâches arrivent tout seuls (les règles ci-dessus
-- s'appliquent aussi au temps réel).
do $$
begin
  begin
    alter publication supabase_realtime add table public.messages;
  exception when duplicate_object then null;
  end;
  begin
    alter publication supabase_realtime add table public.tasks;
  exception when duplicate_object then null;
  end;
  begin
    alter publication supabase_realtime add table public.space_members;
  exception when duplicate_object then null;
  end;
end $$;
