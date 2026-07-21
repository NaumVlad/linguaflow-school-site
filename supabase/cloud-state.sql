-- LinguaFlow — подключение состояния сайта к облаку.
-- Выполнить после setup.sql в Supabase SQL Editor.

create table public.app_state (
  id smallint primary key check (id = 1),
  data jsonb not null,
  revision bigint not null default 1,
  updated_at timestamptz not null default now()
);

alter table public.app_state enable row level security;
create policy "staff cloud state" on public.app_state
for all to authenticated using (id = 1) with check (id = 1);

alter publication supabase_realtime add table public.app_state;

create or replace function public.bump_app_state_revision()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.revision := old.revision + 1;
  new.updated_at := now();
  return new;
end;
$$;

create trigger app_state_revision
before update on public.app_state
for each row execute function public.bump_app_state_revision();

-- Сервер обновляет тот же JSON, который использует существующий интерфейс.
-- Поэтому перенос на облако не меняет карточки, команды помощника и историю.
create or replace function public.complete_due_lessons()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_state jsonb;
  v_lesson jsonb;
  v_attendance jsonb;
  v_charged jsonb;
  v_history jsonb;
  v_student_ids text[];
  v_student_id text;
  v_timezone text;
  v_delay integer;
  v_lesson_count integer;
  v_lesson_index integer;
  v_student_index integer;
  v_remaining integer;
  v_completed integer := 0;
begin
  select data into v_state
  from public.app_state
  where id = 1
  for update;

  if v_state is null then
    return 0;
  end if;

  v_timezone := coalesce(v_state #>> '{settings,timezone}', 'Europe/Kyiv');
  v_delay := greatest(0, coalesce((v_state #>> '{settings,autoCompleteMinutes}')::integer, 30));
  v_lesson_count := jsonb_array_length(coalesce(v_state->'lessons', '[]'::jsonb));

  if v_lesson_count = 0 then
    return 0;
  end if;

  for v_lesson_index in 0..v_lesson_count - 1 loop
    v_lesson := v_state #> array['lessons', v_lesson_index::text];

    if v_lesson->>'status' <> 'planned'
      or ((v_lesson->>'date')::date + (v_lesson->>'start')::time)
        > timezone(v_timezone, now()) - make_interval(mins => v_delay)
    then
      continue;
    end if;

    if nullif(v_lesson->>'studentId', '') is not null then
      v_student_ids := array[v_lesson->>'studentId'];
    else
      select coalesce(array_agg(member.student_id), array[]::text[])
      into v_student_ids
      from jsonb_array_elements(coalesce(v_state->'groups', '[]'::jsonb)) group_row
      cross join lateral jsonb_array_elements_text(coalesce(group_row->'studentIds', '[]'::jsonb)) member(student_id)
      where group_row->>'id' = v_lesson->>'groupId';
    end if;

    v_attendance := coalesce(v_lesson->'attendance', '{}'::jsonb);
    v_charged := coalesce(v_lesson->'chargedStudentIds', '[]'::jsonb);

    foreach v_student_id in array v_student_ids loop
      if not (v_attendance ? v_student_id) then
        v_attendance := jsonb_set(
          v_attendance,
          array[v_student_id],
          jsonb_build_object(
            'status', 'present',
            'note', 'Автоматически отмечено сервером после начала урока'
          ),
          true
        );
      end if;

      if exists (
        select 1 from jsonb_array_elements_text(v_charged) charged(student_id)
        where charged.student_id = v_student_id
      ) then
        continue;
      end if;

      select student_row.ordinality::integer - 1
      into v_student_index
      from jsonb_array_elements(coalesce(v_state->'students', '[]'::jsonb))
        with ordinality student_row(value, ordinality)
      where student_row.value->>'id' = v_student_id
      limit 1;

      if v_student_index is not null then
        v_remaining := coalesce((v_state #>> array['students', v_student_index::text, 'remaining'])::integer, 0);

        if v_remaining > 0 then
          v_state := jsonb_set(
            v_state,
            array['students', v_student_index::text, 'remaining'],
            to_jsonb(v_remaining - 1),
            false
          );

          v_history := coalesce(v_state #> array['students', v_student_index::text, 'history'], '[]'::jsonb);
          v_history := v_history || jsonb_build_array(jsonb_build_object(
            'id', gen_random_uuid()::text,
            'lessonId', v_lesson->>'id',
            'date', to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
            'delta', -1,
            'reason', case when v_attendance #>> array[v_student_id, 'status'] = 'absent'
              then 'Проведённый урок · ученик отсутствовал'
              else 'Проведённый урок'
            end
          ));
          v_state := jsonb_set(
            v_state,
            array['students', v_student_index::text, 'history'],
            v_history,
            true
          );
        end if;
      end if;

      v_charged := v_charged || jsonb_build_array(v_student_id);
      v_student_index := null;
    end loop;

    v_lesson := jsonb_set(v_lesson, '{status}', to_jsonb('done'::text), false);
    v_lesson := jsonb_set(v_lesson, '{attendance}', v_attendance, true);
    v_lesson := jsonb_set(v_lesson, '{chargedStudentIds}', v_charged, true);
    v_state := jsonb_set(v_state, array['lessons', v_lesson_index::text], v_lesson, false);
    v_completed := v_completed + 1;
  end loop;

  if v_completed > 0 then
    update public.app_state set data = v_state where id = 1;
  end if;

  return v_completed;
end;
$$;

revoke all on function public.bump_app_state_revision() from public, anon, authenticated;
revoke all on function public.complete_due_lessons() from public, anon, authenticated;
grant execute on function public.bump_app_state_revision() to postgres, service_role;
grant execute on function public.complete_due_lessons() to postgres, service_role;

-- То же имя заменяет предыдущую команду существующей минутной задачи.
select cron.schedule(
  'linguaflow-auto-complete',
  '* * * * *',
  $$select public.complete_due_lessons();$$
);

select
  'Облачная синхронизация готова' as result,
  (select count(*) from cron.job where jobname = 'linguaflow-auto-complete') as active_jobs;
