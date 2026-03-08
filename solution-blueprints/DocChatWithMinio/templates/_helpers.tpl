# Copyright © Advanced Micro Devices, Inc., or its affiliates.
#
# SPDX-License-Identifier: MIT

{{/*
Create a default fully qualified app name.
*/}}
{{- define "aimsb-talk-to-your-documents.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "aimsb-talk-to-your-documents.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "aimsb-talk-to-your-documents.labels" -}}
helm.sh/chart: {{ include "aimsb-talk-to-your-documents.chart" . }}
{{ include "aimsb-talk-to-your-documents.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels used by deployments and services.
*/}}
{{- define "aimsb-talk-to-your-documents.selectorLabels" -}}
app: {{ include "aimsb-talk-to-your-documents.fullname" . }}
{{- end }}

{{/*
Helper for container environment variables.
*/}}
{{- define "aimsb-talk-to-your-documents.container.env" -}}
- name: QDRANT_URL
  value: {{ include "aim-qdrant.url" . | quote }}
- name: VLLM_URL
  {{ $sub := dict "Values" (merge (dict) .Values.llm) "Release" .Release "Chart" (dict "Name" "llm") }}
  value: {{ include "aimchart-llm.url" $sub }}
- name: EMBEDDING_URL
  {{ $sub := dict "Values" (merge (dict) .Values.embedding) "Release" .Release "Chart" (dict "Name" "embedding") }}
  value: {{ include "aim-embedding.url" $sub }}/embeddings
- name: EMBEDDING_OPENAI_URL
  {{ $sub := dict "Values" (merge (dict) .Values.embedding) "Release" .Release "Chart" (dict "Name" "embedding") }}
  value: {{ include "aim-embedding.url" $sub }}/v1
{{- if .Values.minio.enabled }}
- name: MINIO_ENABLED
  value: "true"
- name: MINIO_ENDPOINT
  value: {{ include "aim-minio.url" . | quote }}
- name: MINIO_BUCKET
  value: {{ .Values.minio.bucket | quote }}
- name: MINIO_REGION
  value: {{ .Values.minio.region | quote }}
- name: MINIO_PREFIX
  value: {{ .Values.minio.prefix | quote }}
- name: MINIO_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "aim-minio.secretName" . }}
      key: accesskey
- name: MINIO_SECRET_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "aim-minio.secretName" . }}
      key: secretkey
{{- end }}
{{- range $key, $value := .Values.env_vars }}
- name: {{ $key }}
  value: {{ tpl $value $ | quote }}
{{- end }}
{{- end }}

{{/*
Qdrant service naming and URL helpers.
*/}}
{{- define "aim-qdrant.release.fullname" -}}
{{- printf "%s-qdrant" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "aim-qdrant.url" -}}
{{- if not .Values.qdrant.existingService -}}
http://{{ include "aim-qdrant.release.fullname" . }}:{{ .Values.qdrant.deployment.ports.http }}
{{- else -}}
{{- if hasPrefix "http" .Values.qdrant.existingService -}}
{{ .Values.qdrant.existingService }}
{{- else -}}
http://{{ .Values.qdrant.existingService }}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
MinIO naming and URL helpers.
*/}}
{{- define "aim-minio.release.fullname" -}}
{{- printf "%s-minio" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "aim-minio.secretName" -}}
{{- if .Values.minio.auth.existingSecret -}}
{{ .Values.minio.auth.existingSecret }}
{{- else -}}
{{ include "aim-minio.release.fullname" . }}
{{- end -}}
{{- end -}}

{{- define "aim-minio.url" -}}
{{- if .Values.minio.existingService -}}
{{- if hasPrefix "http" .Values.minio.existingService -}}
{{ .Values.minio.existingService }}
{{- else -}}
http://{{ .Values.minio.existingService }}
{{- end -}}
{{- else -}}
http://{{ include "aim-minio.release.fullname" . }}:{{ .Values.minio.service.apiPort }}
{{- end -}}
{{- end -}}

{{/*
Helper for container resources.
*/}}
{{- define "aimsb-talk-to-your-documents.container.resources" -}}
{{- if .Values.resources }}
{{- toYaml .Values.resources }}
{{- else }}
{}
{{- end }}
{{- end }}

{{/*
Helper for container volume mounts.
Includes the critical subPath fix for the "requirements.txt not found" error.
*/}}
{{- define "aimsb-talk-to-your-documents.container.volumeMounts" -}}
- name: dshm
  mountPath: /dev/shm
- name: ephemeral-storage
  mountPath: /workload
{{- range $path, $_ := .Files.Glob "src/**" }}
- name: workload-mount
  mountPath: /workload/mount/{{ $path }}
  subPath: {{ $path | replace "/" "_" }}
{{- end }}
{{- end }}

{{/*
Helper for container volumes.
*/}}
{{- define "aimsb-talk-to-your-documents.container.volumes" -}}
- name: dshm
  emptyDir:
    medium: Memory
    sizeLimit: {{ .Values.storage.dshm.sizeLimit }}
- name: ephemeral-storage
  emptyDir:
    sizeLimit: {{ .Values.storage.ephemeral.quantity }}
- name: workload-mount
  configMap:
    name: {{ include "aimsb-talk-to-your-documents.fullname" . }}
{{- end }}

{{/*
Entrypoint script for the application
*/}}
{{- define "aimsb-talk-to-your-documents.entrypoint" -}}
set -euo pipefail
echo "Installing Python dependencies..."
pip install --no-cache-dir -r /workload/mount/src/requirements.txt
echo "Starting Uvicorn server..."
cd /workload/mount/src
uvicorn app:app --host 0.0.0.0 --port {{ .Values.deployment.ports.http }} --root-path /
{{- end }}
