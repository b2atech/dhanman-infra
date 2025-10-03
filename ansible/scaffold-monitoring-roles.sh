#!/bin/bash

cd "$(dirname "$0")"  # ensure you're in the ansible folder

ROLES=("common" "node_exporter" "loki" "promtail" "grafana")

for role in "${ROLES[@]}"; do
  mkdir -p roles/$role/{tasks,handlers,files,templates,vars,defaults}
  touch roles/$role/tasks/main.yml
  echo "- name: $role role placeholder" > roles/$role/tasks/main.yml
done

echo "✅ Monitoring roles scaffolded inside roles/ directory"
