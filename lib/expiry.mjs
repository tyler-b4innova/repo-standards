// Credential expiry sentinel, run daily from the standards repository: for each overlay
// `expiring_credentials` entry, keep exactly one open `human-decision` issue while the credential's
// issue date (a repository variable, YYYY-MM-DD) is older than `max_days`, and close it once renewed.
import { execFileSync } from "node:child_process";
import { client } from "./sync.mjs";

const LABEL = "human-decision";
const DAY = 86400000;

export async function run({ overlay }) {
  const creds = overlay.expiring_credentials ?? [];
  if (!creds.length) return console.log("expiry: no expiring_credentials in the overlay");
  let token = process.env.GH_TOKEN || process.env.GITHUB_TOKEN;
  try { token ||= execFileSync("gh", ["auth", "token"], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim(); } catch {}
  if (!token) return console.log("::notice::expiry idle: no GH_TOKEN, GITHUB_TOKEN or gh login; nothing checked");
  const gh = client(token);
  const repo = overlay.standards_repo;
  const now = new Date().toISOString().slice(0, 10);
  const { GITHUB_SERVER_URL: s, GITHUB_REPOSITORY: gr, GITHUB_RUN_ID: id } = process.env;
  const by = s && gr && id ? `[expiry](${s}/${gr}/actions/runs/${id})` : "expiry";
  const open = await gh("GET", `repos/${repo}/issues?state=open&labels=${LABEL}&per_page=100`);

  for (const { name, issued_var: v, max_days: max } of creds) {
    const title = `Credential expiry: ${name}`;
    const issued = (await gh("GET", `repos/${repo}/actions/variables/${v}`, null, { allow404: true }))?.value?.trim();
    const age = /^\d{4}-\d{2}-\d{2}$/.test(issued ?? "") ? Math.floor((Date.now() - Date.parse(`${issued}T00:00:00Z`)) / DAY) : NaN;
    const finding = !issued ? `Repository variable \`${v}\` (the issue date of ${name}) is not set.`
      : Number.isNaN(age) ? `Repository variable \`${v}\` is \`${issued}\`, not a YYYY-MM-DD date.`
      : age > max ? `${name} is ${age} days old (issued ${issued}, limit ${max}). Issue a new one, update every consumer, revoke the old one, then set \`${v}\` to today's date.`
      : null;
    const [issue, ...dupes] = open.filter((i) => i.title === title && !i.pull_request);
    for (const d of dupes) {
      await gh("POST", `repos/${repo}/issues/${d.number}/comments`, { body: `Duplicate of #${issue.number}.` });
      await gh("PATCH", `repos/${repo}/issues/${d.number}`, { state: "closed" });
    }
    if (finding) {
      const body = `${finding}\n\nChecked ${now} by ${by}. Closes itself once \`${v}\` is within ${max} days.\n`;
      if (issue) await gh("PATCH", `repos/${repo}/issues/${issue.number}`, { body });
      else await gh("POST", `repos/${repo}/issues`, { title, body, labels: [LABEL] });
      console.log(`expiry: ${name}: ${finding}`);
    } else {
      if (issue) {
        await gh("POST", `repos/${repo}/issues/${issue.number}/comments`, { body: `Clear as of ${now}: ${name} issued ${issued}, ${age} days old (limit ${max}). Closed by ${by}.` });
        await gh("PATCH", `repos/${repo}/issues/${issue.number}`, { state: "closed" });
      }
      console.log(`expiry: ${name}: ${age} days old (limit ${max}), clear`);
    }
  }
}
