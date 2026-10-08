param(
    [ValidateSet("up", "down", "status", "logs")]
    [string]$Action = "up"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $ProjectRoot

switch ($Action) {
    "up" {
        docker compose -p talent-eval-mineru -f docker-compose-mineru.yml up -d --build mineru
        docker compose -p talent-eval-agents-course --profile app up -d --build
        docker compose -p talent-eval-agents-course --profile app ps
    }
    "down" {
        docker compose -p talent-eval-agents-course --profile app down
        docker compose -p talent-eval-mineru -f docker-compose-mineru.yml down
    }
    "status" {
        docker compose -p talent-eval-agents-course --profile app ps
        docker compose -p talent-eval-mineru -f docker-compose-mineru.yml ps mineru
    }
    "logs" {
        docker compose -p talent-eval-agents-course --profile app logs -f --tail=200 backend worker frontend
    }
}
