## Architecture
Local Root CA  →  signs  →  Rancher Server Certificate

### Generate CA key:
openssl genrsa -out localCA.key 4096

### Generate CA certificate:
openssl req -x509 -new -nodes \
  -key localCA.key \
  -sha256 -days 3650 \
  -out localCA.crt \
  -subj "/C=DE/ST=Local/L=Local/O=LocalDev/OU=Dev/CN=Local Rancher CA"

### Generate server key:
  openssl genrsa -out rancher.key 2048

### Generate CSR:
  openssl req -new \
  -key rancher.key \
  -out rancher.csr \
  -config rancher.cnf

### Sign it with your CA:
  openssl x509 -req \
  -in rancher.csr \
  -CA localCA.crt \
  -CAkey localCA.key \
  -CAcreateserial \
  -out rancher.crt \
  -days 3650 \
  -sha256 \
  -extensions req_ext \
  -extfile rancher.cnf

### Install Root CA into your system/browser
