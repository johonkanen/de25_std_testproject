// The scope's stream, off the page's thread (after the Ti60's collect_worker.js): the
// WebSocket to the board's port 5004, and every sample made into 1 ms points (each
// channel's minimum and maximum) here, so the page's drawing or a busy tab cannot hold up
// the reading: the board's ring holds seconds, not minutes.
//
// From the page: {type: 'start', url, rate, unsigned: [8 booleans]}, {type: 'stop'},
//   {type: 'raw', on} (the messages as they come too, for a raw recording).
// To the page: {type: 'open'}; {type: 'points', count, values, bytes, samples} after each
//   message: count points, values 16 floats a point (min, max of each channel);
//   {type: 'raw', buffer} (transferred); {type: 'closed', code, reason}.
'use strict';

const CHANNELS = 8;
let socket = null;
let raw = false;
let s = null;

function take(data) {
  const n = data.length / CHANNELS;
  const out = [];
  let at = 0;
  while (at < n) {
    const end = Math.min(n, at + (s.next - s.samples));    // where this point ends, or the data
    for (let c = 0; c < CHANNELS; c++) {
      let min = s.min[c], max = s.max[c];
      const mask = s.unsigned[c] ? 0xffff : -1;
      for (let i = at * CHANNELS + c, last = end * CHANNELS; i < last; i += CHANNELS) {
        const v = data[i] & mask;
        if (v < min) min = v;
        if (v > max) max = v;
      }
      s.min[c] = min; s.max[c] = max;
    }
    s.samples += end - at;
    at = end;
    if (s.samples === s.next) {
      for (let c = 0; c < CHANNELS; c++) {
        out.push(s.min[c], s.max[c]);
        s.min[c] = Infinity; s.max[c] = -Infinity;
      }
      s.count++;
      s.next = Math.floor((s.count + 1) * s.perMs);
    }
  }
  return new Float32Array(out);
}

onmessage = (event) => {
  const m = event.data;
  if (m.type === 'start' && !socket) {
    s = {perMs: m.rate / 1000, samples: 0, next: Math.max(1, Math.floor(m.rate / 1000)), count: 0, bytes: 0,
         unsigned: m.unsigned,
         min: new Float64Array(CHANNELS).fill(Infinity), max: new Float64Array(CHANNELS).fill(-Infinity)};
    if (s.perMs < 1) s.perMs = 1;          // under 1 kS/s: a point per sample
    socket = new WebSocket(m.url);
    socket.binaryType = 'arraybuffer';
    socket.onopen = () => postMessage({type: 'open'});
    socket.onmessage = (e) => {
      if (!(e.data instanceof ArrayBuffer)) return;
      s.bytes += e.data.byteLength;
      const values = take(new Int16Array(e.data));
      postMessage({type: 'points', count: values.length / (CHANNELS * 2), values, bytes: s.bytes,
                   samples: s.samples}, [values.buffer]);
      if (raw) postMessage({type: 'raw', buffer: e.data}, [e.data]);
    };
    socket.onclose = (e) => {
      socket = null;
      postMessage({type: 'closed', code: e.code, reason: e.reason});
    };
  } else if (m.type === 'stop' && socket) {
    socket.close(1000, 'stopped');
  } else if (m.type === 'raw') {
    raw = m.on;
  }
};
