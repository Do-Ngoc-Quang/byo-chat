// Web Worker chạy lõi chatcore (WASM). Giao thức: {id, op, args} -> {id, result} | {id, error}.
// op "open" (args[0] = identity) tạo thiết bị; op "call" (args = [tên thao tác, byte đã đóng gói])
// gọi `WasmCore.call`; op khác là hàm tự do của module (ví dụ core_version).
// `pkg/` do `wasm-pack build wasm --target web --out-dir ../../app/web/pkg` sinh ra.
import init, * as core from './pkg/chatcore_wasm.js';

const ready = init();
let device = null;

self.onmessage = async (e) => {
  const { id, op, args } = e.data;
  try {
    await ready;
    let result;
    if (op === 'open') {
      if (device) throw new Error('đã open');
      device = new core.WasmCore(args[0]);
    } else if (op === 'open_device') {
      if (device) throw new Error('đã open');
      device = core.WasmCore.open_device(args[0]);
    } else if (op === 'open_restore') {
      if (device) throw new Error('đã open');
      device = core.WasmCore.open_restore(args[0]);
    } else if (op === 'call') {
      if (!device) throw new Error('chưa open');
      result = device.call(args[0], args[1]);
    } else if (typeof core[op] === 'function') {
      result = core[op](...(args ?? []));
    } else {
      throw new Error(`op không tồn tại: ${op}`);
    }
    self.postMessage({ id, result });
  } catch (err) {
    self.postMessage({ id, error: String(err?.message ?? err) });
  }
};
