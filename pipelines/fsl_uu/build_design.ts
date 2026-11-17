#!/usr/bin/env -S deno run --allow-read --allow-write --allow-run --allow-env=FSLDIR

import * as path from "node:path";

function fail(message: string): never {
  console.error(`ERROR: ${message}`);
  Deno.exit(1);
}

function parseArgs(argv: string[]): Map<string, string> {
  const parsed = new Map<string, string>();
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index];
    const value = argv[index + 1];
    if (!key?.startsWith("--") || value === undefined) {
      fail(
        `Expected --name value pairs; problem near ${
          key ?? "end of arguments"
        }`,
      );
    }
    parsed.set(key.slice(2), value);
  }
  return parsed;
}

function required(args: Map<string, string>, name: string): string {
  const value = args.get(name);
  if (!value) fail(`Missing --${name}`);
  return value;
}

function requiredPath(args: Map<string, string>, name: string): string {
  return path.resolve(required(args, name));
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

async function requireRegularFile(filename: string): Promise<void> {
  try {
    const stat = await Deno.stat(filename);
    if (!stat.isFile) fail(`Not a regular file: ${filename}`);
  } catch (error) {
    fail(
      `Cannot read ${filename}: ${
        error instanceof Error ? error.message : String(error)
      }`,
    );
  }
}

async function fslval(
  fslDir: string,
  image: string,
  field: string,
): Promise<number> {
  const command = new Deno.Command(path.join(fslDir, "bin", "fslval"), {
    args: [image, field],
    stdout: "piped",
    stderr: "piped",
  });
  const result = await command.output();
  const stderr = new TextDecoder().decode(result.stderr).trim();
  if (!result.success) fail(`fslval ${field} failed for ${image}: ${stderr}`);
  const value = Number(new TextDecoder().decode(result.stdout).trim());
  if (!Number.isFinite(value)) {
    fail(`fslval ${field} returned a non-number for ${image}`);
  }
  return value;
}

function tclQuote(value: string): string {
  return `"${
    value.replaceAll("\\", "\\\\").replaceAll('"', '\\"').replaceAll("$", "\\$")
      .replaceAll("[", "\\[").replaceAll("]", "\\]")
  }"`;
}

function replaceToken(template: string, token: string, value: string): string {
  if (!template.includes(token)) fail(`Template is missing token ${token}`);
  return template.replaceAll(token, value);
}

function timingShiftsFromMetadata(
  metadata: Record<string, unknown>,
  tr: number,
  sliceCount: number,
): number[] {
  if (
    !Array.isArray(metadata.SliceTiming) || metadata.SliceTiming.length === 0
  ) {
    fail(
      "SLICE_TIMING_MODE=metadata was requested, but the JSON has no SliceTiming array",
    );
  }
  if (metadata.SliceTiming.length !== sliceCount) {
    fail(
      `SliceTiming has ${metadata.SliceTiming.length} entries; expected ${sliceCount}`,
    );
  }
  return metadata.SliceTiming.map((raw: unknown, index: number) => {
    const timing = Number(raw);
    if (!Number.isFinite(timing) || timing < 0 || timing >= tr) {
      fail(`SliceTiming[${index}] must be in seconds within [0, TR)`);
    }
    return 0.5 - timing / tr;
  });
}

async function timingShiftsFromCustomFile(
  filename: string,
  sliceCount: number,
): Promise<number[]> {
  await requireRegularFile(filename);
  const text = await Deno.readTextFile(filename);
  const values = text.split(/\s+/).filter((value) => value.length > 0).map(
    Number,
  );
  if (values.length !== sliceCount) {
    fail(
      `Custom slice-timing file has ${values.length} values; expected ${sliceCount}`,
    );
  }
  values.forEach((value, index) => {
    if (!Number.isFinite(value) || value < -0.500001 || value > 0.500001) {
      fail(`Custom timing value ${index} must be within [-0.5, 0.5]`);
    }
  });
  return values;
}

const args = parseArgs(Deno.args);
const bold = requiredPath(args, "bold");
const metadataFile = requiredPath(args, "metadata");
const t1Brain = requiredPath(args, "t1-brain");
const templateFile = requiredPath(args, "template");
const designOutput = requiredPath(args, "design-output");
const sliceOutput = requiredPath(args, "slice-output");
const featOutput = requiredPath(args, "feat-output");
const sliceTimingMode = required(args, "slice-timing-mode");
const customTimingRaw = args.get("custom-slice-timing") ?? "";
const smoothFwhm = positiveNumber(args, "smooth-fwhm");
const highpassHz = positiveNumber(args, "highpass-hz");
const fnirtWarpResolution = positiveNumber(args, "fnirt-warp-resolution");
const deleteVolumes = nonNegativeInteger(args, "delete-volumes");
const fslDir = Deno.env.get("FSLDIR");
if (!fslDir) fail("FSLDIR is not set");

for (const input of [bold, metadataFile, t1Brain, templateFile]) {
  await requireRegularFile(input);
}

const metadata = JSON.parse(await Deno.readTextFile(metadataFile));
const tr = Number(metadata.RepetitionTime);
if (!Number.isFinite(tr) || tr <= 0) {
  fail("Functional JSON has no valid RepetitionTime");
}

const dims = await Promise.all(
  [1, 2, 3, 4].map((axis) => fslval(fslDir, bold, `dim${axis}`)),
);
const headerTr = await fslval(fslDir, bold, "pixdim4");
const headerSliceDim = await fslval(fslDir, bold, "slice_dim");
if (dims[3] <= 1) fail("Functional input is not a 4D time series");
if (deleteVolumes >= dims[3]) {
  fail("delete-volumes must be smaller than the number of functional volumes");
}
if (Math.abs(headerTr - tr) > 0.0001) {
  fail(`TR mismatch: JSON=${tr}, NIfTI header=${headerTr}`);
}

let sliceAxis = headerSliceDim;
if (![1, 2, 3].includes(sliceAxis)) {
  const timingCount = Array.isArray(metadata.SliceTiming)
    ? metadata.SliceTiming.length
    : 0;
  const matches = dims.slice(0, 3).map((size, index) => ({
    axis: index + 1,
    size,
  })).filter(({ size }) => timingCount > 0 && size === timingCount);
  if (matches.length !== 1) {
    fail(
      "NIfTI slice_dim is unavailable and the slice axis cannot be inferred uniquely",
    );
  }
  sliceAxis = matches[0].axis;
}
const sliceCount = dims[sliceAxis - 1];

let sliceTimingCode: number;
let sliceTimingFile = "";
let shifts: number[] | undefined;
switch (sliceTimingMode) {
  case "none":
    sliceTimingCode = 0;
    break;
  case "regular-up":
    sliceTimingCode = 1;
    break;
  case "regular-down":
    sliceTimingCode = 2;
    break;
  case "interleaved":
    sliceTimingCode = 5;
    break;
  case "metadata":
    sliceTimingCode = 4;
    shifts = timingShiftsFromMetadata(metadata, tr, sliceCount);
    break;
  case "custom": {
    sliceTimingCode = 4;
    if (!customTimingRaw) {
      fail("SLICE_TIMING_MODE=custom requires --custom-slice-timing");
    }
    shifts = await timingShiftsFromCustomFile(
      path.resolve(customTimingRaw),
      sliceCount,
    );
    break;
  }
  default:
    fail(
      `Unsupported slice-timing mode ${sliceTimingMode}; use none, regular-up, regular-down, interleaved, metadata, or custom`,
    );
}

await Deno.mkdir(path.dirname(designOutput), { recursive: true });
if (shifts) {
  await Deno.mkdir(path.dirname(sliceOutput), { recursive: true });
  await Deno.writeTextFile(
    sliceOutput,
    `${shifts.map((value) => value.toFixed(9)).join("\n")}\n`,
    { createNew: true },
  );
  sliceTimingFile = sliceOutput;
}

const standardBrain = path.join(
  fslDir,
  "data",
  "standard",
  "MNI152_T1_2mm_brain.nii.gz",
);
await requireRegularFile(standardBrain);

const totalVoxels = dims.reduce((product, value) => product * value, 1);
let design = await Deno.readTextFile(templateFile);
const replacements = new Map<string, string>([
  ["__OUTPUT_DIR__", tclQuote(featOutput)],
  ["__TR__", tr.toString()],
  ["__NPTS__", dims[3].toString()],
  ["__DELETE_VOLUMES__", deleteVolumes.toString()],
  ["__TOTAL_VOXELS__", totalVoxels.toString()],
  ["__SLICE_TIMING_CODE__", sliceTimingCode.toString()],
  ["__SLICE_TIMING_FILE__", tclQuote(sliceTimingFile)],
  ["__SLICE_AXIS__", sliceAxis.toString()],
  ["__SMOOTH_FWHM_MM__", smoothFwhm.toString()],
  ["__HIGHPASS_SECONDS__", (1 / highpassHz).toString()],
  ["__STANDARD_BRAIN__", tclQuote(standardBrain)],
  ["__FNIRT_WARP_RESOLUTION_MM__", fnirtWarpResolution.toString()],
  ["__BOLD_FILE__", tclQuote(bold)],
  ["__T1_BRAIN_FILE__", tclQuote(t1Brain)],
]);
for (const [token, value] of replacements) {
  design = replaceToken(design, token, value);
}
if (/__[A-Z0-9_]+__/.test(design)) {
  fail("Unresolved placeholder remains in generated design");
}

const provenance = [
  `# Generated from ${metadataFile}`,
  `# Slice timing mode: ${sliceTimingMode}`,
  `# Geometry: ${dims.join("x")}; TR=${tr}s; slice axis=${sliceAxis}`,
  "",
].join("\n");
await Deno.writeTextFile(designOutput, provenance + design, {
  createNew: true,
});

console.log(`Generated ${designOutput}`);
if (sliceTimingFile) console.log(`Generated ${sliceTimingFile}`);
console.log(
  `TR=${tr}s, volumes=${
    dims[3]
  }, slices=${sliceCount}, slice timing=${sliceTimingMode}`,
);
