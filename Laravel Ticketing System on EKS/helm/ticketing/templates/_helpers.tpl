{{/* ==========================================================================
     Naming
     ========================================================================== */}}

{{- define "ticketing.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "ticketing.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "ticketing.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* ==========================================================================
     Labels
     ========================================================================== */}}

{{- define "ticketing.selectorLabels" -}}
app.kubernetes.io/name: {{ include "ticketing.name" .ctx }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{- define "ticketing.labels" -}}
helm.sh/chart: {{ include "ticketing.chart" .ctx }}
{{ include "ticketing.selectorLabels" . }}
app.kubernetes.io/part-of: ticketing
app.kubernetes.io/managed-by: {{ .ctx.Release.Service }}
app.kubernetes.io/version: {{ .ctx.Chart.AppVersion | quote }}
{{- with .ctx.Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/* ==========================================================================
     Image reference

     Three guards, in order of how often each one bites:
       1. tag missing            -> Helm would render "repo:" and the kubelet
                                    would resolve it to :latest.
       2. tag == latest          -> mutable tag; two pods of the "same" release
                                    can run different code, and a rollback is a
                                    no-op because the tag did not change.
       3. tag not a 40-char SHA  -> the build contract pins images to the full
                                    git SHA so an image is traceable to a commit.
     ========================================================================== */}}

{{- define "ticketing.image" -}}
{{- $repo := required "image.repository is required - set it to the ECR repository URL from `terraform output ecr_repository_url`" .Values.image.repository -}}
{{- $tag := required "image.tag is required - set it to the full 40-character git SHA of the build (--set image.tag=$(git rev-parse HEAD)). Never deploy an untagged or floating image." .Values.image.tag -}}
{{- if eq (lower $tag) "latest" -}}
{{- fail "image.tag must not be \"latest\": a mutable tag makes rollbacks a no-op and lets two replicas of the same release run different code. Use the full 40-character git SHA." -}}
{{- end -}}
{{- if not (regexMatch "^[0-9a-f]{40}$" $tag) -}}
{{- fail (printf "image.tag %q is not a full 40-character lowercase git SHA. The build contract pins every image to its commit; short SHAs and semver tags are rejected so an image can always be traced back to source." $tag) -}}
{{- end -}}
{{- printf "%s:%s" $repo $tag -}}
{{- end -}}

{{/* ==========================================================================
     ServiceAccount name
     ========================================================================== */}}

{{- define "ticketing.serviceAccountName" -}}
{{- default "ticketing" .Values.serviceAccount.name -}}
{{- end -}}

{{/* ==========================================================================
     Writable mounts required by readOnlyRootFilesystem: true

     The container filesystem is read-only, so every path the application or
     nginx writes to at runtime needs its own emptyDir. All EIGHT are mandatory.
     Omitting a single one is not a degraded mode - it is an immediate crash
     loop on the first request or on boot.

     /var/lib/nginx is the one that is almost always missed. nginx writes its
     client_body / proxy / fastcgi / scgi / uwsgi temp files there; without it
     nginx exits during startup with "mkdir() ... failed (30: Read-only file
     system)" and the pod restarts forever while the other seven mounts look
     perfectly correct.
     ========================================================================== */}}

{{- define "ticketing.writableVolumes" -}}
- name: storage-framework-cache
  emptyDir: {}
- name: storage-framework-sessions
  emptyDir: {}
- name: storage-framework-views
  emptyDir: {}
- name: storage-logs
  emptyDir: {}
- name: bootstrap-cache
  emptyDir: {}
- name: tmp
  emptyDir: {}
- name: var-run
  emptyDir: {}
# nginx temp paths - the mount that is usually forgotten. See the note above.
- name: var-lib-nginx
  emptyDir: {}
{{- end -}}

{{- define "ticketing.writableVolumeMounts" -}}
- name: storage-framework-cache
  mountPath: /var/www/storage/framework/cache
- name: storage-framework-sessions
  mountPath: /var/www/storage/framework/sessions
- name: storage-framework-views
  mountPath: /var/www/storage/framework/views
- name: storage-logs
  mountPath: /var/www/storage/logs
- name: bootstrap-cache
  mountPath: /var/www/bootstrap/cache
- name: tmp
  mountPath: /tmp
- name: var-run
  mountPath: /var/run
# nginx temp paths - the mount that is usually forgotten. See the note above.
- name: var-lib-nginx
  mountPath: /var/lib/nginx
{{- end -}}

{{/* ==========================================================================
     Secret-backed environment variables

     Everything here comes from the single Kubernetes Secret that External
     Secrets materialises from AWS Secrets Manager. Explicit secretKeyRef rather
     than envFrom so that a missing key fails the pod with a named variable
     instead of quietly starting the app with an empty password.
     ========================================================================== */}}

{{- define "ticketing.secretEnv" -}}
{{- $secret := .Values.externalSecrets.targetSecretName -}}
- name: APP_KEY
  valueFrom:
    secretKeyRef:
      name: {{ $secret }}
      key: APP_KEY
- name: DB_HOST
  valueFrom:
    secretKeyRef:
      name: {{ $secret }}
      key: DB_HOST
- name: DB_PORT
  valueFrom:
    secretKeyRef:
      name: {{ $secret }}
      key: DB_PORT
- name: DB_DATABASE
  valueFrom:
    secretKeyRef:
      name: {{ $secret }}
      key: DB_DATABASE
- name: DB_USERNAME
  valueFrom:
    secretKeyRef:
      name: {{ $secret }}
      key: DB_USERNAME
- name: DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ $secret }}
      key: DB_PASSWORD
- name: REDIS_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ $secret }}
      key: REDIS_PASSWORD
- name: MAIL_HOST
  valueFrom:
    secretKeyRef:
      name: {{ $secret }}
      key: MAIL_HOST
- name: MAIL_PORT
  valueFrom:
    secretKeyRef:
      name: {{ $secret }}
      key: MAIL_PORT
- name: MAIL_USERNAME
  valueFrom:
    secretKeyRef:
      name: {{ $secret }}
      key: MAIL_USERNAME
- name: MAIL_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ $secret }}
      key: MAIL_PASSWORD
- name: MAIL_ENCRYPTION
  valueFrom:
    secretKeyRef:
      name: {{ $secret }}
      key: MAIL_ENCRYPTION
- name: MAIL_FROM_ADDRESS
  valueFrom:
    secretKeyRef:
      name: {{ $secret }}
      key: MAIL_FROM_ADDRESS
{{- end -}}

{{/* ==========================================================================
     Full env block: ConfigMap (plain) + Secret (sensitive) + downward API
     ========================================================================== */}}

{{- define "ticketing.envFrom" -}}
- configMapRef:
    name: {{ include "ticketing.fullname" . }}-config
{{- end -}}

{{- define "ticketing.podEnv" -}}
{{- include "ticketing.secretEnv" . }}
- name: POD_NAME
  valueFrom:
    fieldRef:
      fieldPath: metadata.name
- name: POD_IP
  valueFrom:
    fieldRef:
      fieldPath: status.podIP
{{- end -}}

{{/* ==========================================================================
     KEDA / Laravel Redis queue key

     "<REDIS_PREFIX>queues:<queue>" - e.g. laravel_database_queues:default.
     Templated from values so the chart and the application can never disagree.
     ========================================================================== */}}

{{- define "ticketing.queueListName" -}}
{{- printf "%squeues:%s" .Values.redis.prefix .Values.redis.queue -}}
{{- end -}}

{{/* ==========================================================================
     Common annotations
     ========================================================================== */}}

{{- define "ticketing.annotations" -}}
{{- with .Values.commonAnnotations }}
{{ toYaml . }}
{{- end }}
{{- end -}}
