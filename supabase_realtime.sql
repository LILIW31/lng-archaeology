-- LNG 考古資料庫：啟用即時同步
-- 在 Supabase Dashboard → SQL Editor 執行一次

alter table public.lng_entries enable row level security;

-- 確保前端可以讀取與提交
create policy if not exists "public can read LNG entries"
on public.lng_entries for select using (true);

create policy if not exists "public can submit LNG entries"
on public.lng_entries for insert with check (true);

-- 讓 Supabase Realtime 監聽這張表
alter publication supabase_realtime add table public.lng_entries;

-- 若已經加入 publication，最後一行可能顯示 already member；這不影響使用。