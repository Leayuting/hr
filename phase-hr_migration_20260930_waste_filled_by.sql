-- ============================================================
-- 報廢紀錄新增「填寫人」欄位：從門市名冊下拉選單登記，必填。
--
-- 背景：原本設計是「填寫人＝共用門市PIN帳號本身」，全自動、不需要現場人員
-- 多做一步（見phase-hr_migration_20260924_waste_records.sql檔頭說明），這是
-- 當初跟使用者確認過的決策。這次使用者改變主意，要求另外登記真正操作的人
-- （不然只看得到值班帳號，不知道實際是誰填的）——這次的異動是使用者主動
-- 推翻先前決策，不是修bug。
--
-- 做法比照既有漏打卡功能的「資訊提供者」（info_provided_by）：從門市名冊
-- 下拉選單選，不是自由輸入文字，避免打字不一致難以篩選/統計。
--
-- 既有的created_by／created_by_name欄位不動、不刪除——那兩欄仍然代表「哪個
-- 帳號送出這筆」（PIN帳號本身，稽核用），新的filled_by／filled_by_name才
-- 是「實際是哪個人」。
--
-- 提醒：create_waste_record有RETURNS TABLE(id uuid, ...)，函式內id是隱含
-- 變數，這次新增的查詢一樣要明確寫employees.id，不能只寫id（
-- phase-hr_migration_20260924b那次的bug就是這樣來的，這次刻意避開同一個坑）。
-- 2026-09-30
-- ============================================================

begin;

-- 1) 新增欄位（nullable，不backfill既有那1筆真實資料，只在RPC層強制新送出
--    的紀錄必填——這樣不用去猜/竄改已經送出的正式紀錄要填什麼名字）
alter table waste_records add column if not exists filled_by uuid references employees(id);
alter table waste_records add column if not exists filled_by_name text;

-- 2) create_waste_record：新增p_filled_by必填參數。參數列表改變(從10個變
--    11個)，CREATE OR REPLACE無法處理參數列表變更，要先drop舊版
drop function if exists create_waste_record(uuid, uuid, date, text, text, integer, text, text, text, jsonb);

create or replace function create_waste_record(
  p_id uuid, p_store_id uuid, p_report_date date, p_item_name text,
  p_item_source text, p_quantity integer, p_reason_code text, p_reason_note text,
  p_note text, p_filled_by uuid, p_photos jsonb
)
returns table(id uuid, record_no text, daily_report_id uuid)
language plpgsql security definer set search_path = public as $$
declare
  v_report daily_reports;
  v_actor uuid; v_actor_name text;
  v_filled_by_name text;
  v_seq integer;
  v_record_no text;
  v_store_code text;
  v_photo jsonb;
  v_new waste_records;
begin
  if not can_fill_daily_report(p_store_id) then
    raise exception '無權限在此門市新增報廢紀錄';
  end if;
  if p_item_name is null or trim(p_item_name) = '' then
    raise exception '請填寫報廢品項';
  end if;
  if p_item_source not in ('suggested', 'custom') then
    raise exception '無效的品項來源';
  end if;
  if p_quantity is null or p_quantity <= 0 then
    raise exception '報廢數量須大於0';
  end if;
  if p_reason_code not in ('made_wrong', 'quality_issue', 'customer_no_show', 'spill_broken', 'expired', 'wrong_order', 'other') then
    raise exception '無效的報廢原因';
  end if;
  if p_reason_code = 'other' and (p_reason_note is null or trim(p_reason_note) = '') then
    raise exception '選擇「其他」原因時須填寫說明';
  end if;
  if p_filled_by is null then
    raise exception '請選擇填寫人';
  end if;
  if not exists (select 1 from employees where employees.id = p_filled_by and employees.store_id = p_store_id and employees.active) then
    raise exception '所選填寫人不屬於此門市或已離職，請重新選擇';
  end if;
  if p_photos is null or jsonb_array_length(p_photos) < 1 then
    raise exception '報廢紀錄至少需要1張照片';
  end if;
  if is_payroll_locked(p_store_id, p_report_date) then
    raise exception '該月份薪資已鎖定，無法新增報廢紀錄';
  end if;

  v_actor := current_employee_id();
  select name into v_actor_name from employees where employees.id = v_actor;
  select name into v_filled_by_name from employees where employees.id = p_filled_by;
  select code into v_store_code from stores where stores.id = p_store_id;

  -- get-or-create 當日 daily_reports 列（複製 submit_daily_report_entries 的既有慣例）
  select * into v_report from daily_reports where store_id = p_store_id and report_date = p_report_date;
  if v_report is null then
    insert into daily_reports (store_id, report_date, status)
      values (p_store_id, p_report_date, 'draft') returning * into v_report;
  end if;

  select coalesce(max(seq), 0) + 1 into v_seq from waste_records
    where store_id = p_store_id and report_date = p_report_date;
  v_record_no := coalesce(v_store_code, 'STORE') || '-' || to_char(p_report_date, 'YYYYMMDD') || '-' || lpad(v_seq::text, 3, '0');

  insert into waste_records (
    id, seq, record_no, store_id, report_date, daily_report_id,
    item_name, item_source, quantity, reason_code, reason_note, note,
    created_by, created_by_name, filled_by, filled_by_name
  ) values (
    p_id, v_seq, v_record_no, p_store_id, p_report_date, v_report.id,
    trim(p_item_name), p_item_source, p_quantity, p_reason_code,
    case when p_reason_code = 'other' then trim(p_reason_note) else null end,
    nullif(trim(coalesce(p_note, '')), ''),
    v_actor, coalesce(v_actor_name, '未知帳號'), p_filled_by, coalesce(v_filled_by_name, '未知員工')
  ) returning * into v_new;

  for v_photo in select * from jsonb_array_elements(p_photos) loop
    insert into waste_record_photos (waste_record_id, storage_path, file_name, file_size, mime_type, uploaded_by)
      values (
        p_id, v_photo->>'storage_path', v_photo->>'file_name',
        (v_photo->>'file_size')::int, v_photo->>'mime_type', v_actor
      );
  end loop;

  insert into waste_record_history (waste_record_id, action, before_snapshot, after_snapshot, actor_id, actor_name_snapshot)
    values (p_id, 'create', null, to_jsonb(v_new), v_actor, v_actor_name);

  return query select v_new.id, v_new.record_no, v_new.daily_report_id;
end;
$$;
grant execute on function create_waste_record(uuid, uuid, date, text, text, integer, text, text, text, uuid, jsonb) to authenticated;

-- 3) waste_record_list：輸出欄位新增filled_by_name。輸出欄位組成改變也算是
--    「改變回傳型別」，CREATE OR REPLACE一樣處理不了，要先drop
drop function if exists waste_record_list(uuid[], date, date, text, text, uuid, text[], integer, integer);

create or replace function waste_record_list(
  p_store_ids uuid[], p_date_from date, p_date_to date,
  p_item text default null, p_reason_code text default null,
  p_created_by uuid default null, p_status text[] default array['active', 'void'],
  p_limit integer default 50, p_offset integer default 0
)
returns table(
  record_id uuid, record_no text, store_id uuid, store_name text, report_date date,
  item_name text, quantity integer, reason_code text, reason_note text, note text,
  status text, created_by_name text, filled_by_name text, created_at timestamptz,
  photos jsonb, total_count bigint
)
language sql stable security definer set search_path = public as $$
  select wr.id, wr.record_no, wr.store_id, st.name, wr.report_date,
    wr.item_name, wr.quantity, wr.reason_code, wr.reason_note, wr.note,
    wr.status, wr.created_by_name, wr.filled_by_name, wr.created_at,
    coalesce((
      select jsonb_agg(jsonb_build_object('storage_path', p.storage_path, 'file_name', p.file_name) order by p.uploaded_at)
      from waste_record_photos p where p.waste_record_id = wr.id
    ), '[]'::jsonb),
    count(*) over()
  from waste_records wr
  join stores st on st.id = wr.store_id
  where wr.store_id = any(p_store_ids)
    and wr.report_date between p_date_from and p_date_to
    and wr.status = any(p_status)
    and (p_item is null or wr.item_name ilike '%' || p_item || '%')
    and (p_reason_code is null or wr.reason_code = p_reason_code)
    and (p_created_by is null or wr.filled_by = p_created_by)
    and can_manage_waste_record(wr.store_id)
  order by wr.created_at desc
  limit p_limit offset p_offset;
$$;
grant execute on function waste_record_list(uuid[], date, date, text, text, uuid, text[], integer, integer) to authenticated;

commit;

-- 回復方式：drop兩支新簽章的函式，恢復成20260924b版本（10參數版
-- create_waste_record／不含filled_by_name的waste_record_list），並視情況
-- drop掉filled_by／filled_by_name兩個欄位（既有資料不受影響，只是這兩欄
-- 會變回不存在）。
