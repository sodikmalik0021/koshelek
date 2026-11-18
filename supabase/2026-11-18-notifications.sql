-- Общий кошелёк: уведомления, push, напоминания, фото чека, история целей.
-- Выполнить один раз: Supabase → SQL Editor → вставить весь файл → Run.

create table if not exists koshelek.notifications (
  id bigserial primary key,
  member_id uuid not null references koshelek.members(id) on delete cascade,
  kind text not null, title text not null, body text not null default '', tab text not null default 'home',
  created_at timestamptz not null default now(), read_at timestamptz);
create index if not exists notifications_member_idx on koshelek.notifications (member_id, id desc);
alter table koshelek.notifications enable row level security;

create table if not exists koshelek.push_subs (
  id bigserial primary key,
  member_id uuid not null references koshelek.members(id) on delete cascade,
  endpoint text not null unique, p256dh text not null, auth text not null,
  created_at timestamptz not null default now());
alter table koshelek.push_subs enable row level security;

alter table koshelek.config add column if not exists push_secret text not null default encode(extensions.gen_random_bytes(24), 'hex');
alter table koshelek.contributions add column if not exists receipt text;
alter table koshelek.goals add column if not exists reached boolean;

create or replace function koshelek.notify(p_member uuid, p_kind text, p_title text, p_body text, p_tab text default 'home')
returns void language plpgsql security definer set search_path to '' as $$
declare nid bigint;
begin
  if p_member is null then return; end if;
  insert into koshelek.notifications (member_id, kind, title, body, tab)
  values (p_member, p_kind, left(p_title, 140), left(coalesce(p_body, ''), 240), coalesce(p_tab, 'home'))
  returning id into nid;
  delete from koshelek.notifications n where n.member_id = p_member
    and n.id < (select min(x.id) from (select id from koshelek.notifications where member_id = p_member order by id desc limit 100) x);
  if exists (select 1 from koshelek.push_subs where member_id = p_member) then
    perform net.http_post(
      url := 'https://pdzflfmjtawmfbdxqozu.supabase.co/functions/v1/wallet-push',
      headers := jsonb_build_object('Content-Type', 'application/json',
                   'x-push-secret', (select push_secret from koshelek.config where id = 1)),
      body := jsonb_build_object('id', nid));
  end if;
end $$;

create or replace function koshelek.notify_others(p_except uuid, p_kind text, p_title text, p_body text, p_tab text default 'home', p_admins_only boolean default false)
returns void language plpgsql security definer set search_path to '' as $$
declare r record;
begin
  for r in select id from koshelek.members where status = 'active' and id is distinct from p_except loop
    if not p_admins_only or koshelek.is_admin(r.id) then
      perform koshelek.notify(r.id, p_kind, p_title, p_body, p_tab);
    end if;
  end loop;
end $$;

-- сколько участник ещё должен за все недели до текущей включительно
create or replace function koshelek.remaining(p_member uuid)
returns bigint language plpgsql stable security definer set search_path to '' as $$
declare cfg koshelek.config; t date := koshelek.today(); first date; cur date; weeks int; marked int; paid bigint;
begin
  select * into cfg from koshelek.config where id = 1;
  if not cfg.setup_done or cfg.start_date is null then return 0; end if;
  first := cfg.start_date + ((6 - extract(dow from cfg.start_date)::int + 7) % 7);
  cur := t + ((6 - extract(dow from t)::int + 7) % 7);
  if cur < first then return 0; end if;
  weeks := (cur - first) / 7 + 1;
  select count(*) into marked from koshelek.week_marks where member_id = p_member and deadline between first and cur;
  select coalesce(sum(amount), 0) into paid from koshelek.contributions
   where member_id = p_member and status = 'approved' and transfer_date <= t;
  return greatest(0, cfg.weekly_amount::bigint * (weeks - marked) - paid);
end $$;

create or replace function koshelek.trg_contribution() returns trigger language plpgsql security definer set search_path to '' as $$
declare nm text := koshelek.name_of(new.member_id);
begin
  if tg_op = 'INSERT' then
    if new.status = 'approved' and new.reviewed_by = new.member_id then
      perform koshelek.notify_others(new.member_id, 'contribution', nm || ' внёс(ла) ' || koshelek.kgs(new.amount),
        coalesce(new.note, 'Баланс кошелька обновлён'), 'payments');
    elsif new.status = 'approved' then
      perform koshelek.notify(new.member_id, 'contribution', koshelek.name_of(new.reviewed_by) || ' записал(а) ваш платёж ' || koshelek.kgs(new.amount),
        'Баланс кошелька обновлён', 'payments');
    elsif new.status = 'pending' then
      perform koshelek.notify_others(new.member_id, 'review', nm || ' перевёл(а) ' || koshelek.kgs(new.amount), 'Проверьте поступление в Simbank', 'payments',
        koshelek.role_of(new.member_id) <> 'main_admin');
    end if;
  elsif old.status = 'pending' and new.status <> 'pending' then
    perform koshelek.notify(new.member_id, 'review',
      case when new.status = 'approved' then 'Ваш платёж подтверждён' else 'Ваш платёж отклонён' end,
      koshelek.kgs(new.amount) || coalesce(' — ' || new.review_note, ''), 'payments');
  end if;
  return null;
end $$;
create or replace trigger contribution_notify after insert or update of status on koshelek.contributions
  for each row execute function koshelek.trg_contribution();

create or replace function koshelek.trg_expense() returns trigger language plpgsql security definer set search_path to '' as $$
declare nm text := koshelek.name_of(new.requested_by);
begin
  if tg_op = 'INSERT' then
    if new.status = 'voting' then
      perform koshelek.notify_others(new.requested_by, 'vote', nm || ' просит ' || koshelek.kgs(new.amount), new.description || ' — проголосуйте', 'home');
    elsif new.status = 'paid' then
      perform koshelek.notify_others(new.requested_by, 'expense', nm || ' потратил(а) ' || koshelek.kgs(new.amount), new.description, 'history');
    end if;
  elsif old.status is distinct from new.status then
    if new.status = 'approved' then
      perform koshelek.notify(new.requested_by, 'vote', 'Ваш запрос одобрен', new.description || ' — ' || koshelek.kgs(new.amount) || '. Оплатите через Simbank.', 'expenses');
      perform koshelek.notify_others(new.requested_by, 'pay', 'Отметьте оплату: ' || koshelek.kgs(new.amount), new.description, 'expenses', true);
    elsif new.status = 'rejected' then
      perform koshelek.notify(new.requested_by, 'vote', 'Ваш запрос отклонён', new.description || ' — ' || koshelek.kgs(new.amount), 'expenses');
    elsif new.status = 'paid' and old.status = 'approved' then
      perform koshelek.notify(new.requested_by, 'expense', 'Расход отмечен оплаченным', new.description || ' — ' || koshelek.kgs(new.amount), 'expenses');
    end if;
  end if;
  return null;
end $$;
create or replace trigger expense_notify after insert or update of status on koshelek.expenses
  for each row execute function koshelek.trg_expense();

create or replace function koshelek.trg_message() returns trigger language plpgsql security definer set search_path to '' as $$
declare r record; f text; b text := lower(new.body); nm text := koshelek.name_of(new.member_id);
begin
  for r in select id, name from koshelek.members where status = 'active' and id <> new.member_id loop
    f := lower(split_part(btrim(r.name), ' ', 1));
    if f <> '' and position('@' || f in b) > 0 then
      perform koshelek.notify(r.id, 'mention', nm || ' упомянул(а) вас в чате', left(new.body, 160), 'chat');
    end if;
  end loop;
  return null;
end $$;
create or replace trigger message_notify after insert on koshelek.messages
  for each row execute function koshelek.trg_message();

create or replace function koshelek.trg_member() returns trigger language plpgsql security definer set search_path to '' as $$
begin
  if tg_op = 'INSERT' and new.status = 'pending' then
    perform koshelek.notify((select main_admin_id from koshelek.config where id = 1), 'member', 'Новая заявка: ' || new.name, 'Примите или отклоните в разделе «Ещё»', 'more');
  elsif tg_op = 'UPDATE' and old.status = 'pending' and new.status = 'active' then
    perform koshelek.notify(new.id, 'member', 'Вас приняли в кошелёк 🎉', 'Добро пожаловать!', 'home');
  end if;
  return null;
end $$;
create or replace trigger member_notify after insert or update of status on koshelek.members
  for each row execute function koshelek.trg_member();

create or replace function koshelek.weekly_remind(p_kind text) returns void language plpgsql security definer set search_path to '' as $$
declare r record; rem bigint;
begin
  if not coalesce((select setup_done from koshelek.config where id = 1), false) then return; end if;
  for r in select id from koshelek.members where status = 'active' loop
    rem := koshelek.remaining(r.id);
    if rem > 0 then
      perform koshelek.notify(r.id, 'remind',
        case when p_kind = 'sat' then 'Сегодня последний день взноса' else 'Завтра срок взноса' end,
        'Внесите ' || koshelek.kgs(rem) || ' в общий кошелёк', 'payments');
    end if;
  end loop;
end $$;

create or replace function public.wallet_read_notifications(p_token text) returns void
language plpgsql security definer set search_path to '' as $$
declare me koshelek.members;
begin
  me := koshelek.active(p_token);
  update koshelek.notifications set read_at = now() where member_id = me.id and read_at is null;
end $$;

create or replace function public.wallet_vapid_public() returns text
language sql stable security definer set search_path to '' as $$
  select value from public.zk_config where key = 'vapid_public'
$$;

create or replace function public.wallet_push_subscribe(p_token text, p_endpoint text, p_p256dh text, p_auth text) returns void
language plpgsql security definer set search_path to '' as $$
declare me koshelek.members;
begin
  me := koshelek.active(p_token);
  if p_endpoint is null or p_endpoint !~ '^https://' or length(p_endpoint) > 1000
     or coalesce(length(p_p256dh), 0) not between 20 and 200 or coalesce(length(p_auth), 0) not between 8 and 100 then
    raise exception 'Не удалось включить уведомления.';
  end if;
  insert into koshelek.push_subs (member_id, endpoint, p256dh, auth) values (me.id, p_endpoint, p_p256dh, p_auth)
  on conflict (endpoint) do update set member_id = excluded.member_id, p256dh = excluded.p256dh, auth = excluded.auth, created_at = now();
  delete from koshelek.push_subs s where s.member_id = me.id
    and s.id not in (select id from koshelek.push_subs where member_id = me.id order by created_at desc limit 5);
end $$;

create or replace function public.wallet_push_unsubscribe(p_token text, p_endpoint text) returns void
language plpgsql security definer set search_path to '' as $$
declare me koshelek.members;
begin
  me := koshelek.auth(p_token);
  delete from koshelek.push_subs where endpoint = p_endpoint and member_id = me.id;
end $$;

create or replace function public.wallet_push_job(p_secret text, p_id bigint) returns jsonb
language plpgsql security definer set search_path to '' as $$
declare n koshelek.notifications;
begin
  if p_secret is null or p_secret <> (select push_secret from koshelek.config where id = 1) then raise exception 'forbidden'; end if;
  select * into n from koshelek.notifications where id = p_id;
  if not found then return null; end if;
  return jsonb_build_object('title', n.title, 'body', n.body, 'tab', n.tab, 'kind', n.kind, 'id', n.id,
    'subs', (select coalesce(jsonb_agg(jsonb_build_object('endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth)), '[]'::jsonb)
             from koshelek.push_subs s where s.member_id = n.member_id));
end $$;

create or replace function public.wallet_push_drop(p_secret text, p_endpoint text) returns void
language plpgsql security definer set search_path to '' as $$
begin
  if p_secret is null or p_secret <> (select push_secret from koshelek.config where id = 1) then raise exception 'forbidden'; end if;
  delete from koshelek.push_subs where endpoint = p_endpoint;
end $$;

create or replace function public.wallet_remind(p_token text, p_member uuid) returns void
language plpgsql security definer set search_path to '' as $$
declare me koshelek.members; t koshelek.members; rem bigint;
begin
  me := koshelek.active(p_token);
  perform koshelek.require_setup();
  select * into t from koshelek.members where id = p_member and status = 'active';
  if not found or t.id = me.id then raise exception 'Выберите другого участника.'; end if;
  rem := koshelek.remaining(t.id);
  if rem <= 0 then raise exception '% уже всё оплатил(а).', t.name; end if;
  if exists (select 1 from koshelek.notifications where member_id = t.id and kind = 'remind_manual' and created_at > now() - interval '6 hours') then
    raise exception 'Недавно уже напоминали. Попробуйте позже.';
  end if;
  perform koshelek.notify(t.id, 'remind_manual', me.name || ' напоминает о взносе', 'К оплате: ' || koshelek.kgs(rem) || ' 🙏', 'payments');
  insert into koshelek.messages (member_id, body) values (me.id, 'Напомнил(а) ' || t.name || ' про взнос ' || koshelek.kgs(rem) || ' 🙏');
end $$;

create or replace function public.wallet_receipt(p_token text, p_id bigint) returns text
language plpgsql security definer set search_path to '' as $$
declare me koshelek.members;
begin
  me := koshelek.active(p_token);
  return (select receipt from koshelek.contributions where id = p_id);
end $$;

-- новая версия «внести взнос» с фото чека (старая остаётся для совместимости)
create or replace function public.wallet_submit_contribution2(p_token text, p_amount bigint, p_transfer_date date, p_note text default null, p_receipt text default null)
returns void language plpgsql security definer set search_path to '' as $$
declare me koshelek.members; n text := nullif(btrim(coalesce(p_note, '')), ''); rc text := nullif(btrim(coalesce(p_receipt, '')), '');
begin
  me := koshelek.active(p_token);
  perform koshelek.require_setup();
  if p_amount is null or p_amount < 1 or p_amount > 1000000 then raise exception 'Введите сумму от 1 до 1 000 000 сом.'; end if;
  if p_transfer_date is null or p_transfer_date > koshelek.today() then raise exception 'Дата перевода не может быть в будущем.'; end if;
  if n is not null and length(n) > 120 then raise exception 'Заметка слишком длинная (максимум 120 букв).'; end if;
  if rc is not null then
    if length(rc) > 400000 then raise exception 'Фото чека слишком большое.'; end if;
    if rc !~ '^data:image/jpeg;base64,[A-Za-z0-9+/=]+$' then raise exception 'Неверный формат фото чека.'; end if;
  end if;
  insert into koshelek.contributions (member_id, amount, transfer_date, note, status, reviewed_by, reviewed_at, receipt)
  values (me.id, p_amount, p_transfer_date, n, 'approved', me.id, now(), rc);
  perform koshelek.add_log(me.id, 'contribution_submitted', me.name || ' внёс(ла) на карту ' || koshelek.kgs(p_amount)
    || ' (дата перевода ' || to_char(p_transfer_date, 'YYYY-MM-DD') || ')' || case when rc is not null then ' · с чеком' else '' end);
end $$;

create or replace function public.wallet_set_goal(p_token text, p_title text, p_target bigint) returns void
language plpgsql security definer set search_path to '' as $$
declare me koshelek.members; t text := btrim(coalesce(p_title, ''));
begin
  me := koshelek.active(p_token);
  if not koshelek.is_admin(me.id) then raise exception 'Цель может менять только администратор.'; end if;
  if t = '' then raise exception 'Напишите, на что копите.'; end if;
  if length(t) > 40 then raise exception 'Название слишком длинное (максимум 40 букв).'; end if;
  if p_target is null or p_target < 1000 or p_target > 100000000 then raise exception 'Сумма цели: от 1 000 до 100 000 000 сом.'; end if;
  update koshelek.goals set archived_at = now(), reached = (koshelek.balance() >= target) where archived_at is null;
  insert into koshelek.goals (title, target, created_by) values (t, p_target, me.id);
  perform koshelek.add_log(me.id, 'goal_set', koshelek.name_of(me.id) || ' поставил(а) цель «' || t || '»: ' || koshelek.kgs(p_target));
  perform koshelek.notify_others(me.id, 'goal', 'Новая цель: ' || t, 'Копим ' || koshelek.kgs(p_target), 'home');
end $$;

create or replace function public.wallet_delete_goal(p_token text) returns void
language plpgsql security definer set search_path to '' as $$
declare me koshelek.members;
begin
  me := koshelek.active(p_token);
  if not koshelek.is_admin(me.id) then raise exception 'Цель может менять только администратор.'; end if;
  update koshelek.goals set archived_at = now(), reached = (koshelek.balance() >= target) where archived_at is null;
  perform koshelek.add_log(me.id, 'goal_removed', koshelek.name_of(me.id) || ' убрал(а) цель');
end $$;

create or replace function public.wallet_state(p_token text) returns jsonb
language plpgsql security definer set search_path to '' set "TimeZone" to 'UTC' as $$
declare m koshelek.members; cfg koshelek.config; r text;
begin
  m := koshelek.auth(p_token);
  select * into cfg from koshelek.config where id = 1;
  r := koshelek.role_of(m.id);
  if m.status <> 'active' then
    return jsonb_build_object('me', jsonb_build_object('id', m.id, 'name', m.name, 'login', m.login, 'status', m.status));
  end if;
  return jsonb_build_object(
    'me', jsonb_build_object('id', m.id, 'name', m.name, 'login', m.login, 'status', m.status, 'role', r),
    'profiles', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'full_name', x.name, 'login', x.login,
                   'role', koshelek.role_of(x.id), 'avatar', x.avatar) order by x.created_at), '[]'::jsonb)
                 from koshelek.members x where x.status = 'active'),
    'pending', case when r = 'main_admin' then
                 (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'name', x.name, 'login', x.login, 'created_at', x.created_at) order by x.created_at), '[]'::jsonb)
                  from koshelek.members x where x.status = 'pending') else '[]'::jsonb end,
    'settings', jsonb_build_object('weekly_amount', cfg.weekly_amount, 'start_date', cfg.start_date,
                  'opening_balance', cfg.opening_balance, 'setup_done', cfg.setup_done,
                  'main_admin_id', cfg.main_admin_id, 'support_phone', cfg.support_phone),
    'goal', (select to_jsonb(g) from koshelek.goals g where g.archived_at is null order by g.id desc limit 1),
    'goals_history', (select coalesce(jsonb_agg(jsonb_build_object('id', g.id, 'title', g.title, 'target', g.target, 'reached', g.reached,
                       'created_at', g.created_at, 'archived_at', g.archived_at) order by g.id desc), '[]'::jsonb)
                      from (select * from koshelek.goals where archived_at is not null order by id desc limit 20) g),
    'contributions', (select coalesce(jsonb_agg((to_jsonb(c) - 'receipt') || jsonb_build_object('has_receipt', c.receipt is not null) order by c.id), '[]'::jsonb) from koshelek.contributions c),
    'expenses', (select coalesce(jsonb_agg(to_jsonb(e) order by e.id), '[]'::jsonb) from koshelek.expenses e),
    'votes', (select coalesce(jsonb_agg(to_jsonb(v) order by v.created_at), '[]'::jsonb) from koshelek.votes v),
    'week_marks', (select coalesce(jsonb_agg(jsonb_build_object('member_id', w.member_id, 'deadline', w.deadline) order by w.deadline), '[]'::jsonb) from koshelek.week_marks w),
    'log', (select coalesce(jsonb_agg(to_jsonb(l) order by l.id desc), '[]'::jsonb) from (select * from koshelek.log order by id desc limit 500) l),
    'notifications', (select coalesce(jsonb_agg(jsonb_build_object('id', n.id, 'kind', n.kind, 'title', n.title, 'body', n.body, 'tab', n.tab,
                       'created_at', n.created_at, 'read', n.read_at is not null) order by n.id desc), '[]'::jsonb)
                      from (select * from koshelek.notifications where member_id = m.id order by id desc limit 40) n),
    'chat_version', koshelek.chat_version()
  );
end $$;

-- напоминания (Бишкек = UTC+6): пятница 18:00 и суббота 12:00
select cron.schedule('wallet-remind-fri', '0 12 * * 5', $c$select koshelek.weekly_remind('fri')$c$);
select cron.schedule('wallet-remind-sat', '0 6 * * 6', $c$select koshelek.weekly_remind('sat')$c$);
