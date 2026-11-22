-- ============================================================
-- 特休剩餘天數：排特休自動連動扣除／取消或駁回時自動補回，管理員可直接
-- 覆寫設定每個人的剩餘天數。
--
-- 背景：既有的 employees.annual_leave_days 是「全年法定額度」（留空則依
-- 到職日年資自動算，isHr可覆寫），系統裡原本沒有任何「剩餘天數」概念——
-- 排特休（門市PIN自助排休 self_schedule_pick_annual_leave，或一般請假
-- 申請經人資核准）核准幾次都不會扣掉任何數字。這次新增 annual_leave_
-- remaining_days 當作即時餘額，用一支掛在 requests 表上的trigger統一
-- 處理所有寫入路徑的連動（不用個別修改3處既有RPC/前端邏輯），餘額不足時
-- 直接擋下（使用者要求，不允許排到負數）。
--
-- 設計依據見 /Users/phase/.claude/plans/refactored-giggling-badger.md
-- （已跟使用者確認過的完整規劃）。範圍刻意不含：特休隨到職週年自動
-- 加碼/重新核發——那是另一個更大的年度結算功能，這次剩餘天數跟現有的
-- 特休天數一樣，只是手動數字，由管理員自行在週年時調整。
--
-- 2026-11-22使用者要求：不只依賴執行工具的隱含交易行為，明確加上
-- BEGIN/COMMIT。
-- 2026-11-22
-- ============================================================

begin;

-- ============================================================
-- 1) 新欄位 + 一次性backfill：所有在職夥伴＝目前的特休天數（填的值優先，
--    沒填則用年資公式即時算一次，公式等價於前端
--    annualLeaveDaysForSeniority()，用age()取代JS手刻的月份差計算）。
--    離職夥伴不backfill，維持null，不影響任何畫面（本來就不會再排休）。
-- ============================================================
alter table employees add column if not exists annual_leave_remaining_days numeric;

with calc as (
  select e.id,
    coalesce(e.annual_leave_days, (
      case
        when e.hire_date is null then 0
        else (
          select case
            when s.months < 6 then 0
            when s.months < 12 then 3
            when s.years < 2 then 7
            when s.years < 3 then 10
            when s.years < 5 then 14
            when s.years < 10 then 15
            else least(30, 15 + (s.years - 9))
          end
          from (select
            extract(year from age(current_date, e.hire_date))::int as years,
            (extract(year from age(current_date, e.hire_date)) * 12
              + extract(month from age(current_date, e.hire_date)))::int as months
          ) s
        )
      end
    )) as remaining
  from employees e where e.active
)
update employees set annual_leave_remaining_days = calc.remaining
from calc where employees.id = calc.id;

-- ============================================================
-- 2) guard_employee_sensitive_write()擴充：annual_leave_remaining_days
--    跟annual_leave_days同等級保護（僅is_super_admin()可直接改），但留一個
--    「系統自動連動」逃生門給下面的trigger用（transaction-local設定值
--    app.annual_leave_balance_sync，一般client無法從Supabase端呼叫
--    set_config，不會被偽造），否則排休扣款會被這支既有guard擋下來
-- ============================================================
create or replace function guard_employee_sensitive_write()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if is_super_admin() then
    return new;
  end if;
  if tg_op = 'INSERT' then
    if new.access_tier <> 'staff' or new.base_salary <> 0 or new.hourly_rate <> 0 or new.bonus <> 0
       or new.meal_allowance <> 0 or new.position_allowance <> 0
       or new.labor_insurance_fee <> 0 or new.health_insurance_fee <> 0 or new.income_tax <> 0
       or new.annual_leave_days is not null or new.annual_leave_remaining_days is not null then
      raise exception '僅最高管理員可設定權限層級與薪資';
    end if;
  elsif tg_op = 'UPDATE' then
    if new.access_tier is distinct from old.access_tier
       or new.store_id is distinct from old.store_id
       or new.base_salary is distinct from old.base_salary
       or new.hourly_rate is distinct from old.hourly_rate
       or new.bonus is distinct from old.bonus
       or new.meal_allowance is distinct from old.meal_allowance
       or new.position_allowance is distinct from old.position_allowance
       or new.labor_insurance_fee is distinct from old.labor_insurance_fee
       or new.health_insurance_fee is distinct from old.health_insurance_fee
       or new.income_tax is distinct from old.income_tax
       or new.annual_leave_days is distinct from old.annual_leave_days then
      raise exception '僅最高管理員可調整權限層級／門市／薪資';
    end if;
    -- 2026-11-22新增：特休剩餘天數是HR專屬可調整欄位，邏輯跟annual_leave_days
    -- 一致，但排特休時由sync_annual_leave_balance() trigger自動連動扣/補，
    -- 該trigger會設定app.annual_leave_balance_sync='on'標記「這是系統自動
    -- 連動寫入，不是使用者手動改」，在這裡放行，不受「僅HR可調整」限制
    if new.annual_leave_remaining_days is distinct from old.annual_leave_remaining_days
       and coalesce(current_setting('app.annual_leave_balance_sync', true), '') <> 'on' then
      raise exception '僅最高管理員可調整特休剩餘天數';
    end if;
  end if;
  return new;
end;
$$;

-- ============================================================
-- 3) sync_annual_leave_balance()：掛在requests表上，統一處理所有「特休
--    核准中天數」異動的連動扣/補，覆蓋現有全部3條寫入路徑（self_schedule
--    自動核准、self_schedule_clear刪除、RequestFormModal人工審核的
--    decide()更新），不需要個別修改這3處前端/RPC程式碼。
-- ============================================================
create or replace function sync_annual_leave_balance()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_employee_id uuid;
  v_old_days numeric := 0;
  v_new_days numeric := 0;
  v_delta numeric;
  v_remaining numeric;
begin
  if tg_op = 'DELETE' then
    v_employee_id := old.employee_id;
    if old.type = 'annual_leave' and old.status = 'approved' then
      v_old_days := coalesce(old.hours, 0) / 8;
    end if;
  elsif tg_op = 'INSERT' then
    v_employee_id := new.employee_id;
    if new.type = 'annual_leave' and new.status = 'approved' then
      v_new_days := coalesce(new.hours, 0) / 8;
    end if;
  else -- UPDATE
    v_employee_id := new.employee_id;
    if old.type = 'annual_leave' and old.status = 'approved' then
      v_old_days := coalesce(old.hours, 0) / 8;
    end if;
    if new.type = 'annual_leave' and new.status = 'approved' then
      v_new_days := coalesce(new.hours, 0) / 8;
    end if;
  end if;

  v_delta := v_new_days - v_old_days;
  if v_delta = 0 then
    return coalesce(new, old);
  end if;

  select annual_leave_remaining_days into v_remaining from employees where id = v_employee_id;
  if v_remaining is null then
    -- 還沒設定過剩餘天數，不扣不擋（等管理員設定第一個值之後才開始連動）
    return coalesce(new, old);
  end if;

  if v_delta > 0 and v_remaining - v_delta < 0 then
    raise exception '特休餘額不足：剩餘 % 天，無法再排 % 天', v_remaining, v_delta;
  end if;

  perform set_config('app.annual_leave_balance_sync', 'on', true);
  update employees set annual_leave_remaining_days = annual_leave_remaining_days - v_delta
    where id = v_employee_id;
  perform set_config('app.annual_leave_balance_sync', 'off', true);

  return coalesce(new, old);
end;
$$;

drop trigger if exists requests_sync_annual_leave_balance on requests;
create trigger requests_sync_annual_leave_balance
  after insert or update or delete on requests
  for each row execute function sync_annual_leave_balance();

-- ============================================================
-- 4) store_roster()擴充：新增回傳annual_leave_remaining_days，讓門市PIN
--    排休頁能顯示剩餘天數。回傳型別變更，CREATE OR REPLACE處理不了，
--    要先drop舊版。
-- ============================================================
drop function if exists store_roster(uuid);

create or replace function store_roster(p_store_id uuid)
returns table(id uuid, name text, "position" text, employment_type text, active boolean, annual_leave_remaining_days numeric)
language sql
stable
security definer
set search_path = public
as $$
  select id, name, "position", employment_type, active, annual_leave_remaining_days from employees
  where store_id = p_store_id
    and not is_shared_pin_account
    and not exclude_from_roster
    and not is_non_employee_account
    and (
      is_super_admin()
      or can_view_schedule(p_store_id)
      or can_view_daily_report(p_store_id)
      or exists (select 1 from stores s where s.id = p_store_id and s.name = '總部')
      or feature_level('schedule') = 'edit'
    )
  order by active desc, hire_date asc nulls last, name;
$$;
grant execute on function store_roster(uuid) to authenticated;

commit;

-- ============================================================
-- 回復方案：
-- drop trigger if exists requests_sync_annual_leave_balance on requests;
-- drop function if exists sync_annual_leave_balance();
-- -- guard_employee_sensitive_write()／store_roster()要手動改回20260810版本
-- -- （沒有另存備份，可從git歷史找回舊定義後重新create or replace）
-- -- annual_leave_remaining_days欄位本身不建議跟著砍，已累積的餘額數字
-- -- 保留，之後要重新啟用隨時可以，不會遺失資料
-- ============================================================
