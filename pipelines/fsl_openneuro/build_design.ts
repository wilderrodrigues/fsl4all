#!/usr/bin/env -S deno run --allow-read --allow-write --allow-run --allow-env=FSLDIR

import * as path from "node:path";

function fail(message: string): never {
  console.error(`ERROR: ${message}`);
  Deno.exit(1);
}

function parseArgs(argv: string[]): Map<string, string> {
  const parsed = new Map<string, string>();
  for (let i = 0; i < argv.length; i += 2) {
    const key = argv[i];
    const value = argv[i + 1];
    if (!key?.startsWith("--") || value === undefined) {
      fail(`Expected --name value pairs; problem near ${key ?? "end of arguments"}`);
    }
    parsed.set(key.slice(2), value);
  }
  return parsed;
}

function required(args: Map<string, string>, name: string): string {
  const value = args.get(name);
  if (!value) fail(`Missing --${name}`);
  return path.resolve(value);
}

function positiveNumber(args: Map<string, string>, name: string): number {
  const raw = args.get(name);
  const value = Number(raw);
  if (!raw || !Number.isFinite(value) || value <= 0) {
    fail(`--${name} must be a positive number`);
  }
  return value;
}

function nonNegativeInteger(args: Map<string, string>, name: string): number {
  const raw = args.get(name);
  const value = Number(raw);
  if (!raw || !Number.isInteger(value) || value < 0) {
    fail(`--${name} must be a non-negative integer`);
  }
  return value;
}

async function fslval(fslDir: string, image: string, field: string): Promise<number> {
  const command = new Deno.Command(path.join(fslDir, "bin", "fslval"), {
    args: [image, field],
    stdout: "piped",
    stderr: "piped",
  });
  const result = await command.output();
  const stderr = new TextDecoder().decode(result.stderr).trim();
  if (!result.success) fail(`fslval ${field} failed for ${image}: ${stderr}`);
  const value = Number(new TextDecoder().decode(result.stdout).trim());
  if (!Number.isFinite(value)) fail(`fslval ${field} returned a non-number for ${image}`);
  return value;
}

function tclQuote(value: string): string {
  return `"${value.replaceAll("\\", "\\\\").replaceAll("\"", "\\\"").replaceAll("$", "\\$").replaceAll("[", "\\[").replaceAll("]", "\\]")}"`;
}

function replaceToken(template: string, token: string, value: string): string {
  if (!template.includes(token)) fail(`Template is missing token ${token}`);
  return template.replaceAll(token, value);
}

const args = parseArgs(Deno.args);
const bold = required(args, "bold");
const metadataFile = required(args, "metadata");
const t1Brain = required(args, "t1-brain");
const templateFile = required(args, "template");
const designOutput = required(args, "design-output");
const sliceOutput = required(args, "slice-output");
const featOutput = required(args, "feat-output");
const smoothFwhm = positiveNumber(args, "smooth-fwhm");
const highpassHz = positiveNumber(args, "highpass-hz");
const fnirtWarpResolution = positiveNumber(args, "fnirt-warp-resolution");
const deleteVolumes = nonNegativeInteger(args, "delete-volumes");
const fslDir = Deno.env.get("FSLDIR");
if (!fslDir) fail("FSLDIR is not set");

for (const input of [bold, metadataFile, t1Brain, templateFile]) {
  try {
    const stat = await Deno.stat(input);
    if (!stat.isFile) fail(`Not a regular, resolved file: ${input}`);
  } catch (error) {
    fail(`Cannot read ${input}: ${error instanceof Error ? error.message : String(error)}`);
  }
}

const metadata = JSON.parse(await Deno.readTextFile(metadataFile));
const tr = Number(metadata.RepetitionTime);
if (!Number.isFinite(tr) || tr <= 0) fail("BOLD JSON has no valid RepetitionTime");
if (!Array.isArray(metadata.SliceTiming) || metadata.SliceTiming.length === 0) {
  fail("BOLD JSON has no SliceTiming array; slice-timing correction cannot be configured safely");
}

let timings: number[] = metadata.SliceTiming.map((value: unknown, index: number) => {
  const timing = Number(value);
  if (!Number.isFinite(timing) || timing < 0 || timing >= tr) {
    fail(`SliceTiming[${index}] must be in seconds within [0, TR)`);
  }
  return timing;
});

const dims = await Promise.all([1, 2, 3, 4].map((axis) => fslval(fslDir, bold, `dim${axis}`)));
const headerTr = await fslval(fslDir, bold, "pixdim4");
const headerSliceDim = await fslval(fslDir, bold, "slice_dim");
if (dims[3] <= 1) fail("BOLD input is not a 4D time series");
if (deleteVolumes >= dims[3]) fail("delete-volumes must be smaller than the number of BOLD volumes");
if (Math.abs(headerTr - tr) > 0.0001) {
  fail(`TR mismatch: JSON=${tr}, NIfTI header=${headerTr}`);
}

let sliceAxis: number;
const sliceDirection = metadata.SliceEncodingDirection;
if (sliceDirection !== undefined) {
  const match = /^([ijk])(-)?$/.exec(String(sliceDirection));
  if (!match) fail(`Invalid SliceEncodingDirection: ${sliceDirection}`);
  sliceAxis = { i: 1, j: 2, k: 3 }[match[1] as "i" | "j" | "k"];
  if (match[2] === "-") timings = timings.reverse();
  if (headerSliceDim > 0 && headerSliceDim !== sliceAxis) {
    fail(`SliceEncodingDirection axis ${sliceAxis} disagrees with NIfTI slice_dim ${headerSliceDim}`);
  }
} else if ([1, 2, 3].includes(headerSliceDim)) {
  sliceAxis = headerSliceDim;
} else {
  const matchingAxes = dims.slice(0, 3)
    .map((size, index) => ({ size, axis: index + 1 }))
    .filter(({ size }) => size === timings.length);
  if (matchingAxes.length !== 1) {
    fail("Cannot infer the slice axis uniquely from SliceTiming and NIfTI dimensions");
  }
  sliceAxis = matchingAxes[0].axis;
}

if (timings.length !== dims[sliceAxis - 1]) {
  fail(`SliceTiming has ${timings.length} entries but slice dimension ${sliceAxis} has ${dims[sliceAxis - 1]} slices`);
}

// FEAT/slicetimer expects fractional-TR shifts to the middle of the TR.
const shifts: number[] = timings.map((timing: number) => 0.5 - timing / tr);
for (const [index, shift] of shifts.entries()) {
  if (shift < -0.500001 || shift > 0.500001) {
    fail(`Computed slice shift ${index} is outside FEAT's expected [-0.5, 0.5] range`);
  }
}

await Deno.mkdir(path.dirname(sliceOutput), { recursive: true });
await Deno.mkdir(path.dirname(designOutput), { recursive: true });
await Deno.writeTextFile(sliceOutput, `${shifts.map((value: number) => value.toFixed(9)).join("\n")}\n`, { createNew: true });

const standardBrain = path.join(fslDir, "data", "standard", "MNI152_T1_2mm_brain.nii.gz");
const totalVoxels = dims.reduce((product, value) => product * value, 1);
let design = await Deno.readTextFile(templateFile);
const replacements = new Map<string, string>([
  ["__OUTPUT_DIR__", tclQuote(featOutput)],
  ["__TR__", tr.toString()],
  ["__NPTS__", dims[3].toString()],
  ["__DELETE_VOLUMES__", deleteVolumes.toString()],
  ["__TOTAL_VOXELS__", totalVoxels.toString()],
  ["__SLICE_TIMING_FILE__", tclQuote(sliceOutput)],
  ["__SLICE_AXIS__", sliceAxis.toString()],
  ["__SMOOTH_FWHM_MM__", smoothFwhm.toString()],
  ["__HIGHPASS_SECONDS__", (1 / highpassHz).toString()],
  ["__STANDARD_BRAIN__", tclQuote(standardBrain)],
  ["__FNIRT_WARP_RESOLUTION_MM__", fnirtWarpResolution.toString()],
  ["__BOLD_FILE__", tclQuote(bold)],
  ["__T1_BRAIN_FILE__", tclQuote(t1Brain)],
]);
for (const [token, value] of replacements) design = replaceToken(design, token, value);
if (/__[A-Z0-9_]+__/.test(design)) fail("Unresolved placeholder remains in generated design");

const provenance = `# Generated from ${metadataFile}\n# SliceTiming entries: ${timings.length}; slice axis: ${sliceAxis}; target: middle of TR\n`;
await Deno.writeTextFile(designOutput, provenance + design, { createNew: true });

console.log(`Generated ${sliceOutput}`);
console.log(`Generated ${designOutput}`);
console.log(`TR=${tr}s, volumes=${dims[3]}, slices=${timings.length}, slice axis=${sliceAxis}`);
