epoch=$(grep -o "__EPOCH_[0-9]*_EPOCH__" /vault/secrets/aws-creds-raw | grep -o "[0-9]*")
exp=$(date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ)
sed "s/__EPOCH_[0-9]*_EPOCH__/$exp/" /vault/secrets/aws-creds-raw > /vault/secrets/aws-creds.tmp
mv /vault/secrets/aws-creds.tmp /vault/secrets/aws-creds
