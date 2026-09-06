# WiFii secrets for the crew Raspberry Pis - SSID + WPA2 pre-shared key as a
# 64-char hex string (NEVER the plain passphrase).
#
# To let the crew join your wireless network from a passphrase, compute the
# PSK hash first (PBKDF2-HMAC-SHA1 over ssid + passphrase, the same thing
# wpa_passphrase does):
#
#   nix-shell -p wpa_supplicant --run 'wpa_passphrase "MyNetwork" "change-me" '
#       # -> psk=...
#
# or: python3 -c "import hashlib;print(hashlib.pbkdf2_hmac('sha1',b'change-me',b'MyNetwork',4096).hexdigest())"
#
# Then COPY this file to nix/network-secrets.nix (gitignored) and fill in
# your real values. Without the file the builds fail on purpose - wifi is
# configured per network-secrets.nix at image-build time.
{
  ssid = "MyNetwork";
  psk = "0000000000000000000000000000000000000000000000000000000000000000"; # 64 hex chars
}