-- ============================================================
-- 「填寫人」改成自由輸入文字，不再限定從門市名冊選擇。
--
-- 背景：使用者指出有跨店支援的情況——原本的store_roster()下拉選單只會列出
-- 「該門市自己的員工」（p_store_id篩的是常駐門市），支援人員在支援當下
-- 不屬於那間門市的名冊，選不到自己，造成困擾。改成自由輸入文字解決這個
-- 邊界情況，使用者自己選擇要打什麼（可能是姓名、也可能是工號等，不限制
-- 格式）。
--
-- 既有的filled_by（uuid，關聯員工表）欄位保留在schema裡，不刪除，但這次
-- 之後新建立的紀錄不會再寫入這個欄位（一律null）——因為自由文字沒辦法
-- 可靠對應到一筆員工id，勉強對應反而可能對錯人。真正代表「填寫人是誰」
-- 的只剩filled_by_name這個文字欄位。
-- 2026-09-30
-- ============================================================

begin;

-- create_waste_record：p_filled_by從uuid改成text，型別改變等同改變函式
-- 簽章，CREATE OR REPLACE處理不了，要先drop舊版
drop function if exists create_waste_record(uuid, uuid, date, text, text, integer, text, text, text, uuid, jsonb);

create or replace function create_waste_record(
  p_id uuid, p_store_id uuid, p_report_date date, p_item_name text,
  p_item_source text, p_quantity integer, p_reason_code text, p_reason_note text,
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
  if p_filled_by_name is null or trim(p_filled_by_name) = '' then
    raise exception '請填寫填寫人';
  end if;
  if p_photos is null or jsonb_array_length(p_photos) < 1 then
    raise exception '報廢紀錄至少需要1張照片';
  end if;
  if is_payroll_locked(p_store_id, p_report_date) then
    raise exception '該月份薪資已鎖定，無法新增報廢紀錄';
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

  select coalesce(max(seq), 0) + 1 into v_seq from waste_records
    where store_id = p_store_id and report_date = p_report_date;
  v_record_no := coalesce(v_store_code, 'STORE') || '-' || to_char(p_report_date, 'YYYYMMDD') || '-' || lpad(v_seq::text, 3, '0');

  insert into waste_records (
    id, seq, record_no, store_id, report_date, daily_report_id,
    item_name, item_source, quantity, reason_code, reason_note, note,
    created_by, created_by_name, filled_by_name
  ) values (
    p_id, v_seq, v_record_no, p_store_id, p_report_date, v_report.id,
    trim(p_item_name), p_item_source, p_quantity, p_reason_code,
    case when p_reason_code = 'other' then trim(p_reason_note) else null end,
    nullif(trim(coalesce(p_note, '')), ''),
    v_actor, coalesce(v_actor_name, '未知帳號'), trim(p_filled_by_name)
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
grant execute on function create_waste_record(uuid, uuid, date, text, text, integer, text, text, text, text, jsonb) to authenticated;

commit;

-- 回復方式：drop這個text版本，恢復成20260930版本（p_filled_by uuid、限定
-- 從門市名冊選）。waste_records.filled_by_name欄位不受影響、資料保留。
