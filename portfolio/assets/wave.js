/* Waveform for the portfolio's audio players (voice demo, voice workbench), after Krea's recorder: thin centred bars
   drawn from the audio itself, a dotted line where it is quiet, the played part in ink and the rest muted.
   MCWave(el, src, { audio, time }) binds to an <audio>/Audio: it follows playback, writes "00:04 / 00:15" into
   `time`, and seeks on click, drag and the arrow keys. Colours come from --wave-played and --wave-rest on el. */
(function () {
  const BAR = 1.5;
  const STEP = 3.5; // bar + gap, in CSS pixels
  const QUIET = 0.05; // below this share of the loudest peak, draw the dotted line instead of a bar

  const fmt = (t) => {
    t = Math.max(0, Math.floor(t || 0));
    return String(Math.floor(t / 60)).padStart(2, '0') + ':' + String(t % 60).padStart(2, '0');
  };

  // Loudest sample per bucket, scaled so the loudest bucket is 1.
  function peaks(buffer, buckets) {
    const d = buffer.getChannelData(0);
    const size = Math.max(1, Math.floor(d.length / buckets));
    const out = new Float32Array(buckets);
    let max = 0;
    for (let i = 0; i < buckets; i++) {
      let p = 0;
      const end = Math.min(d.length, (i + 1) * size);
      for (let j = i * size; j < end; j++) {
        const v = d[j] < 0 ? -d[j] : d[j];
        if (v > p) p = v;
      }
      out[i] = p;
      if (p > max) max = p;
    }
    if (max > 0) for (let i = 0; i < buckets; i++) out[i] /= max;
    return out;
  }

  function decode(src) {
    const Offline = window.OfflineAudioContext || window.webkitOfflineAudioContext;
    if (!Offline) return Promise.reject(new Error('no Web Audio'));
    return fetch(src)
      .then((r) => r.arrayBuffer())
      .then((b) => new Promise((ok, no) => new Offline(1, 2, 44100).decodeAudioData(b, ok, no)))
      .then((buf) => peaks(buf, 1200));
  }

  window.MCWave = function (el, src, opts) {
    const audio = opts.audio;
    const timeEl = opts.time;
    const canvas = document.createElement('canvas');
    canvas.setAttribute('aria-hidden', 'true');
    el.appendChild(canvas);
    el.setAttribute('role', 'slider');
    el.setAttribute('tabindex', '0');
    el.setAttribute('aria-valuemin', '0');
    el.setAttribute('aria-valuemax', '100');
    if (!el.hasAttribute('aria-label')) el.setAttribute('aria-label', 'Seek');

    let data = null;
    let raf = 0;

    const progress = () => (audio.duration ? audio.currentTime / audio.duration : 0);

    function draw() {
      const w = el.clientWidth;
      const h = el.clientHeight;
      if (!w || !h) return;
      const dpr = window.devicePixelRatio || 1;
      if (canvas.width !== Math.round(w * dpr) || canvas.height !== Math.round(h * dpr)) {
        canvas.width = Math.round(w * dpr);
        canvas.height = Math.round(h * dpr);
        canvas.style.width = w + 'px';
        canvas.style.height = h + 'px';
      }
      const g = canvas.getContext('2d');
      g.setTransform(dpr, 0, 0, dpr, 0, 0);
      g.clearRect(0, 0, w, h);
      const cs = getComputedStyle(el);
      const played = cs.getPropertyValue('--wave-played').trim() || '#1b1712';
      const rest = cs.getPropertyValue('--wave-rest').trim() || '#c9bfae';
      const n = Math.floor(w / STEP);
      const mid = h / 2;
      const at = progress() * w;
      for (let i = 0; i < n; i++) {
        const x = i * STEP;
        let v = 0;
        if (data) {
          const a = Math.floor((i / n) * data.length);
          const b = Math.max(a + 1, Math.floor(((i + 1) / n) * data.length));
          for (let k = a; k < b; k++) if (data[k] > v) v = data[k];
        }
        g.fillStyle = x < at ? played : rest;
        if (v < QUIET) {
          g.fillRect(x, mid - 0.5, 1, 1);
        } else {
          const bh = Math.max(3, v * (h - 2));
          g.fillRect(x, mid - bh / 2, BAR, bh);
        }
      }
      el.setAttribute('aria-valuenow', String(Math.round(progress() * 100)));
      el.setAttribute('aria-valuetext', fmt(audio.currentTime) + ' of ' + fmt(audio.duration));
      if (timeEl) timeEl.textContent = fmt(audio.currentTime) + ' / ' + fmt(audio.duration);
    }

    function loop() {
      draw();
      raf = audio.paused ? 0 : requestAnimationFrame(loop);
    }
    audio.addEventListener('play', () => {
      if (!raf) raf = requestAnimationFrame(loop);
    });
    ['pause', 'ended', 'seeked', 'loadedmetadata', 'durationchange'].forEach((e) => audio.addEventListener(e, draw));

    function seekTo(clientX) {
      if (!audio.duration) return;
      const r = el.getBoundingClientRect();
      audio.currentTime = Math.min(1, Math.max(0, (clientX - r.left) / r.width)) * audio.duration;
      draw();
    }
    el.addEventListener('pointerdown', (e) => {
      el.setPointerCapture(e.pointerId);
      seekTo(e.clientX);
      const move = (m) => seekTo(m.clientX);
      const up = () => {
        el.removeEventListener('pointermove', move);
        el.removeEventListener('pointerup', up);
        el.removeEventListener('pointercancel', up);
      };
      el.addEventListener('pointermove', move);
      el.addEventListener('pointerup', up);
      el.addEventListener('pointercancel', up);
    });
    el.addEventListener('keydown', (e) => {
      if (!audio.duration) return;
      const d = { ArrowRight: 5, ArrowUp: 5, ArrowLeft: -5, ArrowDown: -5 }[e.key];
      if (d) {
        e.preventDefault();
        audio.currentTime = Math.min(audio.duration, Math.max(0, audio.currentTime + d));
      } else if (e.key === 'Home' || e.key === 'End') {
        e.preventDefault();
        audio.currentTime = e.key === 'Home' ? 0 : audio.duration;
      }
    });

    if ('ResizeObserver' in window) new ResizeObserver(draw).observe(el);
    draw();
    decode(src)
      .then((p) => {
        data = p;
        draw();
      })
      .catch(() => {}); // the dotted line stays; playback is unaffected

    return { draw };
  };
})();
