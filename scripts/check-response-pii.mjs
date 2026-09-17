// Fails when a response schema in an OpenAPI document has a property whose
// name says it holds personal or secret data, unless the allowlist carries
// that property with a reason. Driven by check-response-pii.sh, which also
// proves this can fail.
//
//   node check-response-pii.mjs <openapi.json> <allowlist.txt>
//
// Only responses are walked: what a client may SEND (a sign-in form's
// password) is not what the server gives away. Every schema reachable from a
// response is followed through $ref, arrays, maps and allOf/oneOf/anyOf, and
// a property is reported as <Schema>.<property>.
import { readFileSync } from "node:fs";
import process from "node:process";

// Matched against the property name lowercased with punctuation removed, so
// emailAddress, email_address and EMail all match "email".
const PII =
  /email|phone|address|zip|postcode|postalcode|dob|dateofbirth|birthdate|ssn|password|token|secret/;

const [specPath, allowlistPath] = process.argv.slice(2);
if (!specPath || !allowlistPath) {
  process.stderr.write("usage: check-response-pii.mjs <openapi.json> <allowlist.txt>\n");
  process.exit(2);
}

const spec = JSON.parse(readFileSync(specPath, "utf8"));

const problems = [];
const allowed = new Map();
for (const [index, raw] of readFileSync(allowlistPath, "utf8").split("\n").entries()) {
  const line = raw.trim();
  if (line === "" || line.startsWith("#")) continue;
  const [, key, reason] = line.match(/^(\S+)\s*(.*)$/);
  if (reason === "") {
    problems.push(`${allowlistPath}:${index + 1}: ${key} is allowlisted without a reason`);
  }
  allowed.set(key, false);
}

const seen = new Set();
function walk(schema, owner) {
  if (!schema || typeof schema !== "object") return;
  if (schema.$ref) {
    const name = schema.$ref.replace("#/components/schemas/", "");
    if (seen.has(name)) return;
    seen.add(name);
    walk(spec.components?.schemas?.[name], name);
    return;
  }
  for (const [property, child] of Object.entries(schema.properties ?? {})) {
    const key = `${owner}.${property}`;
    if (PII.test(property.toLowerCase().replace(/[^a-z0-9]/g, ""))) {
      if (allowed.has(key)) allowed.set(key, true);
      else problems.push(`${key} is in a response and is named like personal or secret data`);
    }
    walk(child, key);
  }
  walk(schema.items, owner);
  if (typeof schema.additionalProperties === "object") walk(schema.additionalProperties, owner);
  for (const branch of ["allOf", "oneOf", "anyOf"]) {
    for (const child of schema[branch] ?? []) walk(child, owner);
  }
}

let responses = 0;
for (const [path, operations] of Object.entries(spec.paths ?? {})) {
  for (const [method, operation] of Object.entries(operations)) {
    for (const [status, response] of Object.entries(operation?.responses ?? {})) {
      for (const media of Object.values(response.content ?? {})) {
        responses += 1;
        walk(media.schema, `${method.toUpperCase()} ${path} ${status}`);
      }
    }
  }
}

for (const [key, used] of allowed) {
  if (!used) problems.push(`${key} is allowlisted but no response has it; remove the line`);
}

if (problems.length > 0) {
  for (const problem of problems) process.stderr.write(`  - ${problem}\n`);
  process.stderr.write(
    "A response is a record that lists exactly the fields a client needs. Remove the field,\n" +
      `or — if clients really need it — add '<Schema>.<property>  <reason>' to ${allowlistPath}.\n`,
  );
  process.exit(1);
}
process.stdout.write(
  `${responses} response schema(s), ${seen.size} named schema(s): no unlisted personal or secret fields\n`,
);
