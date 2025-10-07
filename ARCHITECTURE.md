# Architecture Diagram - Docker Registry Workflow

## System Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         DHANMAN INFRASTRUCTURE                          │
└─────────────────────────────────────────────────────────────────────────┘

╔═════════════════════════════════════════════════════════════════════════╗
║                          SERVICE REPOSITORIES                           ║
╠═════════════════════════════════════════════════════════════════════════╣
║                                                                         ║
║  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐                ║
║  │   dhanman    │  │   dhanman    │  │   dhanman    │                ║
║  │   -common    │  │   -sales     │  │  -purchase   │  ...           ║
║  └──────────────┘  └──────────────┘  └──────────────┘                ║
║         │                 │                 │                          ║
║         └─────────────────┴─────────────────┘                          ║
║                           │                                            ║
║                    Each contains:                                      ║
║                    • Dockerfile                                        ║
║                    • Jenkinsfile OR                                    ║
║                    • .github/workflows/docker-build-push.yml           ║
║                                                                         ║
╚═════════════════════════════════════════════════════════════════════════╝
                              │
                              │ Git Push
                              ▼
╔═════════════════════════════════════════════════════════════════════════╗
║                           CI/CD PIPELINE                                ║
╠═════════════════════════════════════════════════════════════════════════╣
║                                                                         ║
║  ┌────────────────────────┐    OR    ┌──────────────────────────┐    ║
║  │   Jenkins Pipeline     │          │   GitHub Actions         │    ║
║  │  ┌──────────────────┐  │          │  ┌────────────────────┐  │    ║
║  │  │ 1. Checkout      │  │          │  │ 1. Checkout        │  │    ║
║  │  │ 2. Build .NET    │  │          │  │ 2. Build .NET      │  │    ║
║  │  │ 3. Run Tests     │  │          │  │ 3. Run Tests       │  │    ║
║  │  │ 4. Build Docker  │  │          │  │ 4. Build Docker    │  │    ║
║  │  │ 5. Push to GHCR  │  │          │  │ 5. Push to GHCR    │  │    ║
║  │  └──────────────────┘  │          │  └────────────────────┘  │    ║
║  └────────────────────────┘          └──────────────────────────┘    ║
║                                                                         ║
╚═════════════════════════════════════════════════════════════════════════╝
                              │
                              │ Docker Push
                              ▼
╔═════════════════════════════════════════════════════════════════════════╗
║               GITHUB CONTAINER REGISTRY (ghcr.io/b2atech)               ║
╠═════════════════════════════════════════════════════════════════════════╣
║                                                                         ║
║  📦 dhanman-common:latest    📦 dhanman-common:v1.0.0                  ║
║  📦 dhanman-sales:latest     📦 dhanman-sales:v1.0.0                   ║
║  📦 dhanman-purchase:latest  📦 dhanman-purchase:v1.0.0                ║
║  📦 dhanman-payroll:latest   📦 dhanman-payroll:v1.0.0                 ║
║  📦 dhanman-inventory:latest 📦 dhanman-inventory:v1.0.0               ║
║  📦 dhanman-community:latest 📦 dhanman-community:v1.0.0               ║
║                                                                         ║
╚═════════════════════════════════════════════════════════════════════════╝
                              │
                              │ Docker Pull
                              ▼
╔═════════════════════════════════════════════════════════════════════════╗
║                         DEPLOYMENT SERVERS                              ║
╠═════════════════════════════════════════════════════════════════════════╣
║                                                                         ║
║  ┌───────────────────────────┐        ┌───────────────────────────┐   ║
║  │      QA Environment       │        │   Production Environment  │   ║
║  │  ┌─────────────────────┐  │        │  ┌─────────────────────┐  │   ║
║  │  │  Docker Compose     │  │        │  │  Docker Compose     │  │   ║
║  │  │  (develop tags)     │  │        │  │  (version tags)     │  │   ║
║  │  └─────────────────────┘  │        │  └─────────────────────┘  │   ║
║  │                            │        │                           │   ║
║  │  ┌──────────────────────┐ │        │  ┌──────────────────────┐│   ║
║  │  │ dhanman-common:5200  │ │        │  │ dhanman-common:5200  ││   ║
║  │  │ dhanman-sales:5201   │ │        │  │ dhanman-sales:5201   ││   ║
║  │  │ dhanman-purchase:5202│ │        │  │ dhanman-purchase:5202││   ║
║  │  │ dhanman-payroll:5203 │ │        │  │ dhanman-payroll:5203 ││   ║
║  │  │ dhanman-inventory:5204│ │       │  │ dhanman-inventory:5204││  ║
║  │  │ dhanman-community:5205│ │       │  │ dhanman-community:5205││  ║
║  │  └──────────────────────┘ │        │  └──────────────────────┘│   ║
║  └───────────────────────────┘        └───────────────────────────┘   ║
║                                                                         ║
╚═════════════════════════════════════════════════════════════════════════╝
                              │
                              │ HTTP Requests
                              ▼
╔═════════════════════════════════════════════════════════════════════════╗
║                          NGINX REVERSE PROXY                            ║
╠═════════════════════════════════════════════════════════════════════════╣
║                                                                         ║
║  qa.common.dhanman.com     → localhost:5200                            ║
║  qa.sales.dhanman.com      → localhost:5201                            ║
║  qa.purchase.dhanman.com   → localhost:5202                            ║
║  qa.payroll.dhanman.com    → localhost:5203                            ║
║  qa.inventory.dhanman.com  → localhost:5204                            ║
║  qa.community.dhanman.com  → localhost:5205                            ║
║                                                                         ║
╚═════════════════════════════════════════════════════════════════════════╝
                              │
                              ▼
                       🌐 External Users
```

## Deployment Flow

```
1. DEVELOPER WORKFLOW
   ┌─────────────────────────────────────────────────────┐
   │ Developer pushes code to service repository         │
   │                    │                                │
   │                    ▼                                │
   │ CI/CD automatically triggered                       │
   │                    │                                │
   │                    ▼                                │
   │ Tests run, Docker image built                       │
   │                    │                                │
   │                    ▼                                │
   │ Image pushed to ghcr.io/b2atech/SERVICE:TAG        │
   └─────────────────────────────────────────────────────┘

2. DEVOPS WORKFLOW
   ┌─────────────────────────────────────────────────────┐
   │ DevOps notified of new image                        │
   │                    │                                │
   │                    ▼                                │
   │ Run: ./scripts/deployment/update-service.sh SERVICE │
   │                    │                                │
   │                    ▼                                │
   │ Script pulls new image from registry                │
   │                    │                                │
   │                    ▼                                │
   │ Container stopped, removed, recreated               │
   │                    │                                │
   │                    ▼                                │
   │ Health checks verify service is running             │
   └─────────────────────────────────────────────────────┘

3. MONITORING
   ┌─────────────────────────────────────────────────────┐
   │ Prometheus scrapes metrics from services            │
   │                    │                                │
   │                    ▼                                │
   │ Grafana displays dashboards                         │
   │                    │                                │
   │                    ▼                                │
   │ Loki aggregates logs from all containers            │
   │                    │                                │
   │                    ▼                                │
   │ Alerts sent if services unhealthy                   │
   └─────────────────────────────────────────────────────┘
```

## Directory Structure

```
dhanman-infra/
│
├── 📋 Documentation
│   ├── README.md                    # Main entry point
│   ├── SETUP.md                     # Complete setup guide
│   ├── QUICKREF.md                  # Quick reference
│   └── SERVICE-SETUP-CHECKLIST.md   # Service setup steps
│
├── 🐳 Docker Compose
│   ├── dhanman-services.yml         # Main compose (latest tags)
│   ├── qa/
│   │   └── dhanman-services-qa.yml  # QA config (develop tags)
│   ├── prod/
│   │   └── dhanman-services-prod.yml # Prod config (version tags)
│   └── env/
│       ├── common.env.example       # Environment templates
│       ├── sales.env.example
│       └── ...
│
├── 🔧 CI/CD Templates
│   ├── Dockerfile.example           # Multi-stage .NET Dockerfile
│   ├── jenkins/
│   │   └── Jenkinsfile             # Jenkins pipeline
│   └── github-actions/
│       └── docker-build-push.yml    # GitHub Actions workflow
│
├── 🚀 Deployment Scripts
│   ├── ghcr-login.sh               # Login to registry
│   ├── pull-images.sh              # Pull all images
│   ├── deploy-services.sh          # Deploy/update all
│   └── update-service.sh           # Update single service
│
└── 🤖 Ansible Automation
    ├── roles/
    │   └── dhanman_service/        # Enhanced with GHCR support
    └── inventories/
        ├── qa/                     # QA environment config
        └── prod/                   # Production environment config
```

## Network Architecture

```
                   ┌─────────────────────────────────┐
                   │     dhanman-network (bridge)    │
                   └─────────────────────────────────┘
                                  │
         ┌────────────────────────┼────────────────────────┐
         │                        │                        │
    ┌────▼────┐             ┌────▼────┐            ┌────▼────┐
    │ common  │             │  sales  │            │purchase │
    │  :5200  │             │  :5201  │            │  :5202  │
    └─────────┘             └─────────┘            └─────────┘
         │                        │                        │
    ┌────▼────┐             ┌────▼────┐            ┌────▼────┐
    │ payroll │             │inventory│            │community│
    │  :5203  │             │  :5204  │            │  :5205  │
    └─────────┘             └─────────┘            └─────────┘
         │                        │                        │
         └────────────────────────┼────────────────────────┘
                                  │
                         ┌────────▼────────┐
                         │  PostgreSQL DB  │
                         │  (External)     │
                         └─────────────────┘
```

## Security Model

```
┌─────────────────────────────────────────────────────┐
│               SECURITY LAYERS                       │
├─────────────────────────────────────────────────────┤
│                                                     │
│  🔐 Registry Access                                │
│     • GitHub Personal Access Token                 │
│     • Scope: read:packages, write:packages         │
│                                                     │
│  🔐 Container Security                             │
│     • Non-root user in containers                  │
│     • Health checks for monitoring                 │
│     • Resource limits (CPU, memory)                │
│                                                     │
│  🔐 Secret Management                              │
│     • .env files (gitignored)                      │
│     • Database credentials not in images           │
│     • Ansible vault for automation                 │
│                                                     │
│  🔐 Network Security                               │
│     • Isolated Docker network                      │
│     • Nginx reverse proxy (SSL/TLS)                │
│     • Internal service communication only          │
│                                                     │
└─────────────────────────────────────────────────────┘
```

## Monitoring Stack

```
┌───────────────────────────────────────────────────────┐
│                  MONITORING FLOW                      │
└───────────────────────────────────────────────────────┘

         ┌─────────────────────────────────┐
         │      Service Containers         │
         │  • Expose metrics on /metrics   │
         │  • Write logs to stdout/stderr  │
         │  • Health checks on /health     │
         └──────────┬──────────────┬───────┘
                    │              │
         ┌──────────▼────┐    ┌───▼─────────────┐
         │  Prometheus   │    │   Promtail      │
         │  (Metrics)    │    │   (Log Shipper) │
         └──────────┬────┘    └────┬────────────┘
                    │              │
                    │         ┌────▼─────┐
                    │         │   Loki   │
                    │         │  (Logs)  │
                    │         └────┬─────┘
                    │              │
         ┌──────────▼──────────────▼──────┐
         │         Grafana                │
         │  • Dashboards                  │
         │  • Alerts                      │
         │  • Unified view                │
         └────────────────────────────────┘
                    │
                    ▼
            📊 DevOps Team
```

## Tagging Strategy

```
┌─────────────────────────────────────────────────────┐
│                  IMAGE TAGS                         │
├─────────────────────────────────────────────────────┤
│                                                     │
│  Branch: develop                                   │
│  └─> Tag: develop                                  │
│       Use: QA Environment                          │
│                                                     │
│  Branch: main                                      │
│  └─> Tag: latest                                   │
│       Use: Testing/Staging                         │
│                                                     │
│  Git Tag: v1.0.0                                   │
│  └─> Tag: v1.0.0, 1.0, 1                          │
│       Use: Production                              │
│                                                     │
│  Pull Request                                      │
│  └─> Tag: pr-123                                   │
│       Use: Testing only (not deployed)             │
│                                                     │
└─────────────────────────────────────────────────────┘
```

## Component Interactions

```
Service Repos ─(git push)─> CI/CD ─(docker push)─> GHCR
                                                      │
    ┌─────────────────────────────────────────────────┘
    │
    │ (docker pull)
    ▼
Deployment Server
    │
    ├─> Docker Compose ─> Containers
    │                        │
    ├─> Ansible ──────────> │
    │                        │
    └─> Scripts ──────────> │
                             │
                             ├─> Application Services
                             ├─> Monitoring Stack
                             └─> Log Aggregation
```

---

**Legend:**
- 📦 Docker Images
- 🐳 Docker/Containers
- 🔧 CI/CD Tools
- 🚀 Deployment
- 🤖 Automation
- 🔐 Security
- 📊 Monitoring
- 🌐 Network

---

For detailed information, see:
- [SETUP.md](SETUP.md) - Complete setup guide
- [QUICKREF.md](QUICKREF.md) - Quick reference
- [README.md](README.md) - Main documentation
