{{- with secret "aws/creds/__AWS_SECRETS_ROLE__" -}}
{
  "Version": 1,
  "AccessKeyId": "{{ .Data.access_key }}",
  "SecretAccessKey": "{{ .Data.secret_key }}",
  "SessionToken": "{{ .Data.security_token }}",
  "Expiration": "__EPOCH_{{ add (timestamp "unix" | parseInt) .LeaseDuration }}_EPOCH__"
}
{{- end }}
