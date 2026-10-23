"""Generates dashboards/service-tracing.json. Run: python3 gen_service_tracing_dashboard.py"""
import json
import pathlib

PROM = {"type": "prometheus", "uid": "efm1ca74j8oaod"}
TEMPO = {"type": "tempo", "uid": "tempo"}
SEL = 'service=~"$service", span_kind="SPAN_KIND_SERVER", span_name!="OPTIONS"'

panels = []


def add(panel, x, y, w, h):
    panel.update(id=len(panels) + 1, gridPos={"x": x, "y": y, "w": w, "h": h})
    panels.append(panel)


def prom(expr, legend="", instant=False, fmt="time_series"):
    return {"datasource": PROM, "expr": expr, "legendFormat": legend, "instant": instant,
            "range": not instant, "format": fmt, "refId": chr(65 + 0)}


def stat(title, expr, unit, thresholds):
    return {"type": "stat", "title": title, "datasource": PROM, "targets": [prom(expr, instant=True)],
            "fieldConfig": {"defaults": {"unit": unit, "decimals": 2, "thresholds": {"mode": "absolute", "steps": thresholds}}},
            "options": {"colorMode": "background", "graphMode": "none", "reduceOptions": {"calcs": ["lastNotNull"]}}}


def series(title, expr, unit, legend="{{service}}"):
    return {"type": "timeseries", "title": title, "datasource": PROM, "targets": [prom(expr, legend)],
            "fieldConfig": {"defaults": {"unit": unit, "custom": {"lineWidth": 2, "fillOpacity": 5}}},
            "options": {"legend": {"displayMode": "table", "placement": "right", "calcs": ["mean", "max"]},
                        "tooltip": {"mode": "multi", "sort": "desc"}}}


def endpoint_table(title, expr, unit, value_name):
    return {"type": "table", "title": title, "datasource": PROM, "targets": [prom(expr, instant=True, fmt="table")],
            "fieldConfig": {"defaults": {"unit": unit, "decimals": 2}},
            "transformations": [{"id": "organize", "options": {
                "excludeByName": {"Time": True},
                "renameByName": {"service": "Service", "span_name": "Endpoint", "Value": value_name}}}],
            "options": {"sortBy": [{"displayName": value_name, "desc": True}]}}


def p95(by):
    return f"histogram_quantile(0.95, sum by ({by}, le) (rate(traces_spanmetrics_latency_bucket{{{SEL}}}[$__rate_interval])))"


ERR = f'sum by (service) (rate(traces_spanmetrics_calls_total{{{SEL}, status_code="STATUS_CODE_ERROR"}}[$__rate_interval]))'
ALL = f"sum by (service) (rate(traces_spanmetrics_calls_total{{{SEL}}}[$__rate_interval]))"

add(stat("Requests / sec", f"sum(rate(traces_spanmetrics_calls_total{{{SEL}}}[5m]))", "reqps",
         [{"color": "blue", "value": None}]), 0, 0, 6, 4)
add(stat("Error rate", f'sum(rate(traces_spanmetrics_calls_total{{{SEL}, status_code="STATUS_CODE_ERROR"}}[5m])) '
                       f"/ sum(rate(traces_spanmetrics_calls_total{{{SEL}}}[5m])) or vector(0)", "percentunit",
         [{"color": "green", "value": None}, {"color": "orange", "value": 0.01}, {"color": "red", "value": 0.05}]), 6, 0, 6, 4)
add(stat("p95 latency", f"histogram_quantile(0.95, sum by (le) (rate(traces_spanmetrics_latency_bucket{{{SEL}}}[5m])))", "s",
         [{"color": "green", "value": None}, {"color": "orange", "value": 1}, {"color": "red", "value": 3}]), 12, 0, 6, 4)
add(stat("Errors (range)", f'sum(increase(traces_spanmetrics_calls_total{{{SEL}, status_code="STATUS_CODE_ERROR"}}[$__range])) or vector(0)',
         "short", [{"color": "green", "value": None}, {"color": "red", "value": 1}]), 18, 0, 6, 4)

add(series("Requests / sec by service", ALL, "reqps"), 0, 4, 12, 8)
add(series("Errors / sec by service (5xx and exceptions)", ERR, "reqps"), 12, 4, 12, 8)
add(series("p95 latency by service", p95("service"), "s"), 0, 12, 24, 8)

add(endpoint_table("Slowest endpoints (p95)", f"topk(20, {p95('service, span_name')})", "s", "p95"), 0, 20, 12, 10)
add(endpoint_table("Endpoints with most errors (range)",
                   f'topk(20, sum by (service, span_name) (increase(traces_spanmetrics_calls_total{{{SEL}, status_code="STATUS_CODE_ERROR"}}[$__range])) > 0)',
                   "short", "Errors"), 12, 20, 12, 10)

add({"type": "table", "title": "Recent failed requests — click a Trace ID to open it", "datasource": TEMPO,
     "targets": [{"datasource": TEMPO, "refId": "A", "queryType": "traceql", "limit": 50, "tableType": "traces",
                  "query": '{ resource.service.name =~ "${service:regex}" && status = error }'}]}, 0, 30, 24, 10)
add({"type": "table", "title": "Slow requests (> 2s)", "datasource": TEMPO,
     "targets": [{"datasource": TEMPO, "refId": "A", "queryType": "traceql", "limit": 50, "tableType": "traces",
                  "query": '{ resource.service.name =~ "${service:regex}" && kind = server && duration > 2s }'}]}, 0, 40, 24, 10)
add({"type": "nodeGraph", "title": "Service map (who calls whom)", "datasource": TEMPO,
     "targets": [{"datasource": TEMPO, "refId": "A", "queryType": "serviceMap"}]}, 0, 50, 24, 14)

dashboard = {
    "uid": "dhanman-service-tracing",
    "title": "Dhanman — Service Tracing",
    "tags": ["dhanman", "tracing", "tempo"],
    "timezone": "browser",
    "refresh": "1m",
    "time": {"from": "now-6h", "to": "now"},
    "schemaVersion": 41,
    "templating": {"list": [{
        "name": "service", "label": "Service", "type": "query", "datasource": PROM,
        "query": {"query": "label_values(traces_spanmetrics_calls_total, service)", "refId": "service"},
        "refresh": 2, "multi": True, "includeAll": True, "allValue": ".*",
        "current": {"text": "All", "value": "$__all"}}]},
    "panels": panels,
}

out = pathlib.Path(__file__).parent / "dashboards" / "service-tracing.json"
out.write_text(json.dumps(dashboard, indent=2) + "\n")
print(f"wrote {out}")
