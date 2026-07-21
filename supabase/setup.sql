-- LinguaFlow — облачная база и круглосуточная автоматизация.
-- Выполнить один раз в Supabase SQL Editor от роли postgres.

create extension if not exists pgcrypto;
create extension if not exists pg_cron with schema pg_catalog;

create table public.school_settings (
  id boolean primary key default true check (id),
  school_name text not null default 'LinguaFlow English School',
  timezone text not null default 'Europe/Kyiv',
  auto_complete_minutes integer not null default 30 check (auto_complete_minutes between 0 and 1440),
  updated_at timestamptz not null default now()
);

insert into public.school_settings (id) values (true)
on conflict (id) do nothing;

create table public.teachers (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  color text not null default '#6755e7',
  created_at timestamptz not null default now()
);

create table public.students (
  id uuid primary key default gen_random_uuid(),
  first_name text not null,
  last_name text not null,
  format text not null check (format in ('individual','pair','group')),
  teacher_id uuid references public.teachers(id) on delete set null,
  contact text,
  note text,
  created_at timestamptz not null default now()
);

create table public.student_schedule_slots (
  student_id uuid references public.students(id) on delete cascade,
  weekday smallint not null check (weekday between 0 and 6),
  lesson_time time not null,
  primary key (student_id, weekday)
);

create table public.lesson_groups (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  type text not null check (type in ('pair','group')),
  teacher_id uuid references public.teachers(id) on delete set null,
  created_at timestamptz not null default now()
);

create table public.group_members (
  group_id uuid references public.lesson_groups(id) on delete cascade,
  student_id uuid references public.students(id) on delete cascade,
  primary key (group_id, student_id)
);

create table public.subscriptions (
  id uuid primary key default gen_random_uuid(),
  student_id uuid not null references public.students(id) on delete cascade,
  total_lessons smallint not null check (total_lessons between 1 and 12),
  remaining smallint not null check (remaining between 0 and 12),
  starts_on date,
  first_lesson_number smallint not null default 1 check (first_lesson_number between 1 and 12),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.lessons (
  id uuid primary key default gen_random_uuid(),
  lesson_date date not null,
  starts_at time not null,
  ends_at time not null,
  format text not null check (format in ('individual','pair','group')),
  student_id uuid references public.students(id) on delete cascade,
  group_id uuid references public.lesson_groups(id) on delete cascade,
  teacher_id uuid references public.teachers(id) on delete set null,
  status text not null default 'planned' check (status in ('planned','done','cancelled')),
  note text,
  created_at timestamptz not null default now(),
  constraint lesson_owner check ((student_id is not null) <> (group_id is not null))
);

create table public.lesson_attendance (
  lesson_id uuid references public.lessons(id) on delete cascade,
  student_id uuid references public.students(id) on delete cascade,
  status text not null default 'present' check (status in ('present','absent')),
  note text,
  charged boolean not null default false,
  primary key (lesson_id, student_id)
);

create table public.subscription_history (
  id uuid primary key default gen_random_uuid(),
  subscription_id uuid not null references public.subscriptions(id) on delete cascade,
  lesson_id uuid references public.lessons(id) on delete set null,
  delta smallint not null check (delta in (-1, 1)),
  reason text not null,
  created_at timestamptz not null default now()
);

create index lessons_date_status_idx on public.lessons (lesson_date, status);
create index students_teacher_idx on public.students (teacher_id);
create index subscriptions_student_active_idx on public.subscriptions (student_id, active);
create index subscription_history_lesson_idx on public.subscription_history (lesson_id);

-- Единое правило абонементов:
-- done списывает у присутствовавшего и отсутствовавшего;
-- planned/cancelled возвращает ранее выполненное списание.
create or replace function public.reconcile_lesson_charges(p_lesson_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_status text;
  v_subscription_id uuid;
  v_attendance record;
  v_refund_subscription_id uuid;
begin
  select status into v_status
  from public.lessons
  where id = p_lesson_id
  for update;

  if not found then
    return;
  end if;

  insert into public.lesson_attendance (lesson_id, student_id, status, charged)
  select l.id, participant.student_id, 'present', false
  from public.lessons l
  cross join lateral (
    select l.student_id where l.student_id is not null
    union
    select gm.student_id
    from public.group_members gm
    where gm.group_id = l.group_id
  ) participant
  where l.id = p_lesson_id
  on conflict (lesson_id, student_id) do nothing;

  if v_status = 'done' then
    for v_attendance in
      select * from public.lesson_attendance
      where lesson_id = p_lesson_id and charged = false
      for update
    loop
      v_subscription_id := null;

      select id into v_subscription_id
      from public.subscriptions
      where student_id = v_attendance.student_id
        and active = true
        and remaining > 0
      order by created_at desc
      limit 1
      for update;

      if v_subscription_id is not null then
        update public.subscriptions
        set remaining = remaining - 1
        where id = v_subscription_id;

        insert into public.subscription_history (subscription_id, lesson_id, delta, reason)
        values (
          v_subscription_id,
          p_lesson_id,
          -1,
          case when v_attendance.status = 'absent'
            then 'Проведённый урок · ученик отсутствовал'
            else 'Проведённый урок'
          end
        );

        update public.lesson_attendance
        set charged = true
        where lesson_id = p_lesson_id and student_id = v_attendance.student_id;
      end if;
    end loop;
  else
    for v_attendance in
      select * from public.lesson_attendance
      where lesson_id = p_lesson_id and charged = true
      for update
    loop
      v_refund_subscription_id := null;

      select h.subscription_id into v_refund_subscription_id
      from public.subscription_history h
      join public.subscriptions s on s.id = h.subscription_id
      where h.lesson_id = p_lesson_id
        and h.delta = -1
        and s.student_id = v_attendance.student_id
        and not exists (
          select 1 from public.subscription_history refund
          where refund.lesson_id = h.lesson_id
            and refund.subscription_id = h.subscription_id
            and refund.delta = 1
            and refund.created_at >= h.created_at
        )
      order by h.created_at desc
      limit 1;

      if v_refund_subscription_id is not null then
        update public.subscriptions
        set remaining = least(total_lessons, remaining + 1)
        where id = v_refund_subscription_id;

        insert into public.subscription_history (subscription_id, lesson_id, delta, reason)
        values (v_refund_subscription_id, p_lesson_id, 1, 'Урок отменён или снова запланирован');
      end if;

      update public.lesson_attendance
      set charged = false
      where lesson_id = p_lesson_id and student_id = v_attendance.student_id;
    end loop;
  end if;
end;
$$;

create or replace function public.on_lesson_status_changed()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.reconcile_lesson_charges(new.id);
  return new;
end;
$$;

create trigger lesson_status_reconcile
after insert or update of status on public.lessons
for each row execute function public.on_lesson_status_changed();

-- Все занятия, прошедшие заданный запас времени, закрываются одной транзакцией.
create or replace function public.complete_due_lessons()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_completed integer;
  v_timezone text;
  v_delay integer;
begin
  select timezone, auto_complete_minutes
  into v_timezone, v_delay
  from public.school_settings
  where id = true;

  with due as (
    select l.id
    from public.lessons l
    where l.status = 'planned'
      and (l.lesson_date + l.starts_at)
        <= timezone(v_timezone, now()) - make_interval(mins => v_delay)
    for update skip locked
  ), completed as (
    update public.lessons l
    set status = 'done'
    from due
    where l.id = due.id
    returning l.id
  )
  select count(*) into v_completed from completed;

  return v_completed;
end;
$$;

revoke all on function public.reconcile_lesson_charges(uuid) from public, anon, authenticated;
revoke all on function public.on_lesson_status_changed() from public, anon, authenticated;
revoke all on function public.complete_due_lessons() from public, anon, authenticated;
grant execute on function public.reconcile_lesson_charges(uuid) to postgres, service_role;
grant execute on function public.on_lesson_status_changed() to postgres, service_role;
grant execute on function public.complete_due_lessons() to postgres, service_role;

select cron.schedule(
  'linguaflow-auto-complete',
  '* * * * *',
  $$select public.complete_due_lessons();$$
);

-- Доступ к персональным данным только после входа сотрудника.
alter table public.school_settings enable row level security;
alter table public.teachers enable row level security;
alter table public.students enable row level security;
alter table public.student_schedule_slots enable row level security;
alter table public.lesson_groups enable row level security;
alter table public.group_members enable row level security;
alter table public.subscriptions enable row level security;
alter table public.lessons enable row level security;
alter table public.lesson_attendance enable row level security;
alter table public.subscription_history enable row level security;

create policy "staff settings" on public.school_settings for all to authenticated using (true) with check (true);
create policy "staff teachers" on public.teachers for all to authenticated using (true) with check (true);
create policy "staff students" on public.students for all to authenticated using (true) with check (true);
create policy "staff schedule" on public.student_schedule_slots for all to authenticated using (true) with check (true);
create policy "staff groups" on public.lesson_groups for all to authenticated using (true) with check (true);
create policy "staff members" on public.group_members for all to authenticated using (true) with check (true);
create policy "staff subscriptions" on public.subscriptions for all to authenticated using (true) with check (true);
create policy "staff lessons" on public.lessons for all to authenticated using (true) with check (true);
create policy "staff attendance" on public.lesson_attendance for all to authenticated using (true) with check (true);
create policy "staff history" on public.subscription_history for all to authenticated using (true) with check (true);

select
  'LinguaFlow настроен' as result,
  (select count(*) from cron.job where jobname = 'linguaflow-auto-complete') as active_jobs;
