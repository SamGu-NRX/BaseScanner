// Reads the vertex positions of a PLY point cloud: ascii, binary little-endian or binary
// big-endian. It keeps x, y, z and an optional per-point `generated` flag, which marks points the
// server filled in rather than observed. Anything else throws PlyError, and the viewer then says
// the preview is unavailable instead of drawing a guess.

export class PlyError extends Error {}

const SIZES = {
  char: 1, int8: 1, uchar: 1, uint8: 1,
  short: 2, int16: 2, ushort: 2, uint16: 2,
  int: 4, int32: 4, uint: 4, uint32: 4, float: 4, float32: 4,
  double: 8, float64: 8,
};

/**
 * @param {ArrayBuffer} buffer
 * @param {{ maxPoints?: number }} [options] keeps every n-th point so at most maxPoints remain
 * @returns {{ count: number, kept: number, positions: Float32Array, generated: Uint8Array | null, bounds: { min: number[], max: number[] } | null }}
 */
export function parsePly(buffer, { maxPoints = 60_000 } = {}) {
  const bytes = new Uint8Array(buffer);
  const headerEnd = findHeaderEnd(bytes);
  const header = new TextDecoder("ascii").decode(bytes.subarray(0, headerEnd)).split(/\r?\n/);
  if (header[0]?.trim() !== "ply") throw new PlyError("not a PLY file");

  let format = null;
  const elements = [];
  for (const raw of header.slice(1)) {
    const parts = raw.trim().split(/\s+/);
    if (parts[0] === "format") format = parts[1];
    else if (parts[0] === "element") elements.push({ name: parts[1], count: Number(parts[2]), props: [] });
    else if (parts[0] === "property") {
      const element = elements.at(-1);
      if (!element) throw new PlyError("property before any element");
      if (parts[1] === "list") element.props.push({ list: true, name: parts[4] });
      else element.props.push({ type: parts[1], name: parts[2] });
    }
  }
  if (!["ascii", "binary_little_endian", "binary_big_endian"].includes(format)) {
    throw new PlyError(`unsupported PLY format ${format ?? "(none)"}`);
  }
  const vertex = elements[0];
  if (!vertex || vertex.name !== "vertex") throw new PlyError("the first element is not vertex");
  if (!Number.isInteger(vertex.count) || vertex.count < 0) throw new PlyError("bad vertex count");
  // A zero-point cloud may declare no properties at all; it is empty, not unreadable.
  if (vertex.count === 0) return { count: 0, kept: 0, positions: new Float32Array(0), generated: null, bounds: null };
  if (vertex.props.some((p) => p.list)) throw new PlyError("vertex has a list property");
  for (const p of vertex.props) if (!(p.type in SIZES)) throw new PlyError(`unknown property type ${p.type}`);
  const index = Object.fromEntries(vertex.props.map((p, i) => [p.name, i]));
  if (index.x == null || index.y == null || index.z == null) throw new PlyError("vertex lacks x, y or z");

  const count = vertex.count;
  const stride = Math.max(1, Math.ceil(count / maxPoints));
  const kept = Math.ceil(count / stride);
  const positions = new Float32Array(kept * 3);
  const hasGenerated = index.generated != null;
  const generated = hasGenerated ? new Uint8Array(kept) : null;

  const read = format === "ascii" ? asciiReader(bytes, headerEnd, vertex) : binaryReader(bytes, headerEnd, vertex, format === "binary_little_endian");
  let k = 0;
  for (let i = 0; i < count; i += 1) {
    const row = read(i);
    if (i % stride !== 0) continue;
    positions[k * 3] = row[index.x];
    positions[k * 3 + 1] = row[index.y];
    positions[k * 3 + 2] = row[index.z];
    // Checked after the 32-bit conversion: NaN, infinity or a value too large for a float cannot
    // be drawn and would poison the bounds, so that point is skipped (the next one overwrites it).
    if (!Number.isFinite(positions[k * 3]) || !Number.isFinite(positions[k * 3 + 1]) || !Number.isFinite(positions[k * 3 + 2])) continue;
    if (generated) generated[k] = row[index.generated] ? 1 : 0;
    k += 1;
  }
  return { count, kept: k, positions, generated, bounds: boundsOf(positions, k) };
}

/** Byte offset just past the header line that is exactly `end_header`. */
function findHeaderEnd(bytes) {
  const limit = Math.min(bytes.length, 64 * 1024);
  let start = 0;
  for (let i = 0; i < limit; i += 1) {
    if (bytes[i] !== 0x0a) continue;
    const line = new TextDecoder("ascii").decode(bytes.subarray(start, i)).replace(/\r$/, "").trim();
    if (line === "end_header") return i + 1;
    start = i + 1;
  }
  throw new PlyError("no end_header line in the first 64 KiB");
}

function binaryReader(bytes, offset, vertex, little) {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const sizes = vertex.props.map((p) => SIZES[p.type]);
  const rowBytes = sizes.reduce((a, b) => a + b, 0);
  if (offset + rowBytes * vertex.count > bytes.length) throw new PlyError("file is shorter than its vertex count");
  const row = new Array(vertex.props.length);
  return (i) => {
    let at = offset + i * rowBytes;
    for (let j = 0; j < vertex.props.length; j += 1) {
      row[j] = readScalar(view, at, vertex.props[j].type, little);
      at += sizes[j];
    }
    return row;
  };
}

function readScalar(view, at, type, little) {
  switch (type) {
    case "char": case "int8": return view.getInt8(at);
    case "uchar": case "uint8": return view.getUint8(at);
    case "short": case "int16": return view.getInt16(at, little);
    case "ushort": case "uint16": return view.getUint16(at, little);
    case "int": case "int32": return view.getInt32(at, little);
    case "uint": case "uint32": return view.getUint32(at, little);
    case "float": case "float32": return view.getFloat32(at, little);
    default: return view.getFloat64(at, little);
  }
}

function asciiReader(bytes, offset, vertex) {
  const lines = new TextDecoder("ascii").decode(bytes.subarray(offset)).split(/\r?\n/);
  return (i) => {
    const line = lines[i];
    if (line == null) throw new PlyError("file is shorter than its vertex count");
    const row = line.trim().split(/\s+/).map(Number);
    if (row.length < vertex.props.length || row.some(Number.isNaN)) throw new PlyError(`bad vertex line ${i + 1}`);
    return row;
  };
}

function boundsOf(positions, n) {
  if (n === 0) return null;
  const min = [Infinity, Infinity, Infinity];
  const max = [-Infinity, -Infinity, -Infinity];
  for (let i = 0; i < n; i += 1) {
    for (let a = 0; a < 3; a += 1) {
      const v = positions[i * 3 + a];
      if (v < min[a]) min[a] = v;
      if (v > max[a]) max[a] = v;
    }
  }
  return { min, max };
}
