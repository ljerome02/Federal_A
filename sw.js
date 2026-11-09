/* Service worker : permet d'ouvrir l'application sans réseau.
   - la page et la bibliothèque Supabase sont gardées en cache (réseau d'abord, cache en secours) ;
   - l'API Supabase (données) n'est jamais mise en cache ici : l'application gère elle-même
     son état hors connexion (dernières données connues, file d'attente des pointages). */
const CACHE = 'fa-v1';
const CDN = 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/dist/umd/supabase.js';

self.addEventListener('install', e => {
  e.waitUntil(
    caches.open(CACHE)
      .then(c => Promise.all(['./', './index.html', CDN].map(u => c.add(u).catch(() => {}))))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys()
      .then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', e => {
  const r = e.request;
  if (r.method !== 'GET') return;
  const u = new URL(r.url);
  if (u.hostname.endsWith('supabase.co')) return;           // données : jamais en cache
  if (u.origin !== self.location.origin && r.url !== CDN) return;
  const reseau = fetch(r);
  const delai = new Promise((_, rej) => setTimeout(() => rej(new Error('timeout')), 4000));
  e.respondWith(
    Promise.race([reseau, delai])
      .then(res => {
        if (res && res.ok) { const copie = res.clone(); caches.open(CACHE).then(c => c.put(r, copie)); }
        return res;
      })
      .catch(() => caches.match(r, { ignoreSearch: true })
        .then(m => m || (r.mode === 'navigate' ? caches.match('./index.html') : Response.error())))
  );
});
