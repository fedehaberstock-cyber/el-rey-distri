-- ═════════ Zonas: dia_semana (int) → dias_semana (int[]) ═════════
-- Permite que una zona se visite varios días a la semana.

alter table public.zonas
  add column if not exists dias_semana int[] not null default '{}'::int[];

-- Migrar dato existente si lo hubiera
update public.zonas
   set dias_semana = array[dia_semana]
 where dia_semana is not null
   and (dias_semana is null or array_length(dias_semana,1) is null);

alter table public.zonas drop column if exists dia_semana;

-- Check: cada valor debe estar entre 1 y 7
alter table public.zonas drop constraint if exists zonas_dias_semana_check;
alter table public.zonas add constraint zonas_dias_semana_check
  check (dias_semana <@ array[1,2,3,4,5,6,7]);
