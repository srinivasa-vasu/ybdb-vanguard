# Development Innerloop Workflow

[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/srinivasa-vasu/ybdb-vanguard?devcontainer_path=.devcontainer%2Finit-iloop%2Fdevcontainer.json)

Scaffold a production-ready YugabyteDB-backed application from scratch using the **JHipster YugabyteDB generator** — without installing anything locally. The devcontainer includes a running YugabyteDB node, pre-seeded database, and the JHipster generator ready to run.

---

## Prerequisites

The devcontainer starts a **single-node cluster** and creates the `ybdbapp` database and role automatically. The JHipster YugabyteDB generator (`generator-jhipster-yugabytedb`) is installed during container creation.

---

## Running the exercise

Open the scaffold shell from the VS Code **Terminal** menu:

| Task | What it opens |
|---|---|
| **Terminal → Run Task → `dev-inner-loop`** | Shell in the `ybdbapp/` directory, ready to scaffold |

---

## Scaffolding a new application

From the `dev-inner-loop` shell, run the generator:

```bash
# Inside the ybdbapp/ directory — choose one:
ybdb        # shorthand alias
# or
yugabytedb  # full name
```

The interactive generator prompts you to configure your application:
- Application type (monolith, microservices, gateway)
- Programming language (Java, Kotlin)
- Framework (Spring Boot, Quarkus, Micronaut)
- Authentication (JWT, OAuth2, session)
- Entity definitions

---

## What gets generated

After scaffolding, the generator produces a fully-configured application:

```
ybdbapp/
├── src/                    ← Application source code
├── src/main/resources/
│   └── application.yml     ← Pre-configured for YugabyteDB
├── pom.xml / build.gradle  ← Dependencies including YugabyteDB JDBC driver
└── ...
```

The generated `application.yml` is pre-wired to connect to the YugabyteDB cluster running in the devcontainer (`127.0.0.1:5433`).

---

## Running the generated application

```bash
# Build and run (Maven)
./mvnw

# Or Gradle
./gradlew bootRun
```

The app starts on `localhost:8080`. Open the VS Code port forwarding panel to access it in your browser.

---

## Useful commands

```bash
# Connect to the pre-seeded ybdbapp database
ysqlsh -h 127.0.0.1 -d ybdbapp

# Check which tables were created after running migrations
ysqlsh -h 127.0.0.1 -d ybdbapp -c "\dt"

# YugabyteDB UI (tablet distribution, metrics)
# → Forwarded port 15433 in VS Code
```
