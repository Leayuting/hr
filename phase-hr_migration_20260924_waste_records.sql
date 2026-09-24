-- ============================================================
-- 報廢紀錄（waste records）：從0新增的獨立功能，不修改/不擴充任何既有表、
-- 既有RPC、既有RLS政策。跟每日回報用 daily_report_id 關聯方式串接（門市當日
-- 報廢自動彙整進當天的每日回報），不是塞進 daily_report_entries 或
-- daily_report_attachments。
--
-- 設計依據見 /Users/phase/.claude/plans/snazzy-growing-pony.md（已跟使用者
-- 確認過的完整規劃，含一次獨立Plan agent審閱抓到並修正的5個問題）。這裡
-- 只列關鍵設計提醒：
-- 1) 品項用「自動建議（該店歷史報廢品項，依出現次數排序）＋隨時可自訂文字」，
--    不另建品項資料庫（phase-hr本身沒有商品資料庫，「咖啡豆資料庫」是完全
--    獨立的另一個Supabase專案，這次不跨專案串接）。
-- 2) 填寫人員記錄的是門市共用PIN帳號本身（PIN帳號名稱快照），不是個人姓名
--    ——系統架構上本來就無法知道PIN背後是哪一位，跟簽名紀錄/送出帳號等既有
--    功能完全一致的既有限制，不是這次新功能的缺陷。
-- 3) can_manage_waste_record()是這次唯一新增的權限函式，用來讓「店長PIN」
--    （access_tier='dept_manager'的共用PIN）對報廢紀錄有更正/作廢/查歷史的
--    能力——這是既有daily_report權限完全沒有的（一般PIN跟店長PIN目前對
--    daily_report本身的feature_level都是'fill'，沒有分別）。故意透過既有
--    my_store_id()（已內建auth_user_id=auth.uid() and active過濾）做門市
--    比對，不手刻inline查詢——self_schedule_*系列RPC當年手刻的寫法後來被
--    發現漏了active過濾且不利於維護一致性，這次直接避開同一類問題。
-- 4) 報廢照片開一個新的獨立 storage bucket（waste-record-photos），不是既有
--    daily-report-attachments的RLS有問題（核對過phase-hr_fix_20260810_rbac.sql，
--    can_access_report/can_edit_report其實已經是用can_view_daily_report/
--    can_fill_daily_report的正確模型，沒有過時），純粹是路徑綁定的技術限制：
--    報廢照片要在呼叫任何RPC之前就先上傳，這時候daily_report_id還沒被
--    get-or-create出來，前端只有自己產生的waste_record_id可用，跟既有bucket
--    「第一段路徑=daily_report_id」的規則對不上，改用新bucket＋
--    {store_id}/{waste_record_id}/... 路徑規則就不會有這個先後順序問題。
-- 5) 照片上傳（Storage）＋資料庫寫入（RPC）本質上是兩個獨立步驟（Storage
--    操作無法併入SQL交易，這是Supabase平台限制，簽名上傳/請假憑證上傳也是
--    同樣模式），但「資料庫」那一段（報廢主記錄＋所有照片metadata＋歷程）
--    仍然用單一wrapper RPC一次做完、單一交易——不是上一輪ops-tracking被
--    糾正的「兩個資料庫寫入各自獨立」那種半套寫入問題。
--
-- 部署前待確認事項見檔案結尾。
--
-- 2026-09-24使用者要求：不只依賴執行工具（supabase db query）的隱含交易行為，
-- 明確加上BEGIN/COMMIT——整份檔案（3張新表+1個bucket+6支函式+全部RLS/
-- storage政策）在同一個明確交易內，中途任何一步出錯，前面已執行的部分會
-- 整體rollback，不會留下部分建立的狀態。
-- 2026-09-24
-- ============================================================

begin;

-- ============================================================
-- 1) can_manage_waste_record：這次唯一新增的權限函式，見檔頭說明。放在最前面
--    先建立——因為後面第3張表(waste_record_history)的RLS政策要用到它，
--    CREATE POLICY在建立當下就要能解析到這支函式，不能等到後面才定義
-- ============================================================
create or replace function can_manage_waste_record(p_store_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select is_super_admin()
    or feature_level('daily_report') = 'all'
    or (my_store_id() = p_store_id and exists (
          select 1 from employees
          where auth_user_id = auth.uid() and active
            and access_tier = 'dept_manager' and is_shared_pin_account
        ));
$$;
grant execute on function can_manage_waste_record(uuid) to authenticated;

-- ============================================================
-- 2) 報廢主記錄表
-- ============================================================
create table if not exists waste_records (
  id uuid primary key,  -- 前端產生（呼叫RPC前要先知道id才能組出照片storage路徑）
  seq integer not null,  -- 同店同日流水號
  record_no text not null,
  store_id uuid not null references stores(id),
  report_date date not null,
  -- 2026-09-24使用者要求修正：報廢紀錄是獨立的營運佐證資料，不能因為
  -- daily_reports被刪除就連帶消失（原本寫on delete cascade是錯的，已改成
  -- on delete set null，欄位跟著改成允許null）——store_id/report_date/
  -- item_name/quantity/reason_code/created_by等所有真正的報廢事實欄位都在
  -- 這張表本身，就算daily_report_id變成null，這筆報廢紀錄本身、照片、歷程
  -- 完全不受影響，只是失去跟那筆（已經被刪除的）每日回報的關聯
  daily_report_id uuid references daily_reports(id) on delete set null,
  item_name text not null,
  item_source text not null check (item_source in ('suggested', 'custom')),
  quantity integer not null check (quantity > 0),
  reason_code text not null check (reason_code in (
    'made_wrong', 'quality_issue', 'customer_no_show', 'spill_broken',
    'expired', 'wrong_order', 'other'
  )),
  reason_note text,
  note text,
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
create index if not exists idx_waste_records_store_date on waste_records(store_id, report_date);
create index if not exists idx_waste_records_daily_report on waste_records(daily_report_id);

alter table waste_records enable row level security;
-- 只開 select 政策，不開 insert/update/delete——所有寫入只能透過下面的
-- SECURITY DEFINER RPC，這樣「不可無痕刪除」「所有異動需留痕」直接由資料庫
-- 結構保證，不是前端自律
create policy "waste records read" on waste_records for select
  using (can_view_daily_report(store_id));

-- ============================================================
-- 3) 報廢照片 metadata（檔案本體在 Storage，這裡只存路徑）
-- ============================================================
create table if not exists waste_record_photos (
  id uuid primary key default gen_random_uuid(),
  waste_record_id uuid not null references waste_records(id) on delete cascade,
  storage_path text not null unique,
  file_name text not null,
  file_size int not null check (file_size > 0 and file_size <= 10485760),  -- 10MB，沿用daily_report_attachments既有上限
  mime_type text not null,
  uploaded_by uuid references employees(id),
  uploaded_at timestamptz not null default now()
);
create index if not exists idx_waste_record_photos_record on waste_record_photos(waste_record_id);

alter table waste_record_photos enable row level security;
create policy "waste record photos read" on waste_record_photos for select
  using (exists (
    select 1 from waste_records wr where wr.id = waste_record_id and can_view_daily_report(wr.store_id)
  ));

-- ============================================================
-- 4) 更正/作廢歷程（append-only，比照daily_report_missed_punch_history同款設計）
-- ============================================================
create table if not exists waste_record_history (
  id uuid primary key default gen_random_uuid(),
  waste_record_id uuid not null references waste_records(id) on delete cascade,
  action text not null check (action in ('create', 'correct', 'void')),
  before_snapshot jsonb,
  after_snapshot jsonb not null,
  reason text,
  actor_id uuid references employees(id),
  actor_name_snapshot text,
  created_at timestamptz not null default now()
);
create index if not exists idx_waste_record_history_record on waste_record_history(waste_record_id);

alter table waste_record_history enable row level security;
-- 只有能管理報廢紀錄的身分（店長PIN以上）能看修改/作廢歷程，一般門市人員
-- 看不到——對應規格權限表「查看修改紀錄／查看作廢紀錄」只列給門市主管/
-- 營運管理端
create policy "waste record history read" on waste_record_history for select
  using (exists (
    select 1 from waste_records wr where wr.id = waste_record_id and can_manage_waste_record(wr.store_id)
  ));

-- ============================================================
-- 5) create_waste_record：新增報廢，get-or-create當日daily_reports列＋
--    insert主記錄＋insert所有照片metadata＋insert一筆history，單一交易
-- ============================================================
create or replace function create_waste_record(
  p_id uuid, p_store_id uuid, p_report_date date, p_item_name text,
  p_item_source text, p_quantity integer, p_reason_code text, p_reason_note text,
  p_note text, p_photos jsonb
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
  if p_photos is null or jsonb_array_length(p_photos) < 1 then
    raise exception '報廢紀錄至少需要1張照片';
  end if;
  if is_payroll_locked(p_store_id, p_report_date) then
    raise exception '該月份薪資已鎖定，無法新增報廢紀錄';
  end if;

  v_actor := current_employee_id();
  select name into v_actor_name from employees where id = v_actor;
  select code into v_store_code from stores where id = p_store_id;

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
    created_by, created_by_name
  ) values (
    p_id, v_seq, v_record_no, p_store_id, p_report_date, v_report.id,
    trim(p_item_name), p_item_source, p_quantity, p_reason_code,
    case when p_reason_code = 'other' then trim(p_reason_note) else null end,
    nullif(trim(coalesce(p_note, '')), ''),
    v_actor, coalesce(v_actor_name, '未知帳號')
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
grant execute on function create_waste_record(uuid, uuid, date, text, text, integer, text, text, text, jsonb) to authenticated;

-- ============================================================
-- 6) correct_waste_record：更正（門市主管以上），保留原始內容不覆蓋，寫history
-- ============================================================
create or replace function correct_waste_record(
  p_waste_record_id uuid, p_item_name text, p_item_source text,
  p_quantity integer, p_reason_code text, p_reason_note text, p_note text
)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_record waste_records;
  v_actor uuid; v_actor_name text;
begin
  select * into v_record from waste_records where id = p_waste_record_id;
  if v_record is null then raise exception '找不到這筆報廢紀錄'; end if;
  if not can_manage_waste_record(v_record.store_id) then raise exception '無權限更正此門市的報廢紀錄'; end if;
  if v_record.status <> 'active' then raise exception '已作廢的紀錄不能更正，請改建立新的報廢紀錄'; end if;

  if p_item_name is null or trim(p_item_name) = '' then raise exception '請填寫報廢品項'; end if;
  if p_item_source not in ('suggested', 'custom') then raise exception '無效的品項來源'; end if;
  if p_quantity is null or p_quantity <= 0 then raise exception '報廢數量須大於0'; end if;
  if p_reason_code not in ('made_wrong', 'quality_issue', 'customer_no_show', 'spill_broken', 'expired', 'wrong_order', 'other') then
    raise exception '無效的報廢原因';
  end if;
  if p_reason_code = 'other' and (p_reason_note is null or trim(p_reason_note) = '') then
    raise exception '選擇「其他」原因時須填寫說明';
  end if;

  v_actor := current_employee_id();
  select name into v_actor_name from employees where id = v_actor;

  update waste_records set
    item_name = trim(p_item_name), item_source = p_item_source, quantity = p_quantity,
    reason_code = p_reason_code,
    reason_note = case when p_reason_code = 'other' then trim(p_reason_note) else null end,
    note = nullif(trim(coalesce(p_note, '')), ''),
    updated_by = v_actor, updated_by_name = v_actor_name, updated_at = now()
    where id = p_waste_record_id;

  insert into waste_record_history (waste_record_id, action, before_snapshot, after_snapshot, actor_id, actor_name_snapshot)
    select p_waste_record_id, 'correct', to_jsonb(v_record), to_jsonb(wr), v_actor, v_actor_name
    from waste_records wr where wr.id = p_waste_record_id;
end;
$$;
grant execute on function correct_waste_record(uuid, text, text, integer, text, text, text) to authenticated;

-- ============================================================
-- 7) void_waste_record：作廢（不是刪除），必填作廢原因
-- ============================================================
create or replace function void_waste_record(p_waste_record_id uuid, p_void_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_record waste_records;
  v_actor uuid; v_actor_name text;
begin
  select * into v_record from waste_records where id = p_waste_record_id;
  if v_record is null then raise exception '找不到這筆報廢紀錄'; end if;
  if not can_manage_waste_record(v_record.store_id) then raise exception '無權限作廢此門市的報廢紀錄'; end if;
  if v_record.status <> 'active' then raise exception '此紀錄已經是作廢狀態'; end if;
  if p_void_reason is null or trim(p_void_reason) = '' then raise exception '作廢須填寫原因'; end if;

  v_actor := current_employee_id();
  select name into v_actor_name from employees where id = v_actor;

  update waste_records set
    status = 'void', voided_by = v_actor, voided_by_name = v_actor_name,
    voided_at = now(), void_reason = trim(p_void_reason)
    where id = p_waste_record_id;

  insert into waste_record_history (waste_record_id, action, before_snapshot, after_snapshot, reason, actor_id, actor_name_snapshot)
    select p_waste_record_id, 'void', to_jsonb(v_record), to_jsonb(wr), trim(p_void_reason), v_actor, v_actor_name
    from waste_records wr where wr.id = p_waste_record_id;
end;
$$;
grant execute on function void_waste_record(uuid, text) to authenticated;

-- ============================================================
-- 8) waste_record_list：歷史查詢頁用，權限用can_manage_waste_record
--    （不是can_view_daily_report——見計畫檔說明，這個歷史頁本來就規劃成只有
--    主管以上看得到，RPC本身也要真的擋，不能只靠前端不顯示分頁）
-- ============================================================
create or replace function waste_record_list(
  p_store_ids uuid[], p_date_from date, p_date_to date,
  p_item text default null, p_reason_code text default null,
  p_created_by uuid default null, p_status text[] default array['active', 'void'],
  p_limit integer default 50, p_offset integer default 0
)
returns table(
  record_id uuid, record_no text, store_id uuid, store_name text, report_date date,
  item_name text, quantity integer, reason_code text, reason_note text, note text,
  status text, created_by_name text, created_at timestamptz,
  photos jsonb, total_count bigint
)
language sql stable security definer set search_path = public as $$
  select wr.id, wr.record_no, wr.store_id, st.name, wr.report_date,
    wr.item_name, wr.quantity, wr.reason_code, wr.reason_note, wr.note,
    wr.status, wr.created_by_name, wr.created_at,
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
    and (p_created_by is null or wr.created_by = p_created_by)
    and can_manage_waste_record(wr.store_id)
  order by wr.created_at desc
  limit p_limit offset p_offset;
$$;
grant execute on function waste_record_list(uuid[], date, date, text, text, uuid, text[], integer, integer) to authenticated;

-- ============================================================
-- 9) waste_item_suggestions：品項搜尋建議，來源是該店過去打過的報廢品項，
--    依出現次數排序，不另建品項資料庫
-- ============================================================
create or replace function waste_item_suggestions(p_store_id uuid, p_query text default '')
returns table(item_name text, use_count bigint)
language sql stable security definer set search_path = public as $$
  select wr.item_name, count(*) as use_count
  from waste_records wr
  where wr.store_id = p_store_id
    and can_fill_daily_report(p_store_id)
    and (p_query is null or p_query = '' or wr.item_name ilike '%' || p_query || '%')
  group by wr.item_name
  order by use_count desc, wr.item_name asc
  limit 10;
$$;
grant execute on function waste_item_suggestions(uuid, text) to authenticated;

-- ============================================================
-- 10) Storage：報廢照片獨立bucket，路徑規則 {store_id}/{waste_record_id}/{檔名}
--     （不是{daily_report_id}/...——見檔頭說明的路徑綁定限制）。不開delete
--     政策，沒有人能透過前端刪除照片。
-- ============================================================
insert into storage.buckets (id, name, public)
values ('waste-record-photos', 'waste-record-photos', false)
on conflict (id) do nothing;

create policy "waste record photos upload" on storage.objects for insert
  with check (
    bucket_id = 'waste-record-photos'
    and can_fill_daily_report(((storage.foldername(name))[1])::uuid)
  );
create policy "waste record photos storage read" on storage.objects for select
  using (
    bucket_id = 'waste-record-photos'
    and can_view_daily_report(((storage.foldername(name))[1])::uuid)
  );

commit;

-- ============================================================
-- 回復方案：只新增3張表＋1個bucket＋6支函式，完全沒有修改既有RPC/表/RLS，
-- 回復很單純——若要撤回，先停用前端新入口（WASTE_RECORDS_READY保持false／
-- 拿掉「新增報廢」按鈕與「今日報廢」區塊），確認沒有進行中的請求後，執行
-- 下面幾行即可，既有每日回報資料與功能完全不受影響：
--
-- drop policy if exists "waste record photos upload" on storage.objects;
-- drop policy if exists "waste record photos storage read" on storage.objects;
-- -- bucket本身與其中已上傳的檔案不要在回復當下一併刪除，先保留，另外評估
-- drop function if exists waste_item_suggestions(uuid, text);
-- drop function if exists waste_record_list(uuid[], date, date, text, text, uuid, text[], integer, integer);
-- drop function if exists void_waste_record(uuid, text);
-- drop function if exists correct_waste_record(uuid, text, text, integer, text, text, text);
-- drop function if exists create_waste_record(uuid, uuid, date, text, text, integer, text, text, text, jsonb);
-- -- can_manage_waste_record()不要跟著drop：waste_record_history表的select政策
-- -- 還依賴它（drop function without cascade在這裡會直接失敗），且不影響
-- -- WASTE_RECORDS_READY=false時的行為（沒有前端會呼叫到它），保留完全無害
-- -- 已成功保存的報廢資料與照片metadata請保留，不因回復而刪除表本身；若確定
-- -- 不再需要，之後再另外評估是否要drop table（不建議在回復當下一併做）。
-- ============================================================

-- ============================================================
-- 待確認事項（請先核對再執行這份migration）：
-- 1. 請核對 can_fill_daily_report／can_view_daily_report／feature_level／
--    is_super_admin／my_store_id／current_employee_id／is_payroll_locked
--    這幾個既有函式名稱與參數簽章跟您資料庫實際定義一致（這次是直接讀取
--    本機 phase-hr_fix_*.sql 歷史檔案得出，套用前請自行核對，例如透過
--    Database → Functions頁面）。
-- 2. stores.code 欄位沒有unique約束，如果之後有兩間門市的code重複，
--    record_no可能會撞號（有unique(record_no)約束保護，撞號時會噴錯誤要求
--    重試，不會產生錯誤資料，但值得留意）。
-- 3. can_manage_waste_record()對「店長PIN」的判定是
--    access_tier='dept_manager' and is_shared_pin_account，請核對這兩個
--    欄位在您資料庫裡的實際用法跟這裡假設的一致（三間門市各自的店長PIN
--    帳號是否都正確設定了這兩個欄位）。
-- ============================================================
