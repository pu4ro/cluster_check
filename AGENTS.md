# Repository Guidelines

## Project Structure & Module Organization
- `k8s_health_check.sh`: primary, modular health check with HTML/JSON output and resource collection.
- `generate_official_report.sh`: wraps health checks and JSON to produce public-agency style HTML reports (driven by `.env` values).
- `k8s_check.sh`: baseline legacy checker; keep changes minimal unless fixing bugs.
- `config.conf`: auto-generated runtime config; do not hand-edit in commits.
- `reports/`: generated logs/HTML/JSON and official reports; treat contents as artifacts, not source.
- `.env` / `.env.example`: report and runtime overrides; `.env` may hold sensitive data and should stay untracked.

## Build, Test, and Development Commands
- Run main check: `./k8s_health_check.sh [--format html|json] [--url <https://...>] [--namespace <ns>]`.
- Generate agency report (runs checks if JSON not supplied): `./generate_official_report.sh [--json reports/k8s_health_report_YYYYMMDD_HHMMSS.json] [--org "<name>"] [--author "<name>"]`.
- Debug mode for verbose logs: `DEBUG=true ./k8s_health_check.sh`.
- Clean artifacts (manual): remove files under `reports/` as needed; do not delete config/conf unless regenerating intentionally.

## Coding Style & Naming Conventions
- Language: Bash; prefer POSIX-compatible constructs where possible.
- Indent with two spaces; avoid tabs.
- Functions use lowercase with underscores (`store_result`, `check_<area>`); constants/env vars uppercase with underscores.
- Keep outputs user-focused; reuse existing logging helpers and color codes.
- Run `shellcheck` locally before committing when touching scripts.

## Testing Guidelines
- No automated test suite; validate by executing `./k8s_health_check.sh` against a non-prod cluster or with limited scopes (`--namespace`, `--format`).
- For report changes, generate sample HTML/JSON in `reports/` and visually inspect key sections (summary, node metrics, storage charts).
- When modifying legacy scripts, ensure new logic still exits non-zero on failures that should block automation.

## Commit & Pull Request Guidelines
- Follow existing history: concise, imperative-style subject lines (`Add`, `Update`, `Fix`...), no trailing punctuation.
- Summarize scope in the body only when needed (key options changed, new outputs, breaking flags).
- PRs should describe what changed, why, and how to verify (commands run, sample report names). Link related issues; include before/after notes or screenshots for HTML/report changes.

## Security & Configuration Tips
- Keep `.env` out of version control; it may include organization details and URLs.
- Protect kube credentials; avoid echoing secrets in logs. When sharing artifacts, scrub `reports/` of sensitive cluster metadata.
- Ensure external commands (`kubectl`, `wkhtmltopdf`, `curl`, `jq`, `bc`) are available in the target environment before running scripts.
