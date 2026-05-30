# 🏠 Homelab Infrastructure

This repository contains my personal **Docker-based homelab infrastructure**. It is designed to manage, deploy, and maintain self-hosted services using `docker-compose`, with a focus on simplicity, scalability, and reproducibility.

---

## 📦 Structure

```
.
├── stacks/                # Application stacks (services)
│   ├── immich/
│   ├── multimedia/
│   ├── management/
│   ├── gitlab/
│   └── database/
│
├── infrastructure/        # Core infrastructure components
│   └── network/
│
├── dockerfiles/           # Custom Docker images
│   └── portfolio/
│       ├── Dockerfile.cloud
│       └── .dockerignore
│
├── deployments/           # CI/CD deployments (GitLab, etc.)
│   └── portfolio/
│       └── docker-compose.yml
│
└── README.md
```

---

## 🚀 Usage

### ▶️ Start a stack

```bash
docker compose -f stacks/<stack-name>/docker-compose.yml up -d
```

### ⛔ Stop a stack

```bash
docker compose -f stacks/<stack-name>/docker-compose.yml down
```

---

## 🔄 Updating containers

A script is used to:

* Scan all folders inside `stacks/`
* Pull the latest images
* Restart containers if needed

### ⚠️ Ignored stacks

* Any folder starting with `_` is ignored (e.g., `_my-stack`)
* Any stack marked as disabled will not be updated

---

## 🐳 Dockerfiles

Custom images are stored in `dockerfiles/`.

Naming convention:

* `Dockerfile` → default

Build example:

```bash
docker build -f dockerfiles/portfolio/Dockerfile.cloud -t portfolio:cloud .
```

---

## 🔐 Environment variables

Sensitive values are stored in `.env` files and are **not committed**.

---

## 📄 License

This project is for personal use.
