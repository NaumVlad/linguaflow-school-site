-- LinguaFlow: базовая схема для перехода с IndexedDB на Supabase.
create extension if not exists "pgcrypto";

create table teachers (id uuid primary key default gen_random_uuid(), name text not null, created_at timestamptz default now());
create table students (
  id uuid primary key default gen_random_uuid(), first_name text not null, last_name text not null,
  format text not null check (format in ('individual','pair','group')), teacher_id uuid references teachers(id),
  weekdays smallint[] default '{}', lesson_time time, contact text, note text, created_at timestamptz default now()
);
create table student_schedule_slots (
  student_id uuid references students(id) on delete cascade,
  weekday smallint not null check(weekday between 0 and 6),
  lesson_time time not null,
  primary key(student_id, weekday)
);
create table lesson_groups (
  id uuid primary key default gen_random_uuid(), name text not null, type text not null check (type in ('pair','group')),
  teacher_id uuid references teachers(id), created_at timestamptz default now()
);
create table group_members (group_id uuid references lesson_groups(id) on delete cascade, student_id uuid references students(id) on delete cascade, primary key(group_id,student_id));
create table subscriptions (
  id uuid primary key default gen_random_uuid(), student_id uuid not null references students(id) on delete cascade,
  total_lessons smallint not null check(total_lessons between 1 and 12), remaining smallint not null check(remaining >= 0),
  starts_on date, first_lesson_number smallint not null default 1 check(first_lesson_number between 1 and 12),
  active boolean default true, created_at timestamptz default now()
);
create table lessons (
  id uuid primary key default gen_random_uuid(), lesson_date date not null, starts_at time not null, ends_at time not null,
  format text not null check(format in ('individual','pair','group')), student_id uuid references students(id), group_id uuid references lesson_groups(id),
  teacher_id uuid references teachers(id), status text not null default 'planned' check(status in ('planned','done','cancelled')), note text, created_at timestamptz default now(),
  constraint lesson_owner check ((student_id is not null) <> (group_id is not null))
);
create table lesson_attendance (
  lesson_id uuid references lessons(id) on delete cascade,
  student_id uuid references students(id) on delete cascade,
  status text not null check(status in ('present','absent')),
  note text,
  charged boolean not null default false,
  primary key(lesson_id, student_id)
);
create table subscription_history (
  id uuid primary key default gen_random_uuid(), subscription_id uuid not null references subscriptions(id) on delete cascade,
  lesson_id uuid references lessons(id) on delete set null, delta smallint not null, reason text not null, created_at timestamptz default now()
);

create index lessons_date_idx on lessons(lesson_date);
create index students_teacher_idx on students(teacher_id);
alter table teachers enable row level security;
alter table students enable row level security;
alter table student_schedule_slots enable row level security;
alter table lesson_groups enable row level security;
alter table group_members enable row level security;
alter table subscriptions enable row level security;
alter table lessons enable row level security;
alter table lesson_attendance enable row level security;
alter table subscription_history enable row level security;

-- Базовая политика для авторизованных сотрудников. Перед продакшеном добавьте роли школы.
create policy "authenticated staff teachers" on teachers for all to authenticated using (true) with check (true);
create policy "authenticated staff students" on students for all to authenticated using (true) with check (true);
create policy "authenticated staff schedule slots" on student_schedule_slots for all to authenticated using (true) with check (true);
create policy "authenticated staff groups" on lesson_groups for all to authenticated using (true) with check (true);
create policy "authenticated staff members" on group_members for all to authenticated using (true) with check (true);
create policy "authenticated staff subscriptions" on subscriptions for all to authenticated using (true) with check (true);
create policy "authenticated staff lessons" on lessons for all to authenticated using (true) with check (true);
create policy "authenticated staff attendance" on lesson_attendance for all to authenticated using (true) with check (true);
create policy "authenticated staff history" on subscription_history for all to authenticated using (true) with check (true);
