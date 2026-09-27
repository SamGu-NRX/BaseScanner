import assert from "node:assert/strict";
import { test } from "node:test";
import { PlyError, parsePly } from "../public/ply.js";
import { encodePly } from "../public/scenario.js";

const buf = (text) => new TextEncoder().encode(text).buffer;

test("reads ascii vertices", () => {
  const cloud = parsePly(buf("ply\nformat ascii 1.0\nelement vertex 2\nproperty float x\nproperty float y\nproperty float z\nend_header\n1 2 3\n4 5 6\n"));
  assert.equal(cloud.count, 2);
  assert.deepEqual([...cloud.positions], [1, 2, 3, 4, 5, 6]);
  assert.equal(cloud.generated, null);
  assert.deepEqual(cloud.bounds, { min: [1, 2, 3], max: [4, 5, 6] });
});

test("reads binary little-endian with a generated flag", () => {
  const cloud = parsePly(encodePly([[1, 2, 3, 0], [-1, 0.5, 2, 1]]).buffer);
  assert.equal(cloud.count, 2);
  assert.deepEqual([...cloud.generated], [0, 1]);
  assert.equal(cloud.positions[3], -1);
});

test("reads binary big-endian doubles", () => {
  const head = new TextEncoder().encode("ply\nformat binary_big_endian 1.0\nelement vertex 1\nproperty double x\nproperty double y\nproperty double z\nend_header\n");
  const out = new Uint8Array(head.length + 24);
  out.set(head);
  const view = new DataView(out.buffer);
  [7, 8, 9].forEach((v, i) => view.setFloat64(head.length + i * 8, v, false));
  assert.deepEqual([...parsePly(out.buffer).positions], [7, 8, 9]);
});

test("a comment that mentions end_header does not end the header", () => {
  const cloud = parsePly(buf("ply\nformat ascii 1.0\ncomment written before end_header was known\nelement vertex 1\nproperty float x\nproperty float y\nproperty float z\nend_header\n1 2 3\n"));
  assert.deepEqual([...cloud.positions], [1, 2, 3]);
});

test("non-finite coordinates are skipped", () => {
  const cloud = parsePly(encodePly([[1, 2, 3, 0], [Number.POSITIVE_INFINITY, 0, 0, 0], [Number.NaN, 1, 1, 0], [4, 5, 6, 1]]).buffer);
  assert.equal(cloud.count, 4);
  assert.equal(cloud.kept, 2);
  assert.deepEqual(cloud.bounds, { min: [1, 2, 3], max: [4, 5, 6] });
  assert.deepEqual([...cloud.generated.slice(0, 2)], [0, 1]);
});

test("coordinates too large for a 32-bit float are skipped", () => {
  const cloud = parsePly(buf("ply\nformat ascii 1.0\nelement vertex 2\nproperty double x\nproperty double y\nproperty double z\nend_header\n1e300 0 0\n1 2 3\n"));
  assert.equal(cloud.kept, 1);
  assert.deepEqual(cloud.bounds, { min: [1, 2, 3], max: [1, 2, 3] });
});

test("an empty cloud parses as zero points", () => {
  const cloud = parsePly(buf("ply\nformat ascii 1.0\nelement vertex 0\nend_header\n"));
  assert.equal(cloud.count, 0);
  assert.equal(cloud.bounds, null);
});

test("rows between stride picks are not decoded", () => {
  // Row 1 is malformed; with a stride of 2 it is skipped rather than rejected.
  const cloud = parsePly(buf("ply\nformat ascii 1.0\nelement vertex 3\nproperty float x\nproperty float y\nproperty float z\nend_header\n1 2 3\nnot a row\n4 5 6\n"), { maxPoints: 2 });
  assert.equal(cloud.kept, 2);
  assert.deepEqual([...cloud.positions], [1, 2, 3, 4, 5, 6]);
});

test("keeps at most maxPoints by stride", () => {
  const points = Array.from({ length: 1000 }, (_, i) => [i, 0, 0, 0]);
  const cloud = parsePly(encodePly(points).buffer, { maxPoints: 100 });
  assert.equal(cloud.count, 1000);
  assert.equal(cloud.kept, 100);
  assert.equal(cloud.positions[3], 10);
});

test("refuses what it cannot read", () => {
  const cases = {
    "not a ply": "hello\nend_header\n",
    "no end_header": "ply\nformat ascii 1.0\n",
    "unknown format": "ply\nformat binary_middle_endian 1.0\nelement vertex 1\nproperty float x\nproperty float y\nproperty float z\nend_header\n",
    "no z": "ply\nformat ascii 1.0\nelement vertex 1\nproperty float x\nproperty float y\nend_header\n1 2\n",
    "faces first": "ply\nformat ascii 1.0\nelement face 1\nproperty list uchar int vertex_indices\nelement vertex 1\nproperty float x\nproperty float y\nproperty float z\nend_header\n",
    "short ascii": "ply\nformat ascii 1.0\nelement vertex 2\nproperty float x\nproperty float y\nproperty float z\nend_header\n1 2 3\n",
  };
  for (const [name, text] of Object.entries(cases)) {
    assert.throws(() => parsePly(buf(text)), PlyError, name);
  }
  const truncated = encodePly([[1, 2, 3, 0], [4, 5, 6, 0]]).slice(0, -5);
  assert.throws(() => parsePly(truncated.buffer), PlyError);
});
