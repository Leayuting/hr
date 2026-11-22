-- ============================================================
-- 器具破損紀錄（equipment damage records）：從0新增的獨立功能，完全比照
-- 報廢紀錄（waste records，見 phase-hr_migration_20260924_waste_records.sql）
-- 的技術架構，不修改/不擴充任何既有表、既有RPC、既有RLS政策。跟每日回報用
-- daily_report_id關聯方式串接（門市當日破損自動彙整進當天的每日回報）。
--
-- 設計依據見 /Users/phase/.claude/plans/refactored-giggling-badger.md
-- （已跟使用者確認過的完整規劃）。這裡只列跟報廢紀錄的刻意差異：
-- 1) 破損類型用固定分類（reason_code七選一），不是報廢紀錄的自由輸入品項——
--    器具種類有限，分類比自由文字更適合統計。item_name欄位用來描述「哪一件
--    器具」（例如：3號桌椅、二樓製冰機），reason_code描述「怎麼壞的」。
-- 2) 沒有quantity欄位——器具破損通常一次一件，不像食材有數量概念，整張表
--    拿掉這個欄位（跟報廢紀錄最大的結構差異）。
-- 3) 填寫人從一開始就用自由文字filled_by_name（不是uuid FK），直接套用
--    報廢紀錄事後才修正到的教訓（見phase-hr_migration_20260930b_waste_filled_by_freetext.sql）
--    ——共用PIN帳號＋跨店支援人員無法可靠對應到員工id，沿用自由文字欄位
--    從一開始就是對的設計，不重複報廢紀錄一開始走uuid FK再改的來回。
-- 4) can_manage_equipment_damage()是這次新增的權限函式，邏輯跟
--    can_manage_waste_record()完全一樣（讓店長PIN對自己店的破損紀錄有
--    更正/作廢/查歷史的能力）。
-- 5) 破損照片開獨立storage bucket（equipment-damage-photos），理由跟報廢
--    紀錄一樣：照片要在呼叫RPC之前就先上傳，這時候record本身的id是前端
--    自己產生的，daily_report_id還沒get-or-create出來，無法套用既有
--    daily-report-attachments bucket「第一段路徑=daily_report_id」的規則。
-- 6) Realtime：這份migration從一開始就把三張新表加進supabase_realtime
--    publication（報廢紀錄是上線後才補這一步，這次直接避免同一個遺漏）。
--
-- 2026-11-22使用者要求：不只依賴執行工具（supabase db query）的隱含交易
-- 行為，明確加上BEGIN/COMMIT——整份檔案（3張新表+1個bucket+5支函式+全部
-- RLS/storage政策+realtime publication）在同一個明確交易內，中途任何一步
-- 出錯，前面已執行的部分會整體rollback，不會留下部分建立的狀態。
-- 2026-11-22
-- ============================================================

begin;

-- ============================================================
-- 1) can_manage_equipment_damage：跟can_manage_waste_record邏輯完全相同，
--    放在最前面——後面第3張表(equipment_damage_history)的RLS政策要用到它
-- ============================================================
create or replace function can_manage_equipment_damage(p_store_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select is_super_admin()
    or feature_level('daily_report') = 'all'
    or (my_store_id() = p_store_id and exists (
          select 1 from employees
          where auth_user_id = auth.uid() and active
            and access_tier = 'dept_manager' and is_shared_pin_account
        ));
$$;
grant execute on function can_manage_equipment_damage(uuid) to authenticated;

-- ============================================================
-- 2) 器具破損主記錄表（無quantity欄位，filled_by_name從一開始就是自由文字）
-- ============================================================
create table if not exists equipment_damage_records (
  id uuid primary key,  -- 前端產生（呼叫RPC前要先知道id才能組出照片storage路徑）
  seq integer not null,  -- 同店同日流水號
  record_no text not null,
  store_id uuid not null references stores(id),
  report_date date not null,
  -- 器具破損紀錄是獨立的營運佐證資料，不能因為daily_reports被刪除就連帶
  -- 消失（比照報廢紀錄的修正結論），on delete set null、欄位允許null
  daily_report_id uuid references daily_reports(id) on delete set null,
  item_name text not null,  -- 哪一件器具（自由文字描述，例如：3號桌椅、製冰機）
  item_source text not null check (item_source in ('suggested', 'custom')),
  reason_code text not null check (reason_code in (
    'unusable', 'drop_impact', 'power_wire', 'scratch_crack',
    'part_missing', 'wear_aging', 'other'
  )),
  reason_note text,
  note text,
  filled_by_name text not null,
  status text not null default 'active' check (status in ('active', 'void')),
  created_by uuid references employees(id),
  created_by_name text not null,
  created_at timestamptz not null default now(),
  updated_by uuid references employees(id),
  updated_by_name text,
  updated_at timestamptz,
  voided_by uuid references employees(id),
  voided_by_name text,
  voided_at timestamptz,
  void_reason text,
  unique (store_id, report_date, seq),
  unique (record_no)
);
create index if not exists idx_equipment_damage_records_store_date on equipment_damage_records(store_id, report_date);
create index if not exists idx_equipment_damage_records_daily_report on equipment_damage_records(daily_report_id);

alter table equipment_damage_records enable row level security;
-- 只開select政策，不開insert/update/delete——所有寫入只能透過下面的
-- SECURITY DEFINER RPC
create policy "equipment damage records read" on equipment_damage_records for select
  using (can_view_daily_report(store_id));

-- ============================================================
-- 3) 破損照片 metadata（檔案本體在 Storage，這裡只存路徑）
-- ============================================================
create table if not exists equipment_damage_photos (
  id uuid primary key default gen_random_uuid(),
  equipment_damage_record_id uuid not null references equipment_damage_records(id) on delete cascade,
  storage_path text not null unique,
  file_name text not null,
  file_size int not null check (file_size > 0 and file_size <= 10485760),  -- 10MB，沿用既有上限
  mime_type text not null,
  uploaded_by uuid references employees(id),
  uploaded_at timestamptz not null default now()
);
create index if not exists idx_equipment_damage_photos_record on equipment_damage_photos(equipment_damage_record_id);

alter table equipment_damage_photos enable row level security;
create policy "equipment damage photos read" on equipment_damage_photos for select
  using (exists (
    select 1 from equipment_damage_records edr where edr.id = equipment_damage_record_id and can_view_daily_report(edr.store_id)
  ));

-- ============================================================
-- 4) 更正/作廢歷程（append-only）
-- ============================================================
create table if not exists equipment_damage_history (
  id uuid primary key default gen_random_uuid(),
  equipment_damage_record_id uuid not null references equipment_damage_records(id) on delete cascade,
  action text not null check (action in ('create', 'correct', 'void')),
  before_snapshot jsonb,
  after_snapshot jsonb not null,
  reason text,
  actor_id uuid references employees(id),
  actor_name_snapshot text,
  created_at timestamptz not null default now()
);
create index if not exists idx_equipment_damage_history_record on equipment_damage_history(equipment_damage_record_id);

alter table equipment_damage_history enable row level security;
-- 只有能管理器具破損紀錄的身分（店長PIN以上）能看修改/作廢歷程
create policy "equipment damage history read" on equipment_damage_history for select
  using (exists (
    select 1 from equipment_damage_records edr where edr.id = equipment_damage_record_id and can_manage_equipment_damage(edr.store_id)
  ));

-- ============================================================
-- 5) create_equipment_damage_record：新增破損紀錄，get-or-create當日
--    daily_reports列＋insert主記錄＋insert所有照片metadata＋insert一筆
--    history，單一交易
-- ============================================================
create or replace function create_equipment_damage_record(
  p_id uuid, p_store_id uuid, p_report_date date, p_item_name text,
  p_item_source text, p_reason_code text, p_reason_note text,
  p_note text, p_filled_by_name text, p_photos jsonb
)
returns table(id uuid, record_no text, daily_report_id uuid)
language plpgsql security definer set search_path = public as $$
declare
  v_report daily_reports;
  v_actor uuid; v_actor_name text;
  v_seq integer;
  v_record_no text;
  v_store_code text;
  v_photo jsonb;
  v_new equipment_damage_records;
begin
  if not can_fill_daily_report(p_store_id) then
    raise exception '無權限在此門市新增器具破損紀錄';
  end if;
  if p_item_name is null or trim(p_item_name) = '' then
    raise exception '請填寫損壞器具名稱';
  end if;
  if p_item_source not in ('suggested', 'custom') then
    raise exception '無效的品項來源';
  end if;
  if p_reason_code not in ('unusable', 'drop_impact', 'power_wire', 'scratch_crack', 'part_missing', 'wear_aging', 'other') then
    raise exception '無效的破損類型';
  end if;
  if p_reason_code = 'other' and (p_reason_note is null or trim(p_reason_note) = '') then
    raise exception '選擇「其他」類型時須填寫說明';
  end if;
  if p_filled_by_name is null or trim(p_filled_by_name) = '' then
    raise exception '請填寫填寫人';
  end if;
  if p_photos is null or jsonb_array_length(p_photos) < 1 then
    raise exception '器具破損紀錄至少需要1張照片';
  end if;
  if is_payroll_locked(p_store_id, p_report_date) then
    raise exception '該月份薪資已鎖定，無法新增器具破損紀錄';
  end if;

  v_actor := current_employee_id();
  select name into v_actor_name from employees where employees.id = v_actor;
  select code into v_store_code from stores where stores.id = p_store_id;

  -- get-or-create 當日 daily_reports 列（複製 submit_daily_report_entries 的既有慣例）
  select * into v_report from daily_reports where store_id = p_store_id and report_date = p_report_date;
  if v_report is null then
    insert into daily_reports (store_id, report_date, status)
      values (p_store_id, p_report_date, 'draft') returning * into v_report;
  end if;

  select coalesce(max(seq), 0) + 1 into v_seq from equipment_damage_records
    where store_id = p_store_id and report_date = p_report_date;
  v_record_no := coalesce(v_store_code, 'STORE') || '-' || to_char(p_report_date, 'YYYYMMDD') || '-' || lpad(v_seq::text, 3, '0');

  insert into equipment_damage_records (
    id, seq, record_no, store_id, report_date, daily_report_id,
    item_name, item_source, reason_code, reason_note, note,
    created_by, created_by_name, filled_by_name
  ) values (
    p_id, v_seq, v_record_no, p_store_id, p_report_date, v_report.id,
    trim(p_item_name), p_item_source, p_reason_code,
    case when p_reason_code = 'other' then trim(p_reason_note) else null end,
    nullif(trim(coalesce(p_note, '')), ''),
    v_actor, coalesce(v_actor_name, '未知帳號'), trim(p_filled_by_name)
  ) returning * into v_new;

  for v_photo in select * from jsonb_array_elements(p_photos) loop
    insert into equipment_damage_photos (equipment_damage_record_id, storage_path, file_name, file_size, mime_type, uploaded_by)
      values (
        p_id, v_photo->>'storage_path', v_photo->>'file_name',
        (v_photo->>'file_size')::int, v_photo->>'mime_type', v_actor
      );
  end loop;

  insert into equipment_damage_history (equipment_damage_record_id, action, before_snapshot, after_snapshot, actor_id, actor_name_snapshot)
    values (p_id, 'create', null, to_jsonb(v_new), v_actor, v_actor_name);

  return query select v_new.id, v_new.record_no, v_new.daily_report_id;
end;
$$;
grant execute on function create_equipment_damage_record(uuid, uuid, date, text, text, text, text, text, text, jsonb) to authenticated;

-- ============================================================
-- 6) correct_equipment_damage_record：更正（門市主管以上），保留原始內容
--    不覆蓋，寫history
-- ============================================================
create or replace function correct_equipment_damage_record(
  p_equipment_damage_record_id uuid, p_item_name text, p_item_source text,
  p_reason_code text, p_reason_note text, p_note text, p_filled_by_name text
)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_record equipment_damage_records;
  v_actor uuid; v_actor_name text;
begin
  select * into v_record from equipment_damage_records where id = p_equipment_damage_record_id;
  if v_record is null then raise exception '找不到這筆器具破損紀錄'; end if;
  if not can_manage_equipment_damage(v_record.store_id) then raise exception '無權限更正此門市的器具破損紀錄'; end if;
  if v_record.status <> 'active' then raise exception '已作廢的紀錄不能更正，請改建立新的器具破損紀錄'; end if;

  if p_item_name is null or trim(p_item_name) = '' then raise exception '請填寫損壞器具名稱'; end if;
  if p_item_source not in ('suggested', 'custom') then raise exception '無效的品項來源'; end if;
  if p_reason_code not in ('unusable', 'drop_impact', 'power_wire', 'scratch_crack', 'part_missing', 'wear_aging', 'other') then
    raise exception '無效的破損類型';
  end if;
  if p_reason_code = 'other' and (p_reason_note is null or trim(p_reason_note) = '') then
    raise exception '選擇「其他」類型時須填寫說明';
  end if;
  if p_filled_by_name is null or trim(p_filled_by_name) = '' then raise exception '請填寫填寫人'; end if;

  v_actor := current_employee_id();
  select name into v_actor_name from employees where id = v_actor;

  update equipment_damage_records set
    item_name = trim(p_item_name), item_source = p_item_source,
    reason_code = p_reason_code,
    reason_note = case when p_reason_code = 'other' then trim(p_reason_note) else null end,
    note = nullif(trim(coalesce(p_note, '')), ''),
    filled_by_name = trim(p_filled_by_name),
    updated_by = v_actor, updated_by_name = v_actor_name, updated_at = now()
    where id = p_equipment_damage_record_id;

  insert into equipment_damage_history (equipment_damage_record_id, action, before_snapshot, after_snapshot, actor_id, actor_name_snapshot)
    select p_equipment_damage_record_id, 'correct', to_jsonb(v_record), to_jsonb(edr), v_actor, v_actor_name
    from equipment_damage_records edr where edr.id = p_equipment_damage_record_id;
end;
$$;
grant execute on function correct_equipment_damage_record(uuid, text, text, text, text, text, text) to authenticated;

-- ============================================================
-- 7) void_equipment_damage_record：作廢（不是刪除），必填作廢原因
-- ============================================================
create or replace function void_equipment_damage_record(p_equipment_damage_record_id uuid, p_void_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_record equipment_damage_records;
  v_actor uuid; v_actor_name text;
begin
  select * into v_record from equipment_damage_records where id = p_equipment_damage_record_id;
  if v_record is null then raise exception '找不到這筆器具破損紀錄'; end if;
  if not can_manage_equipment_damage(v_record.store_id) then raise exception '無權限作廢此門市的器具破損紀錄'; end if;
  if v_record.status <> 'active' then raise exception '此紀錄已經是作廢狀態'; end if;
  if p_void_reason is null or trim(p_void_reason) = '' then raise exception '作廢須填寫原因'; end if;

  v_actor := current_employee_id();
  select name into v_actor_name from employees where id = v_actor;

  update equipment_damage_records set
    status = 'void', voided_by = v_actor, voided_by_name = v_actor_name,
    voided_at = now(), void_reason = trim(p_void_reason)
    where id = p_equipment_damage_record_id;

  insert into equipment_damage_history (equipment_damage_record_id, action, before_snapshot, after_snapshot, reason, actor_id, actor_name_snapshot)
    select p_equipment_damage_record_id, 'void', to_jsonb(v_record), to_jsonb(edr), trim(p_void_reason), v_actor, v_actor_name
    from equipment_damage_records edr where edr.id = p_equipment_damage_record_id;
end;
$$;
grant execute on function void_equipment_damage_record(uuid, text) to authenticated;

-- ============================================================
-- 8) equipment_damage_record_list：歷史查詢頁用，權限用
--    can_manage_equipment_damage（跟報廢紀錄一致，只有主管以上看得到，
--    RPC本身真的擋，不只靠前端不顯示分頁）
-- ============================================================
create or replace function equipment_damage_record_list(
  p_store_ids uuid[], p_date_from date, p_date_to date,
  p_item text default null, p_reason_code text default null,
  p_created_by uuid default null, p_status text[] default array['active', 'void'],
  p_limit integer default 50, p_offset integer default 0
)
returns table(
  record_id uuid, record_no text, store_id uuid, store_name text, report_date date,
  item_name text, reason_code text, reason_note text, note text, filled_by_name text,
  status text, created_by_name text, created_at timestamptz,
  photos jsonb, total_count bigint
)
language sql stable security definer set search_path = public as $$
  select edr.id, edr.record_no, edr.store_id, st.name, edr.report_date,
    edr.item_name, edr.reason_code, edr.reason_note, edr.note, edr.filled_by_name,
    edr.status, edr.created_by_name, edr.created_at,
    coalesce((
      select jsonb_agg(jsonb_build_object('storage_path', p.storage_path, 'file_name', p.file_name) order by p.uploaded_at)
      from equipment_damage_photos p where p.equipment_damage_record_id = edr.id
    ), '[]'::jsonb),
    count(*) over()
  from equipment_damage_records edr
  join stores st on st.id = edr.store_id
  where edr.store_id = any(p_store_ids)
    and edr.report_date between p_date_from and p_date_to
    and edr.status = any(p_status)
    and (p_item is null or edr.item_name ilike '%' || p_item || '%')
    and (p_reason_code is null or edr.reason_code = p_reason_code)
    and (p_created_by is null or edr.created_by = p_created_by)
    and can_manage_equipment_damage(edr.store_id)
  order by edr.created_at desc
  limit p_limit offset p_offset;
$$;
grant execute on function equipment_damage_record_list(uuid[], date, date, text, text, uuid, text[], integer, integer) to authenticated;

-- ============================================================
-- 9) equipment_item_suggestions：器具名稱搜尋建議，來源是該店過去打過的
--    破損器具名稱，依出現次數排序，不另建器具資料庫
-- ============================================================
create or replace function equipment_item_suggestions(p_store_id uuid, p_query text default '')
returns table(item_name text, use_count bigint)
language sql stable security definer set search_path = public as $$
  select edr.item_name, count(*) as use_count
  from equipment_damage_records edr
  where edr.store_id = p_store_id
    and can_fill_daily_report(p_store_id)
    and (p_query is null or p_query = '' or edr.item_name ilike '%' || p_query || '%')
  group by edr.item_name
  order by use_count desc, edr.item_name asc
  limit 10;
$$;
grant execute on function equipment_item_suggestions(uuid, text) to authenticated;

-- ============================================================
-- 10) Storage：破損照片獨立bucket，路徑規則
--     {store_id}/{equipment_damage_record_id}/{檔名}。不開delete政策。
-- ============================================================
insert into storage.buckets (id, name, public)
values ('equipment-damage-photos', 'equipment-damage-photos', false)
on conflict (id) do nothing;

create policy "equipment damage photos upload" on storage.objects for insert
  with check (
    bucket_id = 'equipment-damage-photos'
    and can_fill_daily_report(((storage.foldername(name))[1])::uuid)
  );
create policy "equipment damage photos storage read" on storage.objects for select
  using (
    bucket_id = 'equipment-damage-photos'
    and can_view_daily_report(((storage.foldername(name))[1])::uuid)
  );

-- ============================================================
-- 11) Realtime：報廢紀錄上線後才補這一步（20260924c），這次migration從一
--     開始就直接加，避免同一個遺漏重演。
-- ============================================================
alter publication supabase_realtime add table equipment_damage_records, equipment_damage_photos, equipment_damage_history;

commit;

-- ============================================================
-- 回復方案：只新增3張表＋1個bucket＋5支函式，完全沒有修改既有RPC/表/RLS，
-- 回復很單純——若要撤回，先停用前端新入口（EQUIPMENT_DAMAGE_READY保持
-- false／拿掉「新增器具破損」按鈕與「今日器具破損」區塊），確認沒有進行中
-- 的請求後，執行下面幾行即可，既有每日回報資料與功能完全不受影響：
--
-- alter publication supabase_realtime drop table equipment_damage_records, equipment_damage_photos, equipment_damage_history;
-- drop policy if exists "equipment damage photos upload" on storage.objects;
-- drop policy if exists "equipment damage photos storage read" on storage.objects;
-- -- bucket本身與其中已上傳的檔案不要在回復當下一併刪除，先保留，另外評估
-- drop function if exists equipment_item_suggestions(uuid, text);
-- drop function if exists equipment_damage_record_list(uuid[], date, date, text, text, uuid, text[], integer, integer);
-- drop function if exists void_equipment_damage_record(uuid, text);
-- drop function if exists correct_equipment_damage_record(uuid, text, text, text, text, text, text);
-- drop function if exists create_equipment_damage_record(uuid, uuid, date, text, text, text, text, text, text, jsonb);
-- -- can_manage_equipment_damage()不要跟著drop：equipment_damage_history表的
-- -- select政策還依賴它，且不影響EQUIPMENT_DAMAGE_READY=false時的行為
-- -- 已成功保存的破損紀錄與照片metadata請保留，不因回復而刪除表本身
-- ============================================================
