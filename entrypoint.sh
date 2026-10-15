#!/usr/bin/env bash
# Description: Start Localias, install its certificates, and validate configured HTTPS domains.
# Optionally warm the Chromium certificate store with Playwright.

set -v

# Fail on errors, unset variables, and failed pipeline commands.
set -euo pipefail

GITHUB_ACTION_PATH=${GITHUB_ACTION_PATH:?GITHUB_ACTION_PATH must point to the action directory}
WARM_CHROME=${WARM_CHROME:-false}
NSS_DB_PATH="$HOME/.pki/nssdb"
LOCALIAS_BINARY_PATH=localias

banner_echo() {
  printf "\n\033[0;36m%s   \033[0m\n" "$1"
}

# sudo uses secure_path and does not keep the caller's PATH even with -E, so
# user-local installs (version managers, etc.) are invisible to `sudo localias`.
# If we can resolve a real ELF (e.g. via mise which — not a shim, which breaks
# under sudo because HOME=/root), use that absolute path instead of installing.
if sudo -n -E localias --version >/dev/null 2>&1; then
  :
elif command -v mise >/dev/null 2>&1 \
  && resolved_localias=$(mise which localias 2>/dev/null) \
  && [ -n "$resolved_localias" ] && [ -x "$resolved_localias" ]; then
  LOCALIAS_BINARY_PATH=$resolved_localias
  banner_echo "Using existing localias: $LOCALIAS_BINARY_PATH"
else
  banner_echo "Installing localias"
  # Pass --base-url explicitly to avoid inheriting a BASE_URL env var from the CI environment.
  sh "$GITHUB_ACTION_PATH/install.sh" --yes --base-url "https://github.com/peterldowns/localias/releases"
fi

if ! sudo -n -E "$LOCALIAS_BINARY_PATH" --version >/dev/null 2>&1; then
  banner_echo "ERROR: localias not executable via sudo: $LOCALIAS_BINARY_PATH"
  exit 1
fi

# to view logs, run detached `sudo localaias run &`
banner_echo "Starting localias..."
sudo -E "$LOCALIAS_BINARY_PATH" start

# wait until the daemon has finished initializing
# file is normally located at: /root/.local/state/localias/caddy/pki/authorities/local/root.crt

cert_location=$(sudo -E "$LOCALIAS_BINARY_PATH" debug cert)

# this can occur if there was an error installing localias
if [ -z "$cert_location" ]; then
  banner_echo "ERROR: Failed to get certificate location from localias debug cert command"
  exit 1
fi

daemon_success=false

for attempt in {1..5}; do
  banner_echo "Checking for self-signed cert ($attempt/5): $cert_location..."

  # NOTE sudo is really important here, without this the check will fail since the file is protected
  if sudo [ -f "$cert_location" ]; then
    daemon_success=true
  else
    sleep 2
  fi

  if $daemon_success; then
    break
  fi
done

if ! $daemon_success; then
  banner_echo "ERROR: Localias certificate did not appear after five checks: $cert_location"
  exit 1
fi

banner_echo "Creating shared NSS DB..."
# when this directory is properly configured, you should see the following files: cert9.db  key4.db  pkcs11.txt
if [ ! -d "$NSS_DB_PATH" ]; then
  mkdir -p "$NSS_DB_PATH"
  certutil -d "sql:$NSS_DB_PATH" -N --empty-password
fi

# https://chromium.googlesource.com/chromium/src/+/master/docs/linux/cert_management.md
banner_echo "Installing certificates for Chrome and others using shared NSS DB..."
sudo certutil -d "sql:$NSS_DB_PATH" -A -t "C,," -n localias-cert -i "$cert_location"

banner_echo "Installed certificates:"
certutil -L -d "sql:$NSS_DB_PATH"

# localias (caddy) appends the self-signed certificate to /etc/ssl/certs/ca-certificates.crt
# but the system is not refreshed, which causes curl and various other systems to *not* pick up on the new certificate
banner_echo "Refreshing system CA certs..."
sudo update-ca-certificates --fresh

# reset DNS, could cause issues with custom domains
if command -v systemctl >/dev/null &&
  systemctl is-active --quiet systemd-resolved; then
  sudo systemctl restart systemd-resolved
fi

# certs are *not* installed by Caddy in the right location by default
# specifically, we know this fixes `curl` so it respects our self-signed SSL certificates
# banner_echo "Installing locally signed cert"
# sudo -E localias debug cert --print | sudo tee -a /etc/ssl/certs/ca-certificates.crt

# https://stackoverflow.com/a/75352343/129415
# TODO should we set this here? makes httpie work?
# REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
# export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
# export CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
# export NODE_EXTRA_CA_CERTS="/path/to/cert.pem"

# each individual test domain should be tested/warmed up, otherwise downstream services may get an SSL error
test_domains=$("$LOCALIAS_BINARY_PATH" debug config --print | grep -v '^#' | grep -v '^$' | cut -d: -f1 | tr -d ' ')

for test_domain in $test_domains; do
  banner_echo "Testing $test_domain..."
  curl_success=false

  for attempt in {1..5}; do
    banner_echo "Checking HTTPS via curl ($attempt/5)..."
    if curl -vvv --head "$test_domain"; then
      curl_success=true
      break
    fi

    sleep 2
  done

  if ! $curl_success; then
    banner_echo "ERROR: HTTPS check failed after five attempts: $test_domain"
    exit 1
  fi
done

if [ "$WARM_CHROME" = "true" ]; then
  # Prefer uvx to avoid modifying the global Python environment.
  if command -v uvx >/dev/null 2>&1; then
    chrome_python=(uvx --from playwright python)
  else
    python3 -m pip install playwright
    chrome_python=(python3)
  fi

  "${chrome_python[@]}" -m playwright install chromium --only-shell

  for test_domain in $test_domains; do
    banner_echo "Testing Chrome $test_domain..."
    "${chrome_python[@]}" "$GITHUB_ACTION_PATH/warm_chrome.py" "$test_domain"
  done
fi

banner_echo "Tailing localias logs..."
sudo tail -n 0 -f /root/.local/state/localias/daemon.log &
