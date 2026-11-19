/*
 * Общий кошелёк — service worker.
 * Keeps the app itself (page, icons) on the phone so it opens even without internet.
 * Always tries the network first, so updates arrive right away.
 * Wallet data (Supabase) is never cached here.
 */
var CACHE = 'koshelek-v7';
var FILES = ['./', 'index.html', 'manifest.webmanifest', 'icon-192.png', 'icon-512.png', 'apple-touch-icon.png'];

self.addEventListener('install', function (e) {
  e.waitUntil(caches.open(CACHE).then(function (c) { return c.addAll(FILES); }).then(function () { return self.skipWaiting(); }));
});

self.addEventListener('activate', function (e) {
  e.waitUntil(caches.keys().then(function (keys) {
    return Promise.all(keys.filter(function (k) { return k !== CACHE; }).map(function (k) { return caches.delete(k); }));
  }).then(function () { return self.clients.claim(); }));
});

self.addEventListener('fetch', function (e) {
  var req = e.request;
  if (req.method !== 'GET' || new URL(req.url).origin !== self.location.origin) return;
  e.respondWith(Promise.race([fetch(req), new Promise(function (_, rej) { setTimeout(rej, 5000); })]).then(function (res) {
    if (res && res.ok) { var copy = res.clone(); caches.open(CACHE).then(function (c) { c.put(req, copy); }); }
    return res;
  }).catch(function () {
    return caches.match(req, { ignoreSearch: true }).then(function (hit) {
      if (hit) return hit;
      if (req.mode === 'navigate') return caches.match('index.html').then(function (p) { return p || Response.error(); });
      return Response.error();
    });
  }));
});

// ---- push notifications
self.addEventListener('push', function (e) {
  var d = {};
  try { d = e.data ? e.data.json() : {}; } catch (x) { d = { title: 'Общий кошелёк', body: e.data ? e.data.text() : '' }; }
  e.waitUntil(self.registration.showNotification(d.title || 'Общий кошелёк', {
    body: d.body || 'Откройте кошелёк', tag: d.tag || undefined, icon: 'icon-192.png', badge: 'icon-192.png', renotify: !!d.tag, data: { url: './' }
  }));
});
self.addEventListener('notificationclick', function (e) {
  e.notification.close();
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(function (list) {
    for (var i = 0; i < list.length; i++) { if ('focus' in list[i]) return list[i].focus(); }
    return self.clients.openWindow('./');
  }));
});

self.addEventListener('pushsubscriptionchange', function (e) {
  // подписка обновится при следующем открытии приложения (refreshPush)
});
