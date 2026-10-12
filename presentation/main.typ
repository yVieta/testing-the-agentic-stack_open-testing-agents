// © 2026 Vieta. Licensed under CC BY 4.0.
// Global slide settings (16:9 widescreen, dark mode)
#set page(
  paper: "presentation-16-9",
  fill: rgb("#1e1e24"),
  margin: (x: 2.5cm, y: 1.6cm),
  numbering: "1",
)

// Font settings (system-wide fallbacks)
#set text(
  fill: rgb("#f8fafc"),
  size: 20pt,
  lang: "en",
)

// Every main headline (= slide) starts on a new page, gets a visual accent and
// is registered in the automatic table of contents.
#show heading.where(level: 1): it => {
  pagebreak(weak: false)
  block(width: 100%)[
    #set text(fill: rgb("#22c55e"), weight: "bold", size: 28pt)
    #it.body
    #v(0.45em)
    #line(length: 100%, stroke: 1pt + rgb("#334155"))
  ]
}

// Styling for the automatic table of contents entries (Agenda):
// entries are slightly larger than the body slides (16pt, 0.5em spacing)
// so the agenda reads well as the overview page.
#show outline.entry: it => {
  set text(size: 16pt)
  block(spacing: 0.5em)[
    #link(it.element.location())[#strong(text(fill: rgb("#22c55e"))[#it.body()])]
  ]
}

// --- small reusable components ---------------------------------------------

// One dark "card" box with a green title and a grey subtitle.
// `compact: true` shrinks it for diagram rows; `tsize`/`ssize` override
// the title and subtitle font sizes (default 13pt/9.5pt).
#let rcard(title, sub, compact: false, tsize: none, ssize: none) = block(
  fill: rgb("#2a2a35"),
  inset: (x: 8pt, y: if compact {4pt} else {7pt}),
  radius: 8pt,
  stroke: 1pt + rgb("#334155"),
  width: 100%,
)[
  #align(center)[
    #text(weight: "bold", size: if tsize != none {tsize} else if compact {11pt} else {13pt}, fill: rgb("#22c55e"))[#title]\
    #v(2pt)
    #text(size: if ssize != none {ssize} else if compact {8pt} else {9.5pt}, fill: rgb("#cbd5e1"))[#sub]
  ]
]

// A narrow two-way flow arrow between diagram layers.
#let flow(size: 13pt) = align(center)[
  #text(size: size, fill: rgb("#94a3b8"))[↕]
]

// A small "chip" with a bold green title and a grey subtitle line.
#let chiph(title, sub) = block(
  fill: rgb("#2a2a35"),
  inset: (x: 7pt, y: 4pt),
  radius: 6pt,
  stroke: 1pt + rgb("#334155"),
  width: 100%,
)[
  #align(center)[
    #text(weight: "bold", size: 10pt, fill: rgb("#22c55e"))[#title]\
    #text(size: 8.5pt, fill: rgb("#cbd5e1"))[#sub]
  ]
]

// A headline + rule, reused on slides that are not level-1 headings.
#let section(title) = block(width: 100%)[
  #set text(fill: rgb("#22c55e"), weight: "bold", size: 28pt)
  #title
  #v(0.5em)
  #line(length: 100%, stroke: 1pt + rgb("#334155"))
]

// --- COVER SLIDE ------------------------------------------------------------
// The entry page is intentionally larger than the body slides: title and badge
// sizes plus the card inset were bumped (34pt title / 20pt subtitle / inset
// 48x36) so the cover fills more of the 16:9 frame. Tune these values here 
// they only affect this first page.
#box(width: 100%)[
  #align(center + horizon)[
    #block(
      fill: rgb("#2a2a35"),
      inset: (x: 48pt, y: 36pt),
      radius: 24pt,
      stroke: 1.5pt + rgb("#22c55e"),
      width: 100%,
    )[
      #text(size: 34pt, weight: "bold", fill: rgb("#22c55e"))[open-testing-agents:_selfhost_]\
      #v(0.6em)
      #text(size: 20pt, style: "italic", fill: rgb("#cbd5e1"))[A self-hosted, fully declarative testing lab]\
      #text(size: 18pt, fill: rgb("#cbd5e1"))[Testing the agentic stack]\
      #v(2em)
      #align(center)[
        #text(size: 12pt, fill: rgb("#64748b"))[no cloud  #h(0.4em)  and  #h(0.4em)  no hand-edited state]
      ]
      #v(2em)
      #grid(
        columns: (1fr, 1fr),
        align(left)[#text(size: 14pt, fill: rgb("#94a3b8"))[Thanh Viet Nguyen - Vieta]],
        //align(right)[#text(size: 14pt, fill: rgb("#94a3b8"))[Date: 12.10.2026]]
      )
    ]
  ]

  #place(right + bottom)[
  #grid(
    columns: (auto, auto),
    column-gutter: 6pt,
    align(center + horizon)[#image("Creative_Commons_“Share_Alike”_license_icon.svg.webp", width: 3cm)],
    align(center + horizon)[#text(size: 9pt, fill: rgb("#94a3b8"))[Licensed under CC BY-SA 4.0]],
  )
]
]

// --- AUTOMATIC TABLE OF CONTENTS (Agenda) ----------------------------------
// Generated automatically from all = headings; no manual maintenance needed.
// The entry list sits next to the host image on the right.
#pagebreak()
#grid(
  columns: (1.3fr, 1fr),
  column-gutter: 0.6cm,
  [
    #section[Agenda]
    #v(0.4em)
    #outline(title: none, depth: 1)
  ],
  align(top + right)[
    #v(2.8cm)
    #image("hostos.jpeg", width: 100%)
  ]
)

// --- PRESENTATION SLIDES ---------------------------------------------------

= Motivation
#grid(
  columns: (1fr, 1fr),
  column-gutter: 0.8cm,
  [
    #block[
      #set text(size: 15pt)
      - Agentic testing usually means *cloud APIs and vendor lock-in*.
      - External model providers see your test code and data.
      - Brokers (e.g. MQTT) and *hand-edited state* add moving parts.
      - Distributed setups (the old iteration used *Raspberry Pis + MQTT*).
    ]
  ],
  [
    #block[
      #set text(size: 15pt)
      - *This stack:* everything on a single machine you control end to end.
      - No cloud, no MQTT broker, no hand-edited state.
      - Fully declarative from the OS toolchain up.
      - GPU inference, vector store, formal guardrails - all local.
    ]
  ]
)

= What is this repo?
#block[
  #set text(size: 16pt)
  Open-Testing-Agents:_selfhost_ is a small but complete *agentic stack*: three AI
  agents test a real web application - *OWASP Juice Shop* - chain their findings
  into one report and stream the result to a terminal interface.
]
#v(0.5em)
#grid(
  columns: (1fr, 1fr, 1fr, 1fr),
  column-gutter: 0.35cm,
  row-gutter: 0.35cm,
  chiph[Agents][3 CrewAI crews, 3 roles],
  chiph[Model][2x llama.cpp, self-hosted],
  chiph[Memory][Postgres + pgvector],
  chiph[Bus][small MCP server],
  chiph[SUT][Juice Shop via nginx],
  chiph[Guardrails][Lean4 harness],
  chiph[Interface][terminal CLI + Odysseus],
  chiph[IaC][OpenTofu + Dhall + Nix],
)
#v(0.5em)
#text(size: 12pt, fill: rgb("#94a3b8"))[Video presentation: https://codeberg.org/spifamily/open-testing-agents-abgabe]

= The three agents
#table(
  columns: (auto, auto, 2fr, 2fr),
  align: (left, left, left, left),
  stroke: rgb("#334155"),
  [*Role*], [*Crew dir*], [*Work*], [*Output*],
  [e2e engineer], [`build/e2e`], [Playwright tests against the SUT], [`playwright_test.py` + `previous_output.md`],
  [pentester], [`build/pentester`], [nmap : nikto : sqlmap : nuclei scans], [`previous_output.md`],
  [test manager], [`build/manager`], [controller: assign, monitor, follow-ups], [`report.md` (process + findings + mail)],
)
#v(0.6em)
#block[
  #set text(size: 14pt)
  - All three run as *Podman Quadlet* services and carry the same `custom:aigents_bus` tool
    -> they exchange findings *peer-to-peer* over the MCP bus.
  - The *test manager is the controller*: assigns each case to e2e and/or pentester,
    monitors their state, dispatches follow-ups and produces the final report.
  - Prometheus could receiv mails for the test reports which is not working yet 
]

= Stack architecture
#stack(dir: ttb, spacing: 0.1em)[
  #grid(
    columns: (1fr, 1fr, 1fr),
    column-gutter: 0.4cm,
    rcard("e2e engineer", "Playwright + Chromium", compact: true),
    rcard("pentester", "nmap : nikto : sqlmap : nuclei", compact: true),
    rcard("test manager", "controller : final report", compact: true),
  )
  #flow(size: 9pt)
  #align(center)[
    #block(
      fill: rgb("#2a2a35"),
      inset: 6pt,
      radius: 8pt,
      stroke: 1.5pt + rgb("#22c55e"),
      width: 60%,
    )[
      #align(center)[
        #text(weight: "bold", size: 12pt, fill: rgb("#22c55e"))[MCP knowledge bus]\
        #text(size: 8pt, fill: rgb("#cbd5e1"))[JSON-RPC 2.0 over HTTP : host service : 127.0.0.1:8765/mcp]
      ]
    ]
  ]
  #flow(size: 9pt)
  #grid(
    columns: (1fr, 1fr, 1fr, 1fr),
    column-gutter: 0.4cm,
    rcard("SUT", "OWASP Juice Shop : nginx : :8080", compact: true),
    rcard("phi-4-mini", "primary : :18080", compact: true),
    rcard("phi-mini-moe", "fast : :18081", compact: true),
    rcard("Postgres", "+ pgvector : :15432", compact: true),
  )
]
#v(0.25em)
#text(size: 8.5pt, fill: rgb("#94a3b8"))[Agents also reach the SUT and each other directly; the Lean4 harness validates every run before it executes.]

= Models & memory
#grid(
  columns: (1fr, 1fr),
  column-gutter: 0.6cm,
  [
    #block[
      #set text(size: 14pt)
      - *phi-4-mini* - agents' brain, `:18080` (llama.cpp, CUDA)
        - 3.8B dense, 128K native ctx, *native tool calling*
        - 65536 ctx total = 16384 per slot, 4 parallel slots
        - all 99 layers offloaded to an *RTX 3060 (12 GB)*
      - *phi-mini-moe* - *optional* fast helper, `:18081`
        - 7.6B total / 2.4B active experts, runs on *CPU*
        - condenses shared findings before they enter the primary's context
        - extra models are *optional*: `secondary_model_enabled = false` serves only phi-4-mini, the condense step is skipped - everything degrades gracefully
    ]
  ],
  [
    #block[
      #set text(size: 14pt)
      - *PostgreSQL + pgvector* - reports, tasks, findings, embeddings
        - vector *3072* (matches phi-4-mini hidden size)
        - schema seeded once on an empty data dir
      - Both GGUF weights are downloaded by `model-fetch` one-shot profiles
        - phi-4-mini ~2.5 GB, phi-mini-moe ~5 GB
      - One podman-compose stack (`project aigents`) managed by OpenTofu
    ]
  ]
)

= MCP knowledge bus
#grid(
  columns: (1fr, 1.35fr),
  column-gutter: 0.6cm,
  [
    #block[
      #set text(size: 14pt)
      - stdlib-only *JSON-RPC 2.0* over HTTP - runs on the host as a systemd *user* service
      - SQLite state at `/var/spool/aigents/mcp/mcp.db`
      - agents + CLI + Odysseus chat speak the same protocol
      - every failure is a tool message, never a broken run
    ]
  ],
  [
    #block[
      #set text(size: 13pt)
      #table(
        columns: (1fr, 2fr),
        align: (left, left),
        inset: (x: 4pt, y: 2pt),
        stroke: rgb("#334155"),
        [*Bus tool*], [*Purpose*],
        [`assign_test_case`], [manager -> queue a case],
        [`get_next_task` / `list_tasks`], [claim + list tasks],
        [`submit_findings` / `get_findings`], [knowledge exchange],
        [`start_agent` / `stop_agent` / `get_agent_status`], [systemd control],
        [`publish_process` / `publish_note`], [Odysseus docs + notes],
        [`mail_report`], [final report as e-mail],
      )
    ]
  ]
)

= Guardrails: Lean4 harness
#grid(
  columns: (1fr, 1fr),
  column-gutter: 0.6cm,
  [
    #block[
      #set text(size: 14pt)
      - *AgentHarness.lean* - formal types for
        - action boundaries + tool pre-conditions
        - worker state transitions
        - the *single SUT* every role is scoped to
      - Lean 4 port of the *Agda* original (`skills/agda` kept for traceability)
    ]
  ],
  [
    #block[
      #set text(size: 14pt)
      - Role-aware *WellTuned* envelopes (`queue_size, dedupe_cap, crew_timeout, steps, step_cost`)
      - Every cycle the worker runs
        `lake env lean --run Main.lean <role> …`
      - Verdict `accepted` -> crew runs; `rejected` -> logged to Postgres
      - *Off-target is rejected*: any SUT URL that is not Juice Shop fails the check
    ]
  ]
)

= Everything as code
#grid(
  columns: (1fr, 1fr, 1fr),
  column-gutter: 0.5cm,
  [
    #block[
      #section[#text(size: 20pt)[Dhall]]
      #set text(size: 13pt)
      - crew JSON-first config is *typed Dhall*
      - `just crews` -> `.dhall/` -> `build/<role>/`
      - safe by default (total functional language)
    ]
  ],
  [
    #block[
      #section[#text(size: 20pt)[OpenTofu]]
      #set text(size: 13pt)
      - root `deploy/` module composes 5 child modules
      - `service_state=running|stopped`, `run_interval`, …
      - only changed triggers restart (fast code round-trips)
    ]
  ],
  [
    #block[
      #section[#text(size: 20pt)[Nix + just]]
      #set text(size: 13pt)
      - `flake.nix` dev shell: tofu, dhall, lean, just, …
      - `just deploy` / `down` / `status` / `pace 60` / `start-fast`
      - no NixOS required - pure nixpkgs toolchain
    ]
  ]
)

= Interfaces: CLI & Odysseus
#grid(
  columns: (1fr, 1.2fr),
  column-gutter: 0.5cm,
  [
    #block[
      #section[#text(size: 18pt)[`tm_cli`]]
      #set text(size: 14pt)
      - REPL with the test-manager persona (role/goal/backstory)
      - `/status` `/case` `/tasks` `/findings` `/process`
      - `/watch` - real-time dashboard (agents, tasks, findings)
      - `/save` `/latest` - transcripts to Postgres
    ]
  ],
  [
    #block[
      #section[#text(size: 18pt)[Odysseus]]
      #set text(size: 14pt)
      - self-hosted AI workspace (forked, Lean4 modifications), `:7000`
      - chat with the local models + *Test Manager* character
      - *Notes* panel: per-role `test-results` notes (Keep-style)
      - *Documents*: live testing-process markdown, published in place
      - e-mail delivery of final reports (SMTP/IMAP)
    ]
  ]
)

= Stack in numbers
#grid(
  columns: (1fr, 1.6fr),
  column-gutter: 0.6cm,
  [
    #block[
      #set text(size: 13pt)
      - 3 agents : 2 models : 1 SUT
      - 5 OpenTofu modules
      - ~7.5 GB of GGUF weights
      - 64K context : 3072 embedding dim
      - default run interval: 900 s
    ]
  ],
  [
    #block[
      #set text(size: 12pt)
      #table(
        columns: (2fr, auto, 2fr),
        align: (left, center, left),
        inset: (x: 4pt, y: 2pt),
        stroke: rgb("#334155"),
        [*Service*], [*Port*], [*Owner*],
        [juice shop (SUT via nginx)], [`8080`], [sut-setup],
        [juice shop (direct)], [`3000`], [sut-setup],
        [grafana], [`3001`], [sut-setup],
        [phi-4-mini], [`18080`], [model-setup],
        [phi-mini-moe], [`18081`], [model-setup],
        [postgres + pgvector], [`15432`], [model-setup],
        [MCP bus], [`8765`], [mcp-setup],
        [Odysseus UI : SearXNG : ChromaDB : ntfy], [`7000 : 8888 : 8100 : 8091`], [odysseus-setup],
      )
    ]
  ]
)

= Status & lessons learned
#grid(
  columns: (1fr, 1fr),
  column-gutter: 0.6cm,
  [
    #block[
      #set text(size: 13pt)
      - *Alpha phase* - split from MQTT + Raspberry Pis into a single self-hosted host, ready for future projects
      - *Future projects:* more optimized (open-weight) models that run on any system - ~2 GB RAM and 4 CPU cores
      - Qdrant/brokers dropped -> Postgres + pgvector + a direct MCP bus
    ]
  ],
  [
    #block[
      #set text(size: 13pt)
      - A local agentic testing setup is achievable *for everyone* (no cloud, no vendor lock-in)
      - Proof assistants (Rocq, Lean4, Agda) are not only for mathematicians - they guard real agent workflows
      - *Less can be more:* fewer moving parts (no brokers, no external APIs) -> fewer failure modes
    ]
  ]
)

#v(0.35em)
#block(
  fill: rgb("#24312b"),
  inset: (x: 14pt, y: 7pt),
  radius: 10pt,
  stroke: 1.5pt + rgb("#22c55e"),
)[
  #text(weight: "bold", size: 15pt, fill: rgb("#22c55e"))[Open weights + open source -> digital sovereignty]\
  #v(0.15em)
  #block[
    #set text(size: 12.5pt)
    - The agents' brain runs on *open-weight* models: Phi-4-mini and Phi-mini-MoE as local GGUF via llama.cpp
    - No proprietary cloud API, no hidden inference.
    - *All data stays on the machine*: test cases, findings, prompts and reports never leave the host.
    - The toolchain is fully open source: llama.cpp , CrewAI : OpenTofu , Podman , Nix , Lean4 , Dhall .
    - Open weights + open code mean the stack can be *independently verified, audited, forked and improved* - a real building block for digital sovereignty.
  ]
]

= Thank you to be here
#grid(
  columns: (1fr, 1fr, 1fr),
  column-gutter: 0.4cm,
  rcard("Motivation", "self-host, no cloud", tsize: 18pt, ssize: 14pt),
  rcard("Guardrails", "Lean4 harness", tsize: 18pt, ssize: 14pt),
  rcard("Reality", "Still work in progress", tsize: 18pt, ssize: 14pt),
)
#v(0.4em)
#align(center)[#image("ferris.jpeg", height: 4.2cm)]
#v(0.4em)
#text(size: 18pt, fill: rgb("#cbd5e1"))[Thanks for listening - happy to take questions and exchange ideas. ❤️]

= Appendix
#grid(
  columns: (1fr, 1.2fr),
  column-gutter: 0.6cm,
  [
    #block[
      #set text(size: 12pt)
      - https://github.com/yVieta/testing-the-agentic-stack-open-testing-agent-
      - https://codeberg.org/spifamily/ (talk video)
      - https://github.com/yVieta/odysseus (fork with Lean4 modifications)
      - `docs/USER_MANUAL_TEST_CASES.md` - step-by-step test-case manual
    ]
  ],
  [
    #block[
      #set text(size: 12pt)
      - https://owasp.org/www-project-juice-shop/
      - https://www.crewai.com/
      - https://github.com/ggml-org/llama.cpp
      - https://opentofu.org/ : https://dhall-lang.org/
      - https://lean-lang.org/
    ]
  ]
)

#v(0.2em)
#text(weight: "bold", size: 16pt, fill: rgb("#22c55e"))[Sources - `resources/Papers.md`]\
#v(0.2em)
#line(length: 100%, stroke: 1pt + rgb("#334155"))
#v(0.2em)
#grid(
  columns: (1fr, 1fr),
  column-gutter: 0.6cm,
  [
    #block[
      #set text(size: 8pt)
      *Models*
      - https://github.com/microsoft/PhiCookBook
      - https://arxiv.org/abs/2412.08905
      #v(0.1em)
      *Fine tuning*
      - https://odr.chalmers.se/bitstreams/f68aff4a-3865-41b0-ac54-2ce3d917e783/download
      - https://arxiv.org/html/2408.13296v1
      - https://github.com/Curated-Awesome-Lists/awesome-llms-fine-tuning
    ]
  ],
  [
    #block[
      #set text(size: 8pt)
      *Others*
      - https://arxiv.org/html/2501.00217v1
      - https://arxiv.org/html/2407.03203
      #v(0.1em)
      *Offtopic (still inspirational)*
      - https://arxiv.org/pdf/2510.12787
      #v(0.1em)
      *Extension (WIP)*
      - https://github.com/formalverification/agda-native-air
    ]
  ]
)
