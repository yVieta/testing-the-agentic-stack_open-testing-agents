---
name: playwright-testing
description: Write, run and report real Playwright (Python) end-to-end tests against the OWASP Juice Shop SUT. Use when the e2e test agent must probe the web UI at {target_url}, capture console/page errors and screenshots, and save the generated test code and issue list.
---

# Playwright end-to-end testing

The e2e test agent drives a **real headless Chromium** through Playwright against
the **OWASP Juice Shop** SUT. Playwright and its browser are pre-installed in
the agent image, so never install anything — just write a test and run it.

## Target

- The SUT is the OWASP Juice Shop, exposed at `{target_url}` (by default
  `http://127.0.0.1:8080`, an nginx proxy in front of Juice Shop on `:3000`).
- Treat `{target_url}` as the single base URL; do not hardcode ports or hosts.
  Log in / register, browse products, add to cart, search — the usual Juice Shop
  flows.

## Write the test

1. Save **all generated Playwright code** in the working directory as
   `playwright_test.py`. That exact filename is the contract: a post-run step
   publishes it to the Odysseus document library so a human can read the
   generated code in the UI.
2. Use the synchronous API so it runs as a plain `python3` script:

   ```python
   from playwright.sync_api import sync_playwright

   BASE = "{target_url}"
   console_errors = []

   with sync_playwright() as p:
       # Running as root in a container -> the Chromium sandbox is unavailable.
       browser = p.chromium.launch(headless=True, args=["--no-sandbox"])
       page = browser.new_page()
       page.on("console", lambda m: console_errors.append(m.text)
               if m.type == "error" else None)
       page.on("pageerror", lambda e: console_errors.append(str(e)))
       page.goto(BASE, wait_until="networkidle")
       assert page.title(), "page has a title"
       page.screenshot(path="home.png", full_page=True)
       browser.close()
   ```

3. Always launch with `headless=True` and `args=["--no-sandbox"]` — the agent
   runs as root inside the container, where Chromium's sandbox cannot start.
4. Capture evidence: `page.on("console", ...)` and `page.on("pageerror", ...)`
   for errors, and `page.screenshot(path=...)` for failing states. Keep them in
   the working directory.
5. Keep the generated file self-contained and runnable: no imports from the
   crew, no custom packages beyond `playwright`.

## How the test is executed

The runner executes the latest `playwright_test.py` with `python3` once you
finish (using the baked-in Chromium) and records the output — you do not run it
yourself. So make the file:

- self-contained: a plain `python3 playwright_test.py` entry point that imports
  only `playwright`;
- deterministic: exit non-zero when a real assertion fails (`assert` or
  `sys.exit(1)`), so the runner reports a failure.

`PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright` is baked into the image, so the
browser is always found. Anticipate the flows most likely to break and assert on
them; a test that only loads the home page tells the team very little.

## Report

- Write the final list of issues (with the failing route, the console/error
  message, and the screenshot path) to `previous_output.md` in the working
  directory — the pentester and the test manager read that file next.
- Keep `playwright_test.py` as the last version that ran.
- Do not invent results: every issue needs an observed error or a failed
  assertion from an actual run.

## Workflow checklist

- [ ] `playwright_test.py` written in the working directory, runnable by `python3`.
- [ ] Home page and the main flows probed; console/page errors collected.
- [ ] Screenshots saved for failures.
- [ ] `previous_output.md` contains the concrete issue list.
