// no-op service worker：只為了讓瀏覽器判定「可安裝」，不攔截 fetch、不做快取。
// 這個工具即時讀寫 Supabase，快取住舊資料的風險比多一次網路請求嚴重得多。
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', () => self.clients.claim());
