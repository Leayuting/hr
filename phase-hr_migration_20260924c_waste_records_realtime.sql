-- ============================================================
-- 補上報廢紀錄3張表的Realtime發布——原本20260924_waste_records.sql漏掉這步，
-- 導致DailyReportDetail裡「今日報廢」區塊的postgres_changes訂閱從未真正
-- 觸發過（訂閱程式碼本身沒問題，只是表沒有被發布，訊息永遠不會送到訂閱端），
-- 送出成功後畫面不會自動更新，要等元件重新mount（切換日期/門市、重新整理）
-- 才會看到新資料。
--
-- 純粹新增訂閱範圍，不改任何表結構/RPC/RLS/既有資料，已套用並核對過。
-- 2026-09-24
-- ============================================================

alter publication supabase_realtime add table
  waste_records, waste_record_photos, waste_record_history;

-- 回復方式：alter publication supabase_realtime drop table
--   waste_records, waste_record_photos, waste_record_history;
